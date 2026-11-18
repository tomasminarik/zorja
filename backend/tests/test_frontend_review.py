import asyncio
import importlib.util
import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import pytest
from forecast_assertions import assert_forecast_equal
from test_contract import ROOT, checker, validate_example

from aurora_backend.api.forecast import build_forecast, global_kp_context
from aurora_backend.api.replay import RecordedSources
from aurora_backend.domain.types import Interval, Location
from aurora_backend.providers.models import KpBin, Product, SourceState

spec = importlib.util.spec_from_file_location(
    "examples", ROOT / "backend/tools/generate_api_examples.py"
)
examples = importlib.util.module_from_spec(spec)
spec.loader.exec_module(examples)


@pytest.mark.parametrize("name", examples.SCENARIOS)
def test_examples_equal_real_evaluator_serialization(name):
    value = examples.synthetic_forecast(name)
    assert_forecast_equal(value, json.loads((ROOT / "api/examples" / f"{name}.json").read_text()))
    validate_example(value, "Forecast")
    checker.check_forecast(value)
    assert value["minimumRevalidationIntervalSeconds"] == 60
    assert {s["role"] for s in value["sources"]} == {
        "aurora_short_term",
        "aurora_planning",
        "weather",
        "darkness",
    }
    assert value["now"]["confidence"] != "moderate"


def test_polling_floor_never_extends_evidence_or_try_now():
    value = examples.synthetic_forecast("promising-now")
    assert value["now"]["action"] == "try_now"
    evidence = value["now"]["activityEvidence"]["supportedInterval"]
    assert (
        checker.time(value["generatedAt"])
        < checker.time(value["refreshAfter"])
        <= checker.time(evidence["end"])
    )
    assert value["minimumRevalidationIntervalSeconds"] == 60
    assert value["now"]["interval"]["end"] == value["refreshAfter"]
    single = examples.synthetic_forecast("promising-now", continuous=False)
    assert single["now"]["factors"]["activity"] == "not_covered"
    assert single["now"]["action"] != "try_now"


def test_kp_basis_describes_global_context_without_supporting_local_activity():
    value = examples.synthetic_forecast("promising-now")
    segments = value["upcoming"]["segments"] + [
        s for n in value["planning"] for w in n["windows"] for s in w["segments"]
    ]
    unsupported = [s for s in segments if s["factors"]["activity"] != "supported"]
    assert all(s["basis"] == "planning" for s in unsupported)
    assert all(s["rating"] == "unknown" for s in unsupported)
    assert all(s["action"] != "try_now" for s in segments)


def test_unavailable_kp_reason_links_to_source_not_factor_evidence():
    from aurora_backend.api.replay import replay_forecast

    value = asyncio.run(
        replay_forecast("stockholm", ROOT / "backend/tests/fixtures/providers/captured")
    )["forecast"]
    kp = next(s for s in value["sources"] if s["role"] == "aurora_planning")
    assert kp["status"] == "unavailable"
    assert any(r.get("sourceId") == kp["id"] for r in value["now"]["reasons"])
    assert kp["id"] not in value["now"]["sourceIds"]
    checker.check_forecast(value)


@pytest.mark.parametrize(
    "case, expected",
    [
        ("full", "available"),
        ("partial", "partial"),
        ("empty", "not_covered"),
        ("stale", "stale"),
        ("expired", "stale"),
        ("unavailable", "unavailable"),
    ],
)
def test_global_kp_preserves_bins_and_gaps(case, expected):
    captures = RecordedSources(ROOT / "backend/tests/fixtures/providers/captured", "stockholm")
    # The recorded Kp is rejected; use synthetic normalized Kp on the same public location.
    result = asyncio.run(captures.get(Product.WEATHER, latitude=59.3293, longitude=18.0686))
    at = datetime(2026, 10, 12, 21, tzinfo=UTC)
    bins = tuple(KpBin(at + timedelta(hours=h), at + timedelta(hours=h + 3), 9) for h in (0, 3, 6))
    result = replace(
        result,
        snapshot=replace(
            result.snapshot,
            product=Product.KP,
            issued_at=at - timedelta(hours=1),
            observed_at=None,
            forecast_at=None,
            fetched_at=at,
            coordinates=None,
            weather=(),
            kp=bins,
            valid_from=at,
            valid_until=at + timedelta(hours=9),
        ),
        health=replace(
            result.health, state=SourceState.FRESH, cache_expires_at=at + timedelta(minutes=5)
        ),
    )
    if case == "partial":
        result = replace(result, snapshot=replace(result.snapshot, kp=(bins[0], bins[2])))
    elif case == "empty":
        result = replace(result, snapshot=replace(result.snapshot, kp=()))
    elif case == "stale":
        result = replace(result, health=replace(result.health, state=SourceState.STALE))
    elif case == "expired":
        result = replace(result, health=replace(result.health, cache_expires_at=at))
    elif case == "unavailable":
        result = None
    period = Interval(at + timedelta(hours=1), at + timedelta(hours=8))
    value = global_kp_context(result, period, at)
    assert value["status"] == expected
    if value["bins"]:
        assert value["bins"][0]["interval"]["start"] == "2026-10-12T21:00:00Z"
        assert value["bins"][0]["interval"]["end"] == "2026-10-13T00:00:00Z"
    if case == "unavailable":
        assert value["bins"] == []


@pytest.mark.parametrize("at, hours", [("2026-03-28T11:00:00Z", 23), ("2026-10-24T10:00:00Z", 25)])
def test_kp_unknown_context_and_dst_periods(at, hours):
    location = Location(latitude=59.3293, longitude=18.0686, timezone="Europe/Stockholm")
    value = build_forecast(location, datetime.fromisoformat(at), {})
    period = value["planning"][0]["period"]
    assert (
        checker.time(period["end"]) - checker.time(period["start"])
    ).total_seconds() == hours * 3600
    assert all(n["globalKpContext"]["status"] == "unavailable" for n in value["planning"])
    validate_example(value, "Forecast")
    checker.check_forecast(value)


def test_synthetic_error_is_the_real_http_failure_shape():
    value = asyncio.run(examples.synthetic_error())
    assert value == json.loads((ROOT / "api/examples/error-503.json").read_text())
    validate_example(value, "Error")


def test_fixture_tolerance_only_accepts_solar_roundoff():
    assert_forecast_equal({"solarAltitudeDegrees": -12.0 + 3e-14}, {"solarAltitudeDegrees": -12.0})
    for actual, expected in (
        ({"solarAltitudeDegrees": -12.0 + 1e-8}, {"solarAltitudeDegrees": -12.0}),
        ({"kp": 3.0 + 3e-14}, {"kp": 3.0}),
        ({"action": "try_now"}, {"action": "check_later"}),
    ):
        with pytest.raises(AssertionError):
            assert_forecast_equal(actual, expected)
