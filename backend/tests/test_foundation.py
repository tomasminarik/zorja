import asyncio
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
from pydantic import TypeAdapter, ValidationError

from aurora_backend.api.app import create_app
from aurora_backend.astronomy.periods import planning_periods
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.domain.types import CloudCoverPercent, Interval, Location

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "api" / "examples"


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def periods(at, windows=(), coverage=None, timezone="Europe/Stockholm"):
    timestamp = instant(at)
    return planning_periods(
        timestamp,
        timezone,
        windows,
        darkness_coverage=coverage or Interval(timestamp, timestamp + timedelta(days=4)),
    )


def test_current_night_retained_after_midnight():
    window = Interval(instant("2026-10-11T18:00:00Z"), instant("2026-10-12T03:00:00Z"))
    result = periods("2026-10-12T01:00:00Z", [window])
    assert [p.local_date.isoformat() for p in result] == ["2026-10-11", "2026-10-12", "2026-10-13"]


def test_finished_night_omitted_at_exact_half_open_end():
    window = Interval(instant("2026-10-11T18:00:00Z"), instant("2026-10-12T03:00:00Z"))
    assert periods("2026-10-12T03:00:00Z", [window])[0].local_date.isoformat() == "2026-10-12"


def test_later_darkness_before_noon_retains_night():
    window = Interval(instant("2026-10-12T02:00:00Z"), instant("2026-10-12T03:00:00Z"))
    assert periods("2026-10-12T01:00:00Z", [window])[0].local_date.isoformat() == "2026-10-11"


@pytest.mark.parametrize(
    ("at", "expected"),
    [
        ("2026-10-12T10:00:00Z", "2026-10-12"),
        ("2026-06-12T01:00:00Z", "2026-06-12"),
    ],
)
def test_noon_and_no_darkness_do_not_skip_seasons(at, expected):
    assert periods(at)[0].local_date.isoformat() == expected


def test_continuous_darkness_keeps_current_period_before_noon():
    at = instant("2026-12-12T01:00:00Z")
    window = Interval(at - timedelta(days=1), at + timedelta(days=4))
    assert periods("2026-12-12T01:00:00Z", [window])[0].local_date.isoformat() == "2026-12-11"


@pytest.mark.parametrize(
    ("at", "hours"),
    [
        ("2026-03-28T12:00:00Z", 23),
        ("2026-10-24T12:00:00Z", 25),
    ],
)
def test_dst_periods_use_local_calendar_noon(at, hours):
    result = periods(at)
    assert (result[0].interval.end - result[0].interval.start).total_seconds() == hours * 3600
    assert result[0].interval.end == result[1].interval.start


def test_unknown_darkness_is_not_no_darkness():
    at = instant("2026-10-12T01:00:00Z")
    with pytest.raises(ValueError, match="coverage"):
        periods("2026-10-12T01:00:00Z", coverage=Interval(at, at + timedelta(minutes=1)))


@pytest.mark.parametrize("timestamp", [datetime(2026, 10, 12), instant("2026-10-12T00:00:00Z")])
def test_aware_strictly_increasing_intervals(timestamp):
    with pytest.raises(ValueError):
        Interval(timestamp, timestamp)


def test_interval_normalizes_offsets_and_excludes_end():
    interval = Interval(instant("2026-10-12T12:00:00+02:00"), instant("2026-10-12T11:00:00Z"))
    assert interval.start.tzinfo == UTC
    assert interval.contains(interval.start)
    assert not interval.contains(interval.end)


@pytest.mark.parametrize(
    "latitude,longitude,timezone",
    [
        (91, 0, "Europe/Stockholm"),
        (0, -181, "Europe/Stockholm"),
        (float("nan"), 0, "Europe/Stockholm"),
        (0, float("inf"), "Europe/Stockholm"),
        (0, 0, "UTC+2"),
        (0, 0, "../etc/passwd"),
    ],
)
def test_bad_locations_rejected(latitude, longitude, timezone):
    with pytest.raises(ValidationError):
        Location(latitude=latitude, longitude=longitude, timezone=timezone)


@pytest.mark.parametrize("value", [-1, 101, float("nan"), float("inf")])
def test_percent_is_not_unbounded_or_missing(value):
    with pytest.raises(ValidationError):
        TypeAdapter(CloudCoverPercent).validate_python(value)


@pytest.mark.parametrize(
    "env",
    [
        {"AURORA_MODE": "live"},
        {"AURORA_HOST": "0.0.0.0"},
        {"AURORA_PORT": "-1"},
        {"AURORA_PROFILE": "development", "AURORA_FIXTURE_DIR": "/nonexistent"},
        {"AURORA_MOD": "offline"},
    ],
)
def test_unsafe_or_mistyped_configuration_fails(env):
    with pytest.raises(ValueError):
        Settings.from_environment(env)


@pytest.fixture
def client():
    clock = FixedClock(instant("2026-10-12T10:00:00Z"))
    app = create_app(Settings(profile="development", fixture_dir=FIXTURES), clock)

    class InProcessClient:
        def get(self, path):
            async def request():
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=app), base_url="http://test"
                ) as session:
                    return await session.get(path)

            return asyncio.run(request())

    return InProcessClient()


def test_health_distinguishes_live_process_from_forecast_readiness(client):
    response = client.get("/health/live")
    assert response.status_code == 200
    assert response.json()["time"] == "2026-10-12T10:00:00+00:00"
    assert client.get("/health/ready").status_code == 200


def test_fixture_times_and_locations_never_rewritten(client):
    import json

    response = client.get("/dev/replay/promising-now")
    assert response.status_code == 200
    assert response.headers["X-Aurora-Synthetic"] == "true"
    assert response.headers["Cache-Control"] == "private, no-store"
    assert response.json() == json.loads((FIXTURES / "promising-now.json").read_text())


def test_error_scenario_preserves_body_and_http_failure(client):
    response = client.get("/dev/replay/error-503")
    assert response.status_code == 503
    assert response.headers["Retry-After"] == "60"
    assert response.headers["X-Aurora-Synthetic"] == "true"


@pytest.mark.parametrize(
    "query",
    [
        "latitude=nan&longitude=0&timezone=Europe/Stockholm",
        "latitude=0&longitude=181&timezone=Europe/Stockholm",
        "latitude=0&longitude=0&timezone=UTC%2B2",
        "latitude=0",
        "latitude=invalid&longitude=0&timezone=Europe/Stockholm",
    ],
)
def test_http_invalid_query_is_safe_contract_error(client, query):
    response = client.get("/v1/forecast?" + query)
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"
    assert response.json()["requestId"] == response.headers["X-Request-ID"]
    assert "latitude" not in response.json()["message"]


def test_forecast_never_promotes_replay_to_real_output(client):
    response = client.get("/v1/forecast?latitude=59&longitude=18&timezone=Europe/Stockholm")
    assert response.status_code == 200
    assert response.json()["now"]["factors"]["activity"] == "unavailable"
    assert "X-Aurora-Synthetic" not in response.headers


def test_unknown_replay_is_allowlisted(client):
    assert client.get("/dev/replay/not-a-fixture").status_code == 400


def test_network_binding_requires_explicit_opt_in():
    config = Settings.from_environment({"AURORA_HOST": "0.0.0.0", "AURORA_ALLOW_NETWORK": "true"})
    assert config.host == "0.0.0.0" and config.allow_network


def test_pinned_timezone_database_rejects_host_aliases():
    from aurora_backend.domain.timezones import iana_zone

    assert iana_zone("Europe/Stockholm").key == "Europe/Stockholm"
    with pytest.raises(ValueError):
        iana_zone("localtime")


def test_clock_rejects_naive_time_and_converts_offset():
    with pytest.raises(ValueError):
        FixedClock(datetime(2026, 10, 12))
    assert FixedClock(instant("2026-10-12T12:00:00+02:00")).now() == instant("2026-10-12T10:00:00Z")


def test_boolean_is_not_a_coordinate_or_percentage():
    with pytest.raises(ValidationError):
        Location(latitude=True, longitude=0, timezone="Europe/Stockholm")
    with pytest.raises(ValidationError):
        TypeAdapter(CloudCoverPercent).validate_python(False)
