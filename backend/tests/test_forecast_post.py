"""POST transport parity, private validation and shared admission boundaries."""

import asyncio
import json

import httpx
import pytest
from test_contract import SPEC, checker, validate_example
from test_forecast_api import CAPTURES, QUERY

from aurora_backend.api.app import create_app
from aurora_backend.api.replay import RecordedSources
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.budgets import SharedLimits


def test_post_matches_get_and_uses_the_same_capacity():
    async def exercise():
        sources = RecordedSources(CAPTURES, "stockholm")
        app = create_app(Settings(), FixedClock(sources.at), sources)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            get = await client.get("/v1/forecast", params=QUERY)
            post = await client.post("/v1/forecast", json=QUERY)
            assert get.status_code == post.status_code == 200
            assert get.json() == post.json()
            validate_example(post.json(), "Forecast")
            checker.check_forecast(post.json())
            assert post.headers["Cache-Control"] == "private, no-store"
            assert post.headers["X-Request-ID"] != get.headers["X-Request-ID"]
            # Both methods consumed the same local admission pool.
            assert app.state.forecast_service.metrics["requests"] == 2
            app.state.forecast_service._requests = 60
            denied = await client.post("/v1/forecast", json=QUERY)
            assert denied.status_code == 429
            assert denied.headers["Retry-After"] == "60"
            validate_example(denied.json(), "Error")

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "body,headers,query",
    [
        (b"", {}, ""),
        (b"{}", {}, ""),
        (b"null", {}, ""),
        (b"[]", {}, ""),
        (json.dumps({**QUERY, "latitude": "59.3293"}).encode(), {}, ""),
        (json.dumps({**QUERY, "latitude": True}).encode(), {}, ""),
        (json.dumps({**QUERY, "latitude": 91}).encode(), {}, ""),
        (json.dumps({**QUERY, "longitude": float("nan")}).encode(), {}, ""),
        (json.dumps({**QUERY, "timezone": "private-invalid-zone"}).encode(), {}, ""),
        (json.dumps({**QUERY, "at": "private-evaluation-time"}).encode(), {}, ""),
        (b'{"latitude":1,"latitude":2,"longitude":3,"timezone":"UTC"}', {}, ""),
        (b"\xff", {}, ""),
        (b"[" * 1000, {}, ""),
        (b" " * 1025, {}, ""),
        (json.dumps(QUERY).encode(), {"content-type": "text/plain"}, ""),
        (json.dumps(QUERY).encode(), {"content-encoding": "gzip"}, ""),
        (json.dumps(QUERY).encode(), {}, "?latitude=59"),
    ],
)
def test_invalid_post_never_echoes_body_or_starts_provider_work(body, headers, query):
    class Forbidden:
        calls = 0

        async def get(self, *args, **kwargs):
            self.calls += 1
            raise AssertionError("Invalid input must not reach providers")

    async def exercise():
        sources = Forbidden()
        app = create_app(Settings(), sources=sources)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.post(
                "/v1/forecast" + query,
                content=body,
                headers={"content-type": "application/json", **headers},
            )
        assert response.status_code == 400
        assert response.json() == {
            "code": "invalid_request",
            "message": "A valid forecast JSON body is required",
            "requestId": response.headers["X-Request-ID"],
        }
        validate_example(response.json(), "Error")
        assert response.headers["Cache-Control"] == "private, no-store"
        assert app.state.forecast_service.metrics.get("requests", 0) == 0
        assert sources.calls == 0

    asyncio.run(exercise())


def test_post_contract_reuses_get_responses_and_appears_in_mvp_schema():
    spec = create_app(Settings()).openapi()
    operations = spec["paths"]["/v1/forecast"]
    assert operations["post"] == SPEC["paths"]["/v1/forecast"]["post"]
    assert operations["post"]["responses"] == operations["get"]["responses"]
    assert "parameters" not in operations["post"]


def test_streamed_body_limit_applies_without_content_length():
    async def exercise():
        app = create_app(Settings())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            for size, status in [(1024, 200), (1025, 400)]:

                async def chunks(size=size):
                    raw = json.dumps(QUERY).encode()
                    yield raw
                    yield b" " * (size - len(raw))

                response = await client.post(
                    "/v1/forecast", content=chunks(), headers={"content-type": "application/json"}
                )
                assert response.status_code == status
            missing_type = await client.post("/v1/forecast", content=json.dumps(QUERY))
            assert missing_type.status_code == 400

    asyncio.run(exercise())


@pytest.mark.parametrize("admission,status", [("rate_limited", 429), ("storage_unavailable", 503)])
def test_post_shared_capacity_denial_precedes_provider_work(admission, status):
    class Shared:
        limits = SharedLimits()
        lane = "forecast"
        calls = 0

        async def admit_forecast(self, owner):
            self.calls += 1
            return admission

    async def exercise():
        shared = Shared()
        app = create_app(Settings(), shared_admission=shared)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.post("/v1/forecast", json=QUERY)
        assert shared.calls == 1
        assert response.status_code == status
        assert response.headers["Retry-After"] == "60"
        validate_example(response.json(), "Error")
        assert app.state.forecast_service._active == 0

    asyncio.run(exercise())
