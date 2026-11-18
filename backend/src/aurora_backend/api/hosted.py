"""The hosted service at api.zorja.app (Vercel + Upstash); no import-time cloud access."""

from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import AsyncExitStack, asynccontextmanager
from datetime import timedelta
from uuid import uuid4

import httpx
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response

from aurora_backend.api.app import create_app
from aurora_backend.collection.endpoint import Collector
from aurora_backend.collection.signatures import QStashVerifier
from aurora_backend.config.hosted import HostedSettings
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import Clock, SystemClock
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product
from aurora_backend.providers.redis_store import RedisProviderStore, UpstashREST

# Browsers may call the hosted forecast only from the zorja.app site (decisions, 2026-11-12).
SITE_ORIGINS = ("https://zorja.app",)

HOSTED_REUSE = {Product.OVATION: timedelta(minutes=15), Product.KP: timedelta(minutes=60)}


@asynccontextmanager
async def hosted_application(
    config: HostedSettings,
    *,
    clock: Clock | None = None,
    redis_transport: httpx.AsyncBaseTransport | None = None,
    provider_transport: httpx.AsyncBaseTransport | None = None,
    collector_transport: httpx.AsyncBaseTransport | None = None,
) -> AsyncIterator[FastAPI]:
    """Enter once per serving lifecycle on its event loop, then close every owner.

    The platform must run ASGI lifespan so this is entered and exited exactly once.
    No SQLite, registration store, schedule, provisioning or control-plane call.
    """
    timer = clock or SystemClock()
    async with AsyncExitStack() as resources:
        commands = UpstashREST(config.redis_url, config.redis_token, transport=redis_transport)
        resources.push_async_callback(commands.close)
        foreground = RedisProviderStore(
            commands, namespace=config.namespace, limits=config.limits, clock=timer
        )
        # Forecasts reuse the collector's recent global data (docs/decisions.md, 2026-11-03);
        # the collector itself refreshes on the provider's HTTP schedule.
        client = ProviderClient(
            foreground, clock=timer, transport=provider_transport, reuse=HOSTED_REUSE
        )
        resources.push_async_callback(client.close)
        collector = None
        if config.collection_enabled:
            assert config.collector_destination and config.signing_current and config.signing_next
            background = RedisProviderStore(
                commands,
                namespace=config.namespace,
                limits=config.limits,
                clock=timer,
                lane="collector",
            )
            # Separate clients own their provider transports, locks and local caches.
            # Only the command transport and immutable budget policy are shared.
            collection_client = ProviderClient(
                background, clock=timer, transport=collector_transport
            )
            resources.push_async_callback(collection_client.close)
            verifier = QStashVerifier(
                config.collector_destination, config.signing_current, config.signing_next
            )
            collector = Collector(verifier, background, collection_client, timer)
        app = create_app(
            Settings(
                profile="mvp",
                provider_network=True,
                contract_path=config.contract_path,
                response_deadline=config.response_deadline,
            ),
            clock=timer,
            sources=client,
            shared_admission=foreground,
            collector=collector,
            internal_routes=False,
        )
        # Deployment policy only: the immutable contract and local GET remain.
        app.openapi()["paths"]["/v1/forecast"].pop("get", None)

        @app.middleware("http")
        async def post_only(
            request: Request, call_next: Callable[[Request], Awaitable[Response]]
        ) -> Response:
            if request.method == "GET" and request.scope["path"].rstrip("/") == "/v1/forecast":
                request_id = uuid4().hex
                return JSONResponse(
                    {
                        "code": "invalid_request",
                        "message": "Use POST for hosted forecasts",
                        "requestId": request_id,
                    },
                    status_code=405,
                    headers={
                        "Allow": "POST",
                        "Cache-Control": "private, no-store",
                        "X-Request-ID": request_id,
                    },
                )
            return await call_next(request)

        # Outermost, so a preflight is answered before the POST-only rule, admission
        # and any Redis or provider work. Other origins get no CORS headers.
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(SITE_ORIGINS),
            allow_methods=["POST"],
            allow_headers=["Content-Type"],
            expose_headers=["Retry-After", "X-Request-ID"],
            max_age=86400,
        )

        async with app.router.lifespan_context(app):
            yield app


def create_hosted_app(config: HostedSettings) -> FastAPI:
    """Explicit ASGI factory for the Vercel entrypoint, not autodiscovered.

    The platform must run ASGI lifespan. Requests outside a serving lifecycle fail
    closed without creating a client or using SQLite. No background task is started.
    """
    from starlette.types import Receive, Scope, Send

    inner: FastAPI | None = None

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        nonlocal inner
        async with hosted_application(config) as running:
            inner = running
            try:
                yield
            finally:
                inner = None

    async def dispatch(scope: Scope, receive: Receive, send: Send) -> None:
        if inner is None:
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 1013})
                return
            await JSONResponse(
                {"status": "hosting_unavailable"},
                status_code=503,
                headers={"Cache-Control": "private, no-store", "Retry-After": "60"},
            )(scope, receive, send)
            return
        await inner(scope, receive, send)

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.mount("/", dispatch)
    return app
