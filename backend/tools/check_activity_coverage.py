"""Reproduce the coverage gate offline; never select a new scientific policy."""

import hashlib
import json
from datetime import datetime, timedelta
from pathlib import Path

from aurora_backend.astronomy.windows import calculate_windows
from aurora_backend.domain.types import Location, utc
from aurora_backend.evaluation.engine import evaluate
from aurora_backend.evaluation.model import LEGACY_PARAMETERS as DEFAULT_PARAMETERS
from aurora_backend.evaluation.spatial import local_signal
from aurora_backend.providers.client import AGE_LIMITS
from aurora_backend.providers.models import (
    Product,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
)
from aurora_backend.providers.parsers import normalize

CAPTURES = Path(__file__).resolve().parents[1] / "tests/fixtures/providers/captured"
LOCATIONS = (
    ("stockholm", 59.3293, 18.0686, "Europe/Stockholm"),
    ("oslo", 59.9139, 10.7522, "Europe/Oslo"),
    ("helsinki", 60.1699, 24.9384, "Europe/Helsinki"),
    ("berlin", 52.52, 13.405, "Europe/Berlin"),
)


def timing(snapshot: Snapshot, generated_at: datetime) -> dict[str, object]:
    """Separate lead, fetch age, source age and point coverage, with UTC inputs.

    Counterfactual age budgets are necessary arithmetic constraints, not accepted
    age policies. Passing them would still supply no nonzero supported interval.
    """
    generated = utc(generated_at)
    if snapshot.product != Product.OVATION:
        raise ValueError("OVATION snapshot required")
    if snapshot.observed_at is None or snapshot.forecast_at is None:
        raise ValueError("Observation and forecast timestamps required")
    observed, forecast, fetched = (
        utc(snapshot.observed_at),
        utc(snapshot.forecast_at),
        utc(snapshot.fetched_at),
    )
    lead = forecast - observed
    if lead < timedelta(0):
        raise ValueError("Forecast precedes observation")
    ceiling = DEFAULT_PARAMETERS.ovation_max_age
    expiry = observed + ceiling
    return {
        "sourceId": snapshot.id,
        "observedAt": observed.isoformat(),
        "forecastAt": forecast.isoformat(),
        "fetchedAt": fetched.isoformat(),
        "leadSeconds": lead.total_seconds(),
        "observationAgeAtFetchSeconds": (fetched - observed).total_seconds(),
        "observationAgeAtEvaluationSeconds": (generated - observed).total_seconds(),
        "forecastOffsetAtEvaluationSeconds": (forecast - generated).total_seconds(),
        "evaluatorAgeCeilingSeconds": ceiling.total_seconds(),
        "providerAgeCeilingSeconds": AGE_LIMITS[Product.OVATION].total_seconds(),
        "evaluatorAgeExpiresAt": expiry.isoformat(),
        "targetRejectedByEvaluatorAge": forecast >= expiry,
        "targetCoveredByProviderPoint": snapshot.covers(forecast),
        "evaluationCoveredByProviderPoint": snapshot.covers(generated),
        "fallbackMode": snapshot.fallback_mode,
        "supportedInterval": None,
        "counterfactuals": [
            {
                "hypotheticalSecondsAfterTarget": seconds,
                "observationAgeAtThatTimeSeconds": lead.total_seconds() + seconds,
                "strictAgeCeilingMustExceedSeconds": lead.total_seconds() + seconds,
                "scientificallySupported": False,
            }
            for seconds in (0, 60, 300, 900, 1800)
        ],
    }


def replay(captures: Path = CAPTURES) -> dict[str, object]:
    manifest = json.loads((captures / "manifest.json").read_text())
    files = {record["name"]: record for record in manifest["files"]}
    times = {name: datetime.fromisoformat(record["capturedAt"]) for name, record in files.items()}

    def body(name: str) -> bytes:
        raw = (captures / name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != files[name]["sha256"]:
            raise ValueError("Capture checksum mismatch")
        return raw

    aurora = normalize(Product.OVATION, body("ovation.json"), times["ovation.json"])
    generated = max(times.values())
    # Like the evaluator replay, isolate the evaluator from transport expiry.
    # This deliberately generous transport state is disclosed, never live data.
    health = SourceHealth(SourceState.FRESH, None, False, generated, generated, None)
    rows = []
    assert aurora.forecast_at is not None
    for name, lat, lon, zone in LOCATIONS:
        location = Location(latitude=lat, longitude=lon, timezone=zone)
        weather = normalize(
            Product.WEATHER, body(f"met-{name}.json"), times[f"met-{name}.json"], (lon, lat)
        )
        assessments = []
        for at in (generated, aurora.forecast_at):
            result = evaluate(
                location,
                calculate_windows(location, at),
                ovation=(ProviderResult(aurora, health),),
                weather=ProviderResult(weather, health),
                parameters=DEFAULT_PARAMETERS,
            )
            assessments.append(
                {
                    "generatedAt": at.isoformat(),
                    "activityState": result.now.activity.state,
                    "rating": result.now.rating,
                    "action": result.now.action,
                    "refreshAfter": result.now.refresh_after.isoformat(),
                }
            )
        rows.append(
            {
                "location": name,
                "bilinearGridSignal": local_signal(aurora, location),
                "assessments": assessments,
            }
        )
    return {
        "kind": "recorded-provider-coverage-audit",
        "modelVersion": DEFAULT_PARAMETERS.version,
        "gateStatus": "unresolved",
        "liveValidation": False,
        "transportHealthAssumption": "fresh to isolate evaluator timing; HTTP expiry not relaxed",
        "uniqueForecastRuns": 1,
        "pairedObservations": 0,
        "timing": timing(aurora, generated),
        "regionalReplay": rows,
    }


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
