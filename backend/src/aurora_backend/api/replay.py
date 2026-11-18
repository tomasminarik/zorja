"""Recorded public-city inputs through the HTTP pipeline; no provider access."""

import json
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx

from aurora_backend.api.app import create_app
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.activity import stream_deadline
from aurora_backend.providers.client import AGE_LIMITS, http_date
from aurora_backend.providers.models import (
    Product,
    ProviderError,
    ProviderResult,
    SourceHealth,
    SourceState,
)
from aurora_backend.providers.parsers import normalize

CITIES = {
    "stockholm": (59.3293, 18.0686, "Europe/Stockholm"),
    "oslo": (59.9139, 10.7522, "Europe/Oslo"),
    "helsinki": (60.1699, 24.9384, "Europe/Helsinki"),
    "berlin": (52.52, 13.405, "Europe/Berlin"),
}


class RecordedSources:
    def __init__(self, folder: Path, city: str) -> None:
        self.folder, self.city = folder, city
        self.entries = {
            e["name"]: e for e in json.loads((folder / "manifest.json").read_text())["files"]
        }
        self.at = max(datetime.fromisoformat(e["capturedAt"]) for e in self.entries.values())

    async def get(
        self, product: Product, *, latitude: float | None = None, longitude: float | None = None
    ) -> ProviderResult:
        filename = {
            Product.OVATION: "ovation.json",
            Product.KP: "kp.txt",
            Product.WEATHER: f"met-{self.city}.json",
        }[product]
        entry = self.entries[filename]
        fetched = datetime.fromisoformat(entry["capturedAt"])
        expiry = http_date(entry["headers"].get("expires"))
        error = None
        try:
            snapshot = normalize(
                product,
                (self.folder / filename).read_bytes(),
                fetched,
                (longitude, latitude)
                if product == Product.WEATHER and longitude is not None and latitude is not None
                else None,
            )
            origin = snapshot.observed_at or snapshot.issued_at
            snapshot = replace(snapshot, cache_headers=tuple(sorted(entry["headers"].items())))
            state = (
                SourceState.FRESH
                if (
                    origin
                    and origin <= self.at < origin + AGE_LIMITS[product]
                    and expiry
                    and self.at < expiry
                )
                else SourceState.STALE
            )
            if product == Product.OVATION:
                state = (
                    SourceState.FRESH
                    if self.at < stream_deadline((snapshot,))
                    else SourceState.STALE
                )
        except ProviderError as exc:
            snapshot, state, error = None, SourceState.UNAVAILABLE, exc.code
        return ProviderResult(
            snapshot, SourceHealth(state, error, False, fetched, expiry or self.at, expiry)
        )


async def replay_forecast(city: str, folder: Path) -> dict[str, Any]:
    sources = RecordedSources(folder, city)
    latitude, longitude, timezone = CITIES[city]
    config = Settings(provider_network=False)
    app = create_app(config, FixedClock(sources.at), sources)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://replay"
    ) as client:
        response = await client.get(
            "/v1/forecast",
            params={
                "latitude": latitude,
                "longitude": longitude,
                "timezone": timezone,
            },
        )
        response.raise_for_status()
        return {
            "kind": "recorded-provider-http-replay",
            "live": False,
            "city": city,
            "httpStatus": response.status_code,
            "forecast": response.json(),
        }
