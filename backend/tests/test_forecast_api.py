import asyncio
import threading
import time
from dataclasses import replace
from datetime import datetime, timedelta

import httpx
import pytest
from forecast_assertions import assert_forecast_equal
from openapi_spec_validator import validate
from test_contract import ROOT, SPEC, checker, validate_example

from aurora_backend.api.app import create_app
from aurora_backend.api.replay import CITIES, RecordedSources, replay_forecast
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product
from aurora_backend.providers.store import SnapshotStore

CAPTURES = ROOT / "backend/tests/fixtures/providers/captured"
QUERY = {"latitude": 59.3293, "longitude": 18.0686, "timezone": "Europe/Stockholm"}


async def request(app, params=QUERY):
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as c:
        return await c.get("/v1/forecast", params=params)


@pytest.mark.parametrize("city", CITIES)
def test_recorded_http_pipeline_schema_and_semantics(city):
    value = asyncio.run(replay_forecast(city, CAPTURES))
    assert value["httpStatus"] == 200 and value["live"] is False
    forecast = value["forecast"]
    validate_example(forecast, "Forecast")
    checker.check_forecast(forecast)
    assert forecast["now"]["action"] != "try_now"
    assert all(
        s["factors"]["activity"] != "supported"
        for n in forecast["planning"]
        for w in n["windows"]
        for s in w["segments"]
    )
    assert (
        next(s for s in forecast["sources"] if s["product"] == Product.KP)["status"]
        == "unavailable"
    )


def test_normalization_cache_and_http_endpoint_with_mock_provider_transport(tmp_path):
    async def exercise():
        recorded = RecordedSources(CAPTURES, "stockholm")
        clock = FixedClock(recorded.at)
        calls = []

        def transport(req):
            calls.append(req.url.host)
            name = (
                "met-stockholm.json"
                if req.url.host == "api.met.no"
                else ("ovation.json" if req.url.path.endswith(".json") else "kp.txt")
            )
            return httpx.Response(
                200,
                content=(CAPTURES / name).read_bytes(),
                headers=recorded.entries[name]["headers"],
            )

        store = SnapshotStore(tmp_path / "cache.sqlite")
        client = ProviderClient(
            store,
            clock=clock,
            transport=httpx.MockTransport(transport),
            request_spacing=0,
            jitter=lambda: 0,
        )
        try:
            app = create_app(Settings(), clock, client)
            responses = await asyncio.gather(request(app), request(app))
            assert len(calls) == 3
            for response in responses:
                assert response.status_code == 200
                validate_example(response.json(), "Forecast")
                checker.check_forecast(response.json())
                assert response.headers["Cache-Control"] == "private, no-store"
                assert response.headers["X-Request-ID"]
        finally:
            await client.close()
            store.close()

    asyncio.run(exercise())


def shorten_collection_budget(app):
    # Trigger provider expiry early while leaving real astronomy several seconds.
    # This tests partial collection/cancellation without a 0.2s CPU race on CI.
    collect = app.state.forecast_service.collect

    async def bounded(*args, **kwargs):
        kwargs["budget_seconds"] = 0.3
        return await collect(*args, **kwargs)

    app.state.forecast_service.collect = bounded


def test_deadline_returns_partial_weather_and_cancels_hanging_sources():
    class Hanging(RecordedSources):
        cancelled = 0

        async def get(self, product, **kwargs):
            if product == Product.WEATHER:
                return await super().get(product, **kwargs)
            try:
                await asyncio.Event().wait()
            finally:
                self.cancelled += 1

    sources = Hanging(CAPTURES, "stockholm")
    app = create_app(Settings(response_deadline=5), FixedClock(sources.at), sources)
    shorten_collection_budget(app)
    started = time.monotonic()
    response = asyncio.run(request(app))
    assert time.monotonic() - started < 5
    assert response.status_code == 200 and sources.cancelled == 2
    assert response.json()["now"]["factors"]["activity"] == "unavailable"
    assert (
        next(s for s in response.json()["sources"] if s["product"] == Product.WEATHER)["status"]
        == "fresh"
    )
    validate_example(response.json(), "Forecast")
    checker.check_forecast(response.json())


def test_outage_is_useful_astronomy_not_optimistic():
    class Failed:
        async def get(self, product, **kwargs):
            raise RuntimeError("sensitive provider details")

    sources = RecordedSources(CAPTURES, "stockholm")
    app = create_app(Settings(), FixedClock(sources.at), Failed())
    response = asyncio.run(request(app))
    assert response.status_code == 200
    value = response.json()
    assert value["now"]["rating"] == "unknown"
    assert value["upcoming"] is not None
    assert "sensitive" not in response.text
    validate_example(value, "Forecast")
    checker.check_forecast(value)


def test_evaluator_failure_is_safe_503(monkeypatch):
    def fail(*args):
        raise ValueError("sensitive coordinates")

    monkeypatch.setattr("aurora_backend.api.app.build_forecast", fail)
    response = asyncio.run(request(create_app(Settings())))
    assert response.status_code == 503 and response.headers["Retry-After"] == "60"
    assert "sensitive" not in response.text
    validate_example(response.json(), "Error")


@pytest.mark.parametrize(
    "extra",
    [
        {"at": "2026-01-01T00:00:00Z"},
        {"latitude": "nan"},
        {"timezone": "UTC+2"},
        {"longitude": 181},
    ],
)
def test_query_validation_and_server_clock(extra):
    response = asyncio.run(request(create_app(Settings()), QUERY | extra))
    assert response.status_code == 400
    validate_example(response.json(), "Error")
    assert response.json()["requestId"] == response.headers["X-Request-ID"]


def test_duplicate_query_rejected():
    params = list(QUERY.items()) + [("latitude", 60)]
    assert asyncio.run(request(create_app(Settings()), params)).status_code == 400


def test_rate_limit_and_coordinate_free_metrics():
    app = create_app(Settings())
    app.state.forecast_service._requests = 60
    response = asyncio.run(request(app))
    assert response.status_code == 429 and response.headers["Retry-After"] == "60"
    validate_example(response.json(), "Error")
    assert app.state.forecast_service.metrics == {"rate_limited": 1}


def test_openapi_has_one_published_authority():
    spec = create_app(Settings(profile="development")).openapi()
    assert spec == SPEC
    validate(spec)
    assert "422" not in spec["paths"]["/v1/forecast"]["get"]["responses"]


def test_between_request_cache_expiry_changes_evidence():
    class Expired(RecordedSources):
        async def get(self, product, **kwargs):
            result = await super().get(product, **kwargs)
            return replace(
                result,
                health=replace(result.health, cache_expires_at=self.at - timedelta(seconds=1)),
            )

    sources = Expired(CAPTURES, "stockholm")
    response = asyncio.run(request(create_app(Settings(), FixedClock(sources.at), sources)))
    assert response.json()["now"]["factors"]["weather"] == "stale"
    assert response.json()["now"]["action"] != "try_now"
    checker.check_forecast(response.json())


@pytest.mark.parametrize(
    "at, latitude",
    [
        ("2026-06-21T12:00:00Z", 69.6492),
        ("2026-12-21T00:00:00Z", 89),
        ("2026-10-25T01:00:00Z", 59.3293),
    ],
)
def test_http_polar_and_timezone_boundaries(at, latitude):
    app = create_app(Settings(), FixedClock(datetime.fromisoformat(at)))
    response = asyncio.run(request(app, QUERY | {"latitude": latitude}))
    assert response.status_code == 200
    validate_example(response.json(), "Forecast")
    checker.check_forecast(response.json())


def test_single_exact_instant_cannot_supply_current_bracket():
    class Exact(RecordedSources):
        async def get(self, product, **kwargs):
            result = await super().get(product, **kwargs)
            if result.snapshot and product == Product.OVATION:
                result = replace(
                    result,
                    snapshot=replace(
                        result.snapshot,
                        observed_at=self.at - timedelta(minutes=1),
                        forecast_at=self.at,
                        valid_from=self.at,
                        valid_until=self.at,
                        grid=tuple(replace(p, value=80) for p in result.snapshot.grid),
                    ),
                )
            if result.snapshot and product == Product.WEATHER:
                result = replace(
                    result,
                    snapshot=replace(
                        result.snapshot,
                        weather=tuple(replace(s, total_cloud=10) for s in result.snapshot.weather),
                    ),
                )
            return result

    sources = Exact(CAPTURES, "stockholm")
    response = asyncio.run(request(create_app(Settings(), FixedClock(sources.at), sources)))
    value = response.json()
    assert value["now"]["action"] == "check_later"
    assert value["now"]["activityEvidence"]["supportedInterval"] is None
    validate_example(value, "Forecast")
    checker.check_forecast(value)


def test_cpu_deadline_keeps_capacity_until_work_finishes(monkeypatch):
    entered, unblock = threading.Event(), threading.Event()

    def blocked(*args):
        entered.set()
        assert unblock.wait(10)
        return {}  # Deadline has already returned; this value is never serialized.

    monkeypatch.setattr("aurora_backend.api.app.build_forecast", blocked)

    async def exercise():
        app = create_app(Settings(response_deadline=0.5))
        task = asyncio.create_task(request(app))
        try:
            assert await asyncio.to_thread(entered.wait, 5)
            response = await asyncio.wait_for(task, 5)
            assert response.status_code == 503
            assert app.state.forecast_service._active == 1
        finally:
            unblock.set()
            await asyncio.gather(task, return_exceptions=True)
        async with asyncio.timeout(5):
            while app.state.forecast_service._active:
                await asyncio.sleep(0.01)
        assert app.state.forecast_service._active == 0

    asyncio.run(exercise())


def test_provider_opt_in_lifecycle_creates_and_closes_local_cache(tmp_path):
    async def exercise():
        app = create_app(Settings(provider_network=True, cache_path=tmp_path / "cache.sqlite"))
        async with app.router.lifespan_context(app):
            assert isinstance(app.state.forecast_service.sources, ProviderClient)
        assert app.state.forecast_service.sources.http.is_closed

    asyncio.run(exercise())


def test_deadline_retains_stale_cache_history(tmp_path):
    async def exercise():
        recorded = RecordedSources(CAPTURES, "stockholm")
        clock = FixedClock(recorded.at)
        hanging = False

        async def transport(req):
            if hanging:
                await asyncio.Event().wait()
            name = (
                "met-stockholm.json"
                if req.url.host == "api.met.no"
                else ("ovation.json" if req.url.path.endswith(".json") else "kp.txt")
            )
            return httpx.Response(
                200,
                content=(CAPTURES / name).read_bytes(),
                headers=recorded.entries[name]["headers"],
            )

        store = SnapshotStore(tmp_path / "cache.sqlite")
        client = ProviderClient(
            store,
            clock=clock,
            transport=httpx.MockTransport(transport),
            request_spacing=0,
            jitter=lambda: 0,
        )
        try:
            app = create_app(Settings(response_deadline=5), clock, client)
            assert (await request(app)).status_code == 200
            hanging = True
            clock = FixedClock(recorded.at + timedelta(minutes=1))
            client.clock = clock
            app = create_app(Settings(response_deadline=5), clock, client)
            shorten_collection_budget(app)
            response = await request(app)
            assert response.status_code == 200
            value = response.json()
            aurora = next(s for s in value["sources"] if s["product"] == Product.OVATION)
            assert aurora["status"] == "stale" and aurora["fetchedAt"] is not None
            assert value["now"]["action"] != "try_now"
            checker.check_forecast(value)
        finally:
            await client.close()
            store.close()

    asyncio.run(exercise())


def test_recorded_artifact_matches_http_recomputation():
    import json

    rows = json.loads((ROOT / "backend/tests/fixtures/replays/option-a-replay.json").read_text())
    for row in rows:
        assert_forecast_equal(asyncio.run(replay_forecast(row["city"], CAPTURES)), row)
        validate_example(row["forecast"], "Forecast")
        checker.check_forecast(row["forecast"])


def test_providers_see_only_two_decimal_coordinates():
    """Hosted, another client's precise point never reaches providers or the shared cache."""
    from aurora_backend.api.service import ForecastService
    from aurora_backend.domain.types import Location

    seen = []

    class Recording:
        async def get(self, product, *, latitude=None, longitude=None):
            seen.append((latitude, longitude))
            raise RuntimeError("synthetic")

    service = ForecastService(Recording(), coordinate_decimals=2)
    location = Location(latitude=69.649234, longitude=18.955321, timezone="Europe/Oslo")
    asyncio.run(service.collect(location, datetime(2026, 11, 13, 20)))
    assert seen and all(point == (69.65, 18.96) for point in seen)
