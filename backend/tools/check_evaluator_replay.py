"""Offline fixed-public-location replay, not the /v1/forecast API or observations."""

import json
from datetime import datetime
from pathlib import Path

from aurora_backend.astronomy.windows import calculate_windows
from aurora_backend.domain.types import Location
from aurora_backend.evaluation.engine import evaluate
from aurora_backend.evaluation.model import LEGACY_PARAMETERS
from aurora_backend.evaluation.spatial import horizon_candidate, local_signal
from aurora_backend.providers.models import (
    Product,
    ProviderError,
    ProviderResult,
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


def replay() -> list[dict[str, object]]:
    manifest = json.loads((CAPTURES / "manifest.json").read_text())
    times = {f["name"]: datetime.fromisoformat(f["capturedAt"]) for f in manifest["files"]}
    at = max(times.values())
    health = SourceHealth(SourceState.FRESH, None, False, at, at, None)
    aurora = normalize(
        Product.OVATION, (CAPTURES / "ovation.json").read_bytes(), times["ovation.json"]
    )
    kp_error = None
    try:
        kp = normalize(Product.KP, (CAPTURES / "kp.txt").read_bytes(), times["kp.txt"])
    except ProviderError as error:
        kp = None
        kp_error = error.code
    rows = []
    for name, lat, lon, zone in LOCATIONS:
        location = Location(latitude=lat, longitude=lon, timezone=zone)
        weather = normalize(
            Product.WEATHER,
            (CAPTURES / f"met-{name}.json").read_bytes(),
            times[f"met-{name}.json"],
            (lon, lat),
        )
        solar = calculate_windows(location, at)
        output = evaluate(
            location,
            solar,
            ovation=(ProviderResult(aurora, health),),
            weather=ProviderResult(weather, health),
            kp=ProviderResult(kp, health),
            parameters=LEGACY_PARAMETERS,
        )
        horizon = horizon_candidate(aurora, location)
        rows.append(
            {
                "location": name,
                "generatedAt": at.isoformat(),
                "model": output.model_version,
                "nearestGridSignal": local_signal(aurora, location, nearest=True),
                "bilinearGridSignal": local_signal(aurora, location),
                "geometryOnlyHorizonSignal": horizon.value if horizon else None,
                "nowRating": output.now.rating,
                "nowAction": output.now.action,
                "activityState": output.now.activity.state,
                "cloudEnvelope": output.now.weather.value,
                "kpContext": output.now.kp_context.value,
                "kpCaptureError": kp_error,
                "upcomingSegments": len(output.upcoming),
                "planningSegments": [len(s) for s in output.planning],
                "planningRatings": [
                    sorted({s.assessment.rating for s in night}) for night in output.planning
                ],
                "sourceIds": output.now.source_ids,
            }
        )
    return rows


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
