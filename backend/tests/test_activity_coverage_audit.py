"""Audit arithmetic and gate evidence; no new coverage/age rule is approved."""

import importlib.util
import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from aurora_backend.providers.models import Product
from aurora_backend.providers.parsers import normalize

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "activity_coverage_audit", ROOT / "backend/tools/check_activity_coverage.py"
)
assert spec and spec.loader
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def captured_snapshot():  # type: ignore[no-untyped-def]
    directory = ROOT / "backend/tests/fixtures/providers/captured"
    manifest = json.loads((directory / "manifest.json").read_text())
    record = next(row for row in manifest["files"] if row["name"] == "ovation.json")
    return normalize(
        Product.OVATION,
        (directory / "ovation.json").read_bytes(),
        datetime.fromisoformat(record["capturedAt"]),
    )


@pytest.mark.parametrize("lead_minutes", [0, 19, 20, 30, 60, 90])
def test_age_boundary_at_target(lead_minutes: int) -> None:
    snapshot = captured_snapshot()
    observed = datetime(2026, 10, 12, 19, tzinfo=UTC)
    target = observed + timedelta(minutes=lead_minutes)
    snapshot = replace(snapshot, observed_at=observed, forecast_at=target, fetched_at=observed)
    row = audit.timing(snapshot, target)
    assert row["leadSeconds"] == lead_minutes * 60
    assert row["targetRejectedByEvaluatorAge"] == (lead_minutes >= 20)
    assert row["evaluationCoveredByProviderPoint"] is True
    assert row["supportedInterval"] is None
    assert all(not c["scientificallySupported"] for c in row["counterfactuals"])


def test_refetch_cannot_reset_age_or_create_duration() -> None:
    snapshot = captured_snapshot()
    assert snapshot.forecast_at
    target = snapshot.forecast_at
    original = audit.timing(snapshot, target)
    refetched = audit.timing(replace(snapshot, fetched_at=target), target)
    assert original["evaluatorAgeExpiresAt"] == refetched["evaluatorAgeExpiresAt"]
    assert original["targetRejectedByEvaluatorAge"] == refetched["targetRejectedByEvaluatorAge"]
    assert (
        audit.timing(snapshot, target + timedelta(microseconds=1))[
            "evaluationCoveredByProviderPoint"
        ]
        is False
    )


def test_invalid_inputs_are_not_coverage() -> None:
    snapshot = captured_snapshot()
    at = snapshot.fetched_at
    for invalid in (
        replace(snapshot, product=Product.KP),
        replace(snapshot, observed_at=None),
        replace(snapshot, forecast_at=None),
        replace(snapshot, observed_at=at, forecast_at=at - timedelta(seconds=1)),
    ):
        with pytest.raises(ValueError):
            audit.timing(invalid, at)
    with pytest.raises(ValueError, match="aware"):
        audit.timing(snapshot, at.replace(tzinfo=None))


def test_recorded_gate_report_is_reproducible() -> None:
    report = audit.replay()
    assert report == json.loads(
        (ROOT / "backend/tests/fixtures/replays/activity-coverage-audit.json").read_text()
    )
    assert report["gateStatus"] == "unresolved"
    assert report["uniqueForecastRuns"] == 1
    assert report["pairedObservations"] == 0
    assert all(
        assessment["action"] != "try_now"
        for row in report["regionalReplay"]
        for assessment in row["assessments"]
    )


def test_corrupt_capture_fails_before_reporting(tmp_path: Path) -> None:
    directory = ROOT / "backend/tests/fixtures/providers/captured"
    (tmp_path / "manifest.json").write_bytes((directory / "manifest.json").read_bytes())
    (tmp_path / "ovation.json").write_bytes(b"{}")
    with pytest.raises(ValueError, match="checksum"):
        audit.replay(tmp_path)
