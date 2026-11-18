import copy
import importlib.util
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate

from aurora_backend.astronomy.periods import planning_periods
from aurora_backend.domain.types import Interval

ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((ROOT / "api/openapi.json").read_text())
module_spec = importlib.util.spec_from_file_location("checker", ROOT / "tools/check_contract.py")
checker = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(checker)


def validate_example(value, schema):
    full = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        **SPEC,
        "$ref": "#/components/schemas/" + schema,
    }
    Draft202012Validator(full, format_checker=FormatChecker()).validate(value)


def test_full_openapi_validation():
    validate(SPEC)


@pytest.mark.parametrize(
    "path", sorted((ROOT / "api/examples").glob("*.json")), ids=lambda p: p.stem
)
def test_examples_with_full_schema_and_semantics(path):
    value = json.loads(path.read_text())
    name = "Error" if path.stem.startswith("error-") else "Forecast"
    validate_example(value, name)
    if name == "Forecast":
        checker.check_forecast(value)
        darkness = [
            Interval(checker.time(w["interval"]["start"]), checker.time(w["interval"]["end"]))
            for p in value["planning"]
            for w in p["windows"]
        ]
        generated = checker.time(value["generatedAt"])
        coverage = Interval(generated, checker.time(value["planning"][-1]["period"]["end"]))
        if value["upcomingStatus"] != "unavailable":
            expected = planning_periods(
                generated, value["location"]["timezone"], darkness, darkness_coverage=coverage
            )
            assert [p.local_date.isoformat() for p in expected] == [
                p["localDate"] for p in value["planning"]
            ]


@pytest.mark.parametrize(
    "mutation", ["stale", "cloud", "missing_weather", "missing_activity", "daylight", "blocker"]
)
def test_optimistic_mutations_rejected(mutation):
    forecast = json.loads((ROOT / "api/examples/promising-now.json").read_text())
    forecast = copy.deepcopy(forecast)
    a = forecast["now"]
    if mutation == "stale":
        forecast["sources"][0]["status"] = "stale"
    elif mutation == "cloud":
        a["cloudCoverPercent"] = 71
    elif mutation == "missing_weather":
        a["cloudCoverPercent"] = None
    elif mutation == "missing_activity":
        a["factors"]["activity"] = "unknown"
    elif mutation == "daylight":
        a["solarAltitudeDegrees"] = 10
    else:
        a["reasons"].append(
            {"code": "cloud_obstruction", "effect": "blocker", "message": "Blocked"}
        )
    with pytest.raises(AssertionError):
        checker.check_forecast(forecast)


def test_overlapping_disjoint_windows_rejected():
    forecast = json.loads((ROOT / "api/examples/disjoint-darkness.json").read_text())
    second = forecast["planning"][0]["windows"][1]
    second["interval"]["start"] = forecast["planning"][0]["windows"][0]["interval"]["start"]
    second["segments"][0]["interval"]["start"] = second["interval"]["start"]
    with pytest.raises(AssertionError):
        checker.check_forecast(forecast)


def test_provider_fixture_provenance_and_integrity():
    import hashlib

    folder = ROOT / "backend/tests/fixtures/providers"
    manifest = json.loads((folder / "manifest.json").read_text())
    assert manifest["kind"] == "synthetic"
    assert manifest["capturedAt"] is None
    for entry in manifest["files"]:
        assert hashlib.sha256((folder / entry["name"]).read_bytes()).hexdigest() == entry["sha256"]
