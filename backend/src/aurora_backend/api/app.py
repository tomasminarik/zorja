import asyncio
import json
import secrets
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from aurora_backend.api.forecast import build_forecast
from aurora_backend.api.forecast_input import forecast_location
from aurora_backend.api.service import ForecastService, Sources
from aurora_backend.collection.endpoint import Collector, add_collector_route
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import Clock, SystemClock
from aurora_backend.domain.errors import DomainError, ErrorCode
from aurora_backend.domain.types import Location
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.redis_store import RedisProviderStore
from aurora_backend.providers.store import SnapshotStore


def create_app(
    settings: Settings | None = None,
    clock: Clock | None = None,
    sources: Sources | None = None,
    shared_admission: RedisProviderStore | None = None,
    collector: Collector | None = None,
    internal_routes: bool = True,
) -> FastAPI:
    """Build the forecast app.

    `internal_routes=False` (the public hosted service) leaves out the API docs,
    the OpenAPI document and the per-instance metrics and provider-health routes.
    """
    config = Settings.from_environment() if settings is None else settings
    if shared_admission is not None and (
        shared_admission.limits is None or shared_admission.lane != "forecast"
    ):
        raise ValueError("Shared admission requires foreground budget limits")
    if shared_admission is not None and isinstance(sources, ProviderClient):
        if sources.store is not shared_admission:
            raise ValueError("Foreground client must use the admitted budgeted store")
    timer = SystemClock() if clock is None else clock
    # The hosted service (shared admission) rounds what providers and the shared cache see to
    # the app's two decimals; the local server and replays keep the request's precision.
    service = ForecastService(
        sources,
        config.response_deadline,
        coordinate_decimals=2 if shared_admission is not None else None,
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        store = None
        client = None
        try:
            if config.provider_network and sources is None:
                if shared_admission is None:
                    store = SnapshotStore(config.cache_path)
                selected_store = shared_admission or store
                assert selected_store is not None
                client = ProviderClient(selected_store, clock=timer)
                service.sources = client
            yield
        finally:
            if client:
                await client.close()
            if store:
                store.close()

    hidden: dict[str, Any] = (
        {} if internal_routes else {"docs_url": None, "redoc_url": None, "openapi_url": None}
    )
    app = FastAPI(title="Aurora forecast service", version="1.0.0", lifespan=lifespan, **hidden)
    # One authority: the actual endpoint serializes the published contract. Tests
    # validate HTTP outputs against it; no competing framework forecast schema.
    published = json.loads(config.contract_path.read_text())
    if config.profile == "mvp":
        # Runtime projection; the full frozen contract remains unchanged on disk.
        published["paths"] = {"/v1/forecast": published["paths"]["/v1/forecast"]}
    app.openapi = lambda: published  # type: ignore[method-assign]
    app.state.forecast_service = service
    if collector is not None:
        add_collector_route(app, collector)
    scenarios = {path.stem: path for path in config.fixture_dir.glob("*.json")}

    @app.middleware("http")
    async def response_metadata(request: Request, call_next: Any) -> Any:
        request.state.request_id = uuid4().hex
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["Cache-Control"] = "private, no-store"
        return response

    @app.exception_handler(DomainError)
    async def domain_error(request: Request, error: DomainError) -> JSONResponse:
        status = 400 if error.code == ErrorCode.INVALID_REQUEST else 503
        return JSONResponse(
            status_code=status,
            content={
                "code": error.code.value,
                "message": error.message,
                "requestId": request.state.request_id,
            },
            headers={"Retry-After": "60"} if status == 503 else {},
        )

    @app.exception_handler(RequestValidationError)
    async def invalid_query(request: Request, error: RequestValidationError) -> JSONResponse:
        # Do not echo query coordinates or framework/provider internals.
        return await domain_error(
            request,
            DomainError(ErrorCode.INVALID_REQUEST, "Valid coordinates and timezone are required"),
        )

    @app.get("/health/live")
    def liveness() -> dict[str, str]:
        return {"status": "alive", "mode": config.mode, "time": timer.now().isoformat()}

    @app.get("/health/ready")
    def readiness() -> dict[str, Any]:
        return {
            "status": "ready",
            "providerNetwork": config.provider_network,
            "meaning": "Pipeline configured; provider freshness is separate",
        }

    if internal_routes:

        @app.get("/health/providers")
        def provider_health() -> dict[str, Any]:
            return {
                "providerNetwork": config.provider_network,
                "lastEvaluation": dict(service.health),
                "meaning": "Last request only; inspect forecast.sources for freshness",
            }

        @app.get("/metrics")
        def metrics() -> dict[str, int]:
            return dict(service.metrics)

    if config.profile == "development":

        @app.get("/dev/scenarios")
        def list_scenarios() -> dict[str, Any]:
            return {"synthetic": True, "scenarios": sorted(scenarios)}

        @app.get("/dev/replay/{scenario}")
        def replay(scenario: str) -> JSONResponse:
            if scenario not in scenarios:
                raise DomainError(ErrorCode.INVALID_REQUEST, "Unknown synthetic scenario")
            payload = json.loads(scenarios[scenario].read_text())
            return JSONResponse(
                content=payload,
                status_code=503 if scenario.startswith("error-") else 200,
                headers={
                    "X-Aurora-Synthetic": "true",
                    "X-Aurora-Mode": "offline",
                    **({"Retry-After": "60"} if scenario.startswith("error-") else {}),
                },
            )

    @app.get("/v1/forecast")
    async def forecast(
        request: Request, latitude: float, longitude: float, timezone: str
    ) -> JSONResponse:
        try:
            location = Location(latitude=latitude, longitude=longitude, timezone=timezone)
            if set(request.query_params) != {"latitude", "longitude", "timezone"} or any(
                len(request.query_params.getlist(key)) != 1 for key in request.query_params
            ):
                raise ValueError("Unexpected or repeated parameters")
        except (ValidationError, ValueError) as error:
            raise DomainError(
                ErrorCode.INVALID_REQUEST, "Valid coordinates and timezone are required"
            ) from error
        return await evaluate(request, location)

    @app.post("/v1/forecast")
    async def forecast_post(request: Request) -> JSONResponse:
        return await evaluate(request, await forecast_location(request))

    async def evaluate(request: Request, location: Location) -> JSONResponse:
        if not service.admit():
            return JSONResponse(
                status_code=429,
                content={
                    "code": "rate_limited",
                    "message": "Local request capacity exceeded",
                    "requestId": request.state.request_id,
                },
                headers={"Retry-After": "60"},
            )
        started = asyncio.get_running_loop().time()
        if shared_admission is not None:
            try:
                async with asyncio.timeout(2):
                    admission = await shared_admission.admit_forecast(secrets.token_hex(32))
            except asyncio.CancelledError:
                service.release()
                raise
            except Exception:
                admission = "storage_unavailable"
            if admission != "admitted":
                service.release()
                status = 429 if admission == "rate_limited" else 503
                return JSONResponse(
                    {
                        "code": "rate_limited" if status == 429 else "forecast_unavailable",
                        "message": "Shared forecast capacity temporarily unavailable",
                        "requestId": request.state.request_id,
                    },
                    status_code=status,
                    headers={"Retry-After": "60"},
                )
        release_here = True
        try:
            # Server time is chosen after bounded collection, so expired evidence
            # cannot become fresh because it was fresh at request arrival.
            results = await service.collect(
                location,
                timer.now(),
                budget_seconds=max(
                    0.001, service.deadline - (asyncio.get_running_loop().time() - started)
                ),
            )
            try:
                work = asyncio.create_task(
                    asyncio.to_thread(build_forecast, location, timer.now(), results)
                )
                remaining = max(
                    0.001, service.deadline - (asyncio.get_running_loop().time() - started)
                )
                try:
                    payload = await asyncio.wait_for(asyncio.shield(work), remaining)
                except (TimeoutError, asyncio.CancelledError):
                    # Keep admission occupied until bounded CPU work actually ends.
                    release_here = False

                    def finished(task: asyncio.Task[Any]) -> None:
                        service.release()
                        if not task.cancelled():
                            task.exception()

                    work.add_done_callback(finished)
                    raise
            except Exception as error:
                service.metrics["evaluation_failure"] += 1
                raise DomainError(
                    ErrorCode.FORECAST_UNAVAILABLE, "Forecast evaluation temporarily unavailable"
                ) from error
            service.health = {
                s["product"]: s["status"]
                for s in payload["sources"]
                if s["provider"] != "backend_astronomy"
            }
            service.metrics["success"] += 1
            service.metrics["degraded"] += int(
                any(s["status"] != "fresh" for s in payload["sources"])
            )
            return JSONResponse(content=payload)
        finally:
            if release_here:
                service.release()

    return app
