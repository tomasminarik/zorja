"""Freeze compatibility and explicit abstention at unsupported time coverage."""

import asyncio
import copy
import json

import pytest
from test_contract import ROOT, SPEC, checker, validate_example

from aurora_backend.api.replay import replay_forecast

BASELINE = json.loads((ROOT / "api/frozen/v1-openapi.json").read_text())


def compatible(old, new, path=()):
    if isinstance(old, dict):
        assert isinstance(new, dict)
        for key, value in old.items():
            if key in {"description", "summary"} and not (path and path[-1] == "properties"):
                continue
            assert key in new, path + (key,)
            compatible(value, new[key], path + (key,))
        if not path or path[-1] == "properties":
            # Adding optional properties is allowed; adding new required fields is
            # caught by the parent schema's unchanged required array below.
            return
        # A path may gain an additive HTTP operation; every existing operation
        # remains recursively frozen, including parameters and response schemas.
        additions = set(new) - set(old)
        if len(path) == 1 and path[0].startswith("/"):
            assert additions <= {"get", "post", "put", "patch", "delete", "head", "options"}
        else:
            assert not additions, path
    else:
        assert old == new, path


def test_frozen_v1_contract_is_compatible():
    compatible(BASELINE["paths"], SPEC["paths"])
    compatible(BASELINE["components"]["schemas"], SPEC["components"]["schemas"])
    assert SPEC["info"]["version"] == "1.0.0"


def test_freeze_guard_accepts_optional_extension_and_rejects_required_field():
    new = copy.deepcopy(SPEC)
    new["components"]["schemas"]["Forecast"]["properties"]["optionalFutureField"] = {
        "type": "string"
    }
    compatible(BASELINE["components"]["schemas"], new["components"]["schemas"])
    new["components"]["schemas"]["Forecast"]["required"].append("optionalFutureField")
    with pytest.raises(AssertionError):
        compatible(BASELINE["components"]["schemas"], new["components"]["schemas"])


def test_freeze_guard_allows_new_operation_but_still_protects_existing_get():
    new = copy.deepcopy(SPEC["paths"])
    compatible(BASELINE["paths"], new)
    new["/v1/forecast"]["get"]["parameters"][0]["required"] = False
    with pytest.raises(AssertionError):
        compatible(BASELINE["paths"], new)


@pytest.mark.parametrize("mutation", ["type", "enum", "field"])
def test_freeze_guard_rejects_breaking_changes(mutation):
    new = copy.deepcopy(SPEC)
    assessment = new["components"]["schemas"]["Assessment"]
    if mutation == "type":
        assessment["properties"]["summary"]["type"] = "number"
    elif mutation == "enum":
        assessment["properties"]["action"]["enum"].remove("try_now")
    else:
        assessment["properties"].pop("rating")
    with pytest.raises(AssertionError):
        compatible(BASELINE["components"]["schemas"], new["components"]["schemas"])


@pytest.mark.parametrize("city", ["stockholm", "oslo", "helsinki", "berlin"])
def test_recorded_activity_is_explicitly_without_continuous_support(city):
    row = asyncio.run(replay_forecast(city, ROOT / "backend/tests/fixtures/providers/captured"))
    value = row["forecast"]
    assert value["apiVersion"] == "1.0.0"
    assert value["now"]["activityEvidence"]["supportedInterval"] is None
    assert value["now"]["activityEvidence"]["forecastInstants"] == ["2026-10-12T20:34:00Z"]
    assert value["now"]["action"] != "try_now"
    validate_example(value, "Forecast")
    checker.check_forecast(value)


def test_positive_guidance_cannot_omit_its_continuous_evidence():
    value = json.loads((ROOT / "api/examples/promising-now.json").read_text())
    assert value["now"]["activityEvidence"]["supportedInterval"] is not None
    value["now"]["activityEvidence"]["supportedInterval"] = None
    with pytest.raises(AssertionError):
        checker.check_forecast(value)


def test_activity_metadata_is_an_optional_extension_for_reviewed_consumers():
    value = json.loads((ROOT / "api/examples/promising-now.json").read_text())
    value["now"].pop("activityEvidence")
    # A client which ignores additive fields can still decode the reviewed shape.
    validate_example(value, "Forecast")
