"""Forecast-only MVP profile: only the forecast route and health checks are served."""

import asyncio
import json

import httpx
import pytest
from openapi_spec_validator import validate

from aurora_backend.api.app import create_app
from aurora_backend.config.settings import Settings


def test_mvp_default_routes_schema_and_lifecycle(tmp_path):
    # Synthetic fixtures need not be usable for the MVP.
    settings = Settings(fixture_dir=tmp_path / "no-fixtures")
    app = create_app(settings)
    assert settings.profile == "mvp"
    full = json.loads(settings.contract_path.read_text())
    spec = app.openapi()
    validate(spec)
    assert set(spec["paths"]) == {"/v1/forecast"}
    assert spec["paths"]["/v1/forecast"] == full["paths"]["/v1/forecast"]
    assert spec["components"] == full["components"]
    assert json.loads(settings.contract_path.read_text()) == full

    async def exercise():
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as client:
                for path, method in [
                    ("/v1/installations", "POST"),
                    ("/v1/installations/synthetic", "GET"),
                    ("/v1/installations/synthetic/subscription", "PUT"),
                    ("/dev/scenarios", "GET"),
                    ("/dev/replay/promising-now", "GET"),
                ]:
                    assert (await client.request(method, path, json={})).status_code == 404
                response = await client.get(
                    "/v1/forecast",
                    params={"latitude": 59, "longitude": 18, "timezone": "Europe/Stockholm"},
                )
                assert response.status_code == 200
                assert response.json()["now"]["factors"]["activity"] == "unavailable"
                assert (await client.get("/health/live")).status_code == 200

    asyncio.run(exercise())


def test_profile_rejects_mistakes_and_requires_development_fixtures(tmp_path):
    assert Settings.from_environment({"AURORA_PROFILE": "development"}).profile == "development"
    with pytest.raises(ValueError):
        Settings.from_environment({"AURORA_PROFILE": "production"})
    with pytest.raises(ValueError):
        Settings(profile="development", fixture_dir=tmp_path / "missing")
