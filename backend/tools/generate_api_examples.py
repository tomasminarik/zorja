"""Generate UI examples from explicit synthetic normalized inputs and the real serializer.

No observations, provider capture, calibration, or live network is involved.
"""

import asyncio
import hashlib
import json
from dataclasses import asdict, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest.mock import patch
from uuid import UUID

import httpx

from aurora_backend.api.app import create_app
from aurora_backend.api.forecast import build_forecast
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.domain.types import Location
from aurora_backend.providers.models import (
    GridPoint,
    KpBin,
    Product,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
    WeatherSample,
)

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = (
    "promising-now",
    "daylight-next-window",
    "cloud-blocked",
    "stale-aurora",
    "weather-unavailable",
    "midnight-sun",
    "polar-night",
    "after-midnight-current-night",
    "morning-finished-night",
    "disjoint-darkness",
    "partial-third-night",
    "limited-clouds",
    "low-activity",
    "stale-weather",
    "weather-missing",
    "too-bright-tonight",
    "south-could-reach",
    "south-not-expected",
)


def synthetic_forecast(name: str, *, continuous: bool = True) -> dict[str, Any]:
    if name not in SCENARIOS:
        raise ValueError("Unknown synthetic scenario")
    at = datetime(2026, 10, 12, 21, tzinfo=UTC)
    latitude, longitude, timezone = 59.3293, 18.0686, "Europe/Stockholm"
    if name == "daylight-next-window":
        at = at.replace(hour=10)
    elif name == "after-midnight-current-night":
        at = at.replace(day=13, hour=1)
    elif name == "morning-finished-night":
        at = at.replace(day=13, hour=8)
    elif name == "midnight-sun":
        at, latitude, longitude = datetime(2026, 6, 21, 12, tzinfo=UTC), 69.6492, 18.9553
    elif name == "too-bright-tonight":
        # Tromsø as darkness returns in late August: tonight never gets dark enough,
        # a later night within the three-day horizon does.
        at, latitude, longitude = datetime(2026, 8, 31, 12, tzinfo=UTC), 69.6492, 18.9553
    elif name == "polar-night":
        at, latitude, longitude = datetime(2026, 12, 21, 0, tzinfo=UTC), 89, 0
    elif name == "disjoint-darkness":
        # Deliberately displaced timezone/longitude: two qualifying intervals
        # separated by brighter twilight inside the same local noon period.
        at, latitude, longitude = datetime(2026, 12, 21, 12, tzinfo=UTC), 78, 60
    elif name.startswith("south-"):
        # Edinburgh: south of the aurora zone, where the night outlook applies.
        latitude, longitude, timezone = 55.9533, -3.1883, "Europe/London"
    location = Location(latitude=latitude, longitude=longitude, timezone=timezone)
    cloud = 90 if name == "cloud-blocked" else 30 if name == "limited-clouds" else 10
    signal = 1 if name == "low-activity" else 80
    ids = {p: hashlib.sha256(f"synthetic:{name}:{p.value}".encode()).hexdigest() for p in Product}
    observed = at - timedelta(minutes=21 if name == "stale-aurora" else 1)
    ovation = Snapshot(
        ids[Product.OVATION],
        Product.OVATION,
        "NOAA SWPC",
        None,
        observed,
        at,
        at,
        at,
        at,
        (("aurora", "provider_0_100"),),
        None,
        grid=tuple(
            GridPoint(lon, lat, signal) for lon in range(-180, 180) for lat in range(-90, 91)
        ),
    )
    weather_origin = at - timedelta(hours=7 if name == "stale-weather" else 1)
    first = at.replace(minute=0, second=0, microsecond=0)
    hours = 50 if name == "partial-third-night" else 97
    samples = tuple(
        WeatherSample(
            first + timedelta(hours=h),
            None if name == "weather-missing" else cloud,
            None,
            None,
            None,
            None,
            timedelta(hours=1) if h < hours - 1 else None,
        )
        for h in range(hours)
    )
    weather = Snapshot(
        ids[Product.WEATHER],
        Product.WEATHER,
        "MET Norway",
        weather_origin,
        None,
        None,
        at,
        samples[0].time,
        samples[-1].time,
        (("cloud_area_fraction", "%"),),
        (longitude, latitude),
        weather=samples,
    )
    kp_value = 3.0 if name == "south-not-expected" else 5.0
    kp_start = at.replace(hour=(at.hour // 3) * 3, minute=0, second=0, microsecond=0)
    bins = tuple(
        KpBin(kp_start + timedelta(hours=3 * h), kp_start + timedelta(hours=3 * (h + 1)), kp_value)
        for h in range(32)
    )
    kp = Snapshot(
        ids[Product.KP],
        Product.KP,
        "NOAA SWPC",
        at - timedelta(hours=1),
        None,
        None,
        at,
        bins[0].start,
        bins[-1].end,
        (("kp", "index"),),
        None,
        kp=bins,
    )

    def identified(snapshot: Snapshot) -> Snapshot:
        data = asdict(snapshot)
        data.pop("id")
        body = json.dumps(
            data,
            sort_keys=True,
            default=lambda t: t.total_seconds() if isinstance(t, timedelta) else t.isoformat(),
        ).encode()
        return replace(snapshot, id=hashlib.sha256(body).hexdigest())

    ovation, weather, kp = (identified(s) for s in (ovation, weather, kp))
    health = SourceHealth(
        SourceState.FRESH, None, False, at, at + timedelta(minutes=5), at + timedelta(minutes=5)
    )
    results = {
        Product.OVATION: ProviderResult(ovation, health),
        Product.WEATHER: ProviderResult(weather, health),
        Product.KP: ProviderResult(kp, health),
    }
    if continuous:
        retained = []
        for offset in (-5, 10):
            target = at + timedelta(minutes=offset)
            retained.append(
                identified(
                    replace(
                        ovation,
                        forecast_at=target,
                        valid_from=target,
                        valid_until=target,
                        observed_at=target - timedelta(minutes=60),
                        fetched_at=at - timedelta(minutes=2),
                    )
                )
            )
        results[Product.OVATION] = ProviderResult(retained[-1], health, tuple(retained))
    if name == "stale-aurora":
        results[Product.OVATION] = replace(
            results[Product.OVATION], health=replace(health, state=SourceState.STALE)
        )
    if name == "weather-unavailable":
        results.pop(Product.WEATHER)
    return build_forecast(location, at, results)


async def synthetic_error() -> dict[str, Any]:
    clock = FixedClock(datetime(2026, 10, 12, 21, tzinfo=UTC))
    app = create_app(Settings(), clock)
    with (
        patch("aurora_backend.api.app.build_forecast", side_effect=ValueError("synthetic failure")),
        patch("aurora_backend.api.app.uuid4", return_value=UUID(int=0)),
    ):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://synthetic"
        ) as client:
            response = await client.get(
                "/v1/forecast",
                params={
                    "latitude": 59.3293,
                    "longitude": 18.0686,
                    "timezone": "Europe/Stockholm",
                },
            )
    assert response.status_code == 503
    payload: dict[str, Any] = response.json()
    return payload


def generate() -> dict[str, dict[str, Any]]:
    return {
        **{name: synthetic_forecast(name) for name in SCENARIOS},
        "error-503": asyncio.run(synthetic_error()),
    }


if __name__ == "__main__":
    for name, value in generate().items():
        (ROOT / "api/examples" / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")
    print(
        f"Generated {len(SCENARIOS) + 1} examples from synthetic evaluator inputs"
        " and an actual HTTP failure."
    )
