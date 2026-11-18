"""Local lifecycle and configuration checks; all transports are synthetic."""

import asyncio
import json
from pathlib import Path

import httpx
import pytest

from aurora_backend.api.hosted import hosted_application
from aurora_backend.config.hosted import HostedSettings
from aurora_backend.config.settings import Settings

CONTRACT = Path(__file__).resolve().parents[2] / "api/openapi.json"
SECRET = "synthetic-secret-never-print-" + "x" * 32


def environment(**extra):
    return {
        "AURORA_HOSTED_REDIS_URL": "https://synthetic.upstash.io",
        "AURORA_HOSTED_REDIS_TOKEN": SECRET,
        "AURORA_HOSTED_NAMESPACE": "synthetic-hosted-v2",
        "AURORA_HOSTED_CONTRACT_PATH": str(CONTRACT),
        **extra,
    }


def configured(**extra):
    return HostedSettings.from_environment(environment(**extra))


class Transport(httpx.AsyncBaseTransport):
    def __init__(self):
        self.closed = 0
        self.calls = 0

    async def handle_async_request(self, request):
        self.calls += 1
        raise AssertionError("Unexpected network access")

    async def aclose(self):
        self.closed += 1


@pytest.mark.parametrize(
    "extra",
    [
        {"AURORA_PROFILE": "development"},
        {"AURORA_PROVIDER_NETWORK": "true"},
        {"AURORA_HOSTED_REDIS_TOKEN": ""},
        {"AURORA_HOSTED_REDIS_TOKEN": SECRET + "\n"},
        {"AURORA_HOSTED_REDIS_URL": "http://synthetic.upstash.io"},
        {"AURORA_HOSTED_REDIS_URL": "https://synthetic.upstash.io/?secret=" + SECRET},
        {"AURORA_HOSTED_REDIS_URL": "https://" + SECRET + "@synthetic.upstash.io"},
        {"AURORA_HOSTED_NAMESPACE": ""},
        {"AURORA_HOSTED_COLLECTION_ENABLED": "true"},
        {"AURORA_HOSTED_SIGNING_CURRENT": SECRET},
        {"AURORA_HOSTED_RESPONSE_DEADLINE": "11"},
        {"AURORA_HOSTED_UNKNOWN": SECRET},
    ],
)
def test_invalid_environment_is_generic_and_redacted(extra):
    with pytest.raises(ValueError) as failure:
        configured(**extra)
    assert (
        str(failure.value) == "Invalid Aurora hosted configuration"
        or str(failure.value) == "Unsupported Aurora hosted configuration"
    )
    assert SECRET not in str(failure.value)
    assert failure.value.__cause__ is None


def test_secrets_redacted_and_local_configuration_stays_separate():
    settings = configured()
    assert SECRET not in repr(settings)
    assert SECRET not in settings.model_dump_json()
    assert settings.collection_enabled is False
    assert Settings().provider_network is False
    with pytest.raises(ValueError):
        Settings.from_environment(environment())


@pytest.mark.parametrize("exit_kind", ["normal", "exception", "cancelled"])
def test_owned_lifecycle_closes_on_every_exit_without_network_or_sqlite(exit_kind, monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Hosted mode must not open SQLite")

    monkeypatch.setattr("aurora_backend.api.app.SnapshotStore", forbidden)

    async def run():
        redis, provider = Transport(), Transport()
        try:
            async with hosted_application(
                configured(), redis_transport=redis, provider_transport=provider
            ) as app:
                assert app.state.forecast_service.sources.store.limits == configured().limits
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
                ) as http:
                    assert (await http.get("/health/ready")).json()["providerNetwork"] is True
                    assert (await http.post("/internal/collect/ovation")).status_code == 404
                    assert (await http.post("/v1/installations")).status_code == 404
                    assert (await http.get("/dev/scenarios")).status_code == 404
                    assert set(app.openapi()["paths"]) == {"/v1/forecast"}
                    for internal in ("/openapi.json", "/docs", "/redoc", "/metrics"):
                        assert (await http.get(internal)).status_code == 404
                    assert (await http.get("/health/providers")).status_code == 404
                    for path in ("/v1/forecast", "/v1/forecast/"):
                        response = await http.get(path, params={"latitude": 59, "longitude": 18})
                        assert response.status_code == 405
                        assert response.headers["allow"] == "POST"
                        assert response.headers["cache-control"] == "private, no-store"
                        assert (
                            "latitude" not in response.text and "location" not in response.headers
                        )
                    assert set(app.openapi()["paths"]["/v1/forecast"]) == {"post"}
                if exit_kind == "exception":
                    raise RuntimeError("Synthetic serving failure")
                if exit_kind == "cancelled":
                    raise asyncio.CancelledError
        except (RuntimeError, asyncio.CancelledError):
            if exit_kind == "normal":
                raise
        assert redis.closed == provider.closed == 1
        assert redis.calls == provider.calls == 0

    asyncio.run(run())


def test_bad_contract_closes_partially_initialized_resources():
    async def run():
        redis, provider = Transport(), Transport()
        with pytest.raises(FileNotFoundError):
            async with hosted_application(
                configured(AURORA_HOSTED_CONTRACT_PATH="/synthetic-missing-contract.json"),
                redis_transport=redis,
                provider_transport=provider,
            ):
                pytest.fail("Invalid startup must not serve")
        assert redis.closed == provider.closed == 1
        assert redis.calls == provider.calls == 0

    asyncio.run(run())


def test_collection_opt_in_uses_same_budget_namespace_and_authenticates_before_io():
    async def run():
        redis, provider, collection = Transport(), Transport(), Transport()
        settings = configured(
            AURORA_HOSTED_COLLECTION_ENABLED="true",
            AURORA_HOSTED_COLLECTOR_DESTINATION=(
                "https://synthetic.example/internal/collect/ovation"
            ),
            AURORA_HOSTED_SIGNING_CURRENT=SECRET,
            AURORA_HOSTED_SIGNING_NEXT="synthetic-next-key-" + "n" * 32,
        )
        async with hosted_application(
            settings,
            redis_transport=redis,
            provider_transport=provider,
            collector_transport=collection,
        ) as app:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                response = await http.post(
                    "/internal/collect/ovation", content=b'{"task":"ovation"}'
                )
                assert response.status_code == 401
                assert response.headers["cache-control"] == "private, no-store"
        assert redis.closed == provider.closed == collection.closed == 1
        assert redis.calls == provider.calls == collection.calls == 0

    asyncio.run(run())


def test_asgi_factory_requires_lifespan_and_resets_after_shutdown(monkeypatch):
    from aurora_backend.api import hosted

    real_lifecycle = hosted.hosted_application
    redis, provider = Transport(), Transport()

    def local_lifecycle(config):
        return real_lifecycle(config, redis_transport=redis, provider_transport=provider)

    monkeypatch.setattr(hosted, "hosted_application", local_lifecycle)

    async def run():
        app = hosted.create_hosted_app(configured())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
        ) as http:
            assert (await http.get("/health/ready")).status_code == 503
            async with app.router.lifespan_context(app):
                assert (await http.get("/health/ready")).status_code == 200
                assert (await http.get("/openapi.json")).status_code == 404
            assert (await http.get("/health/ready")).status_code == 503
        assert redis.closed == provider.closed == 1
        assert redis.calls == provider.calls == 0

    asyncio.run(run())


def test_foreground_budget_denial_never_accesses_provider():
    async def run():
        calls = []

        def denied(request):
            calls.append(request)
            # Monthly usage already above the forecast allowance.
            over = [{"result": 10**9}, {"result": 0}, {"result": 1}, {"result": [None, None]}]
            return httpx.Response(200, json=over + [{"result": 1}, {"result": 1}])

        provider = Transport()
        async with hosted_application(
            configured(), redis_transport=httpx.MockTransport(denied), provider_transport=provider
        ) as app:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                for _ in range(2):
                    response = await http.post(
                        "/v1/forecast",
                        json={"latitude": 59, "longitude": 18, "timezone": "Europe/Stockholm"},
                    )
                    assert response.status_code == 503
                    assert response.headers["retry-after"] == "60"
                    assert SECRET not in response.text
            # The second request is stopped by the process circuit, without Redis IO.
            assert len(calls) == 1
        assert provider.calls == 0
        assert provider.closed == 1

    asyncio.run(run())


@pytest.mark.parametrize("path", ["/v1/forecast", "/v1/forecast/", "/v1/forecast//"])
def test_hosted_get_is_rejected_before_io_and_openapi_only_advertises_post(path):
    async def run():
        redis, provider = Transport(), Transport()
        async with hosted_application(
            configured(), redis_transport=redis, provider_transport=provider
        ) as app:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                response = await http.get(
                    path,
                    params={
                        "latitude": 60.123456,
                        "longitude": 15.654321,
                        "timezone": "Europe/Stockholm",
                    },
                    headers={"X-Request-ID": "synthetic-untrusted-input"},
                )
                assert response.status_code == 405
                assert response.headers["allow"] == "POST"
                assert response.headers["cache-control"] == "private, no-store"
                request_id = response.headers["x-request-id"]
                assert len(request_id) == 32
                assert request_id != "synthetic-untrusted-input"
                assert response.json() == {
                    "code": "invalid_request",
                    "message": "Use POST for hosted forecasts",
                    "requestId": request_id,
                }
                spec = app.openapi()
                assert "get" not in spec["paths"]["/v1/forecast"]
                assert "post" in spec["paths"]["/v1/forecast"]
                # Runtime projection must not mutate the frozen/local authority.
                assert "get" in json.loads(CONTRACT.read_text())["paths"]["/v1/forecast"]
        assert redis.calls == provider.calls == 0
        assert redis.closed == provider.closed == 1

    asyncio.run(run())


def test_site_origin_preflight_and_post_get_cors_before_io():
    async def run():
        redis, provider = Transport(), Transport()
        async with hosted_application(
            configured(), redis_transport=redis, provider_transport=provider
        ) as app:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                preflight = {
                    "Origin": "https://zorja.app",
                    "Access-Control-Request-Method": "POST",
                    "Access-Control-Request-Headers": "content-type",
                }
                ok = await http.options("/v1/forecast", headers=preflight)
                assert ok.status_code == 200
                assert ok.headers["access-control-allow-origin"] == "https://zorja.app"
                assert "POST" in ok.headers["access-control-allow-methods"]
                assert ok.headers["access-control-max-age"] == "86400"

                other = await http.options(
                    "/v1/forecast", headers={**preflight, "Origin": "https://example.org"}
                )
                assert other.status_code == 400
                assert "access-control-allow-origin" not in other.headers

                # A real response from the site carries the header too (here the GET 405).
                rejected = await http.get("/v1/forecast", headers={"Origin": "https://zorja.app"})
                assert rejected.status_code == 405
                assert rejected.headers["access-control-allow-origin"] == "https://zorja.app"
                assert "x-request-id" in rejected.headers["access-control-expose-headers"].lower()
                elsewhere = await http.get(
                    "/v1/forecast", headers={"Origin": "https://example.org"}
                )
                assert "access-control-allow-origin" not in elsewhere.headers
        assert redis.calls == provider.calls == 0

    asyncio.run(run())
