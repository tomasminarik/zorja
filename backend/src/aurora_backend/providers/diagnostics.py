"""Opt-in source diagnostics. Never emit location keys, bodies or visibility guidance."""

from datetime import datetime
from pathlib import Path
from typing import Any

from aurora_backend.providers.client import ProviderClient, weather_coordinates
from aurora_backend.providers.models import Product
from aurora_backend.providers.store import SnapshotStore


async def inspect_sources(
    cache_path: Path, latitude: float, longitude: float
) -> list[dict[str, Any]]:
    weather_coordinates(latitude, longitude)
    store = SnapshotStore(cache_path)
    client = ProviderClient(store)
    results = []
    try:
        # NOAA globals once; one selected weather key. No automatic schedule is started.
        for product in Product:
            result = await client.get(product, latitude=latitude, longitude=longitude)
            snapshot = result.snapshot
            results.append(
                {
                    "product": product.value,
                    "state": result.health.state.value,
                    "refreshError": result.health.refresh_error,
                    "deprecated": result.health.deprecated,
                    "checkedAt": iso(result.health.checked_at),
                    "nextRefreshAt": iso(result.health.next_refresh_at),
                    "cacheExpiresAt": iso(result.health.cache_expires_at),
                    "snapshotId": snapshot.id if snapshot else None,
                    "issuedAt": iso(snapshot.issued_at)
                    if snapshot and snapshot.issued_at
                    else None,
                    "observedAt": iso(snapshot.observed_at)
                    if snapshot and snapshot.observed_at
                    else None,
                    "forecastAt": iso(snapshot.forecast_at)
                    if snapshot and snapshot.forecast_at
                    else None,
                    "fetchedAt": iso(snapshot.fetched_at) if snapshot else None,
                    "validFrom": iso(snapshot.valid_from) if snapshot else None,
                    "validUntil": iso(snapshot.valid_until) if snapshot else None,
                    "samples": len(snapshot.grid or snapshot.kp or snapshot.weather)
                    if snapshot
                    else 0,
                }
            )
    finally:
        await client.close()
        store.close()
    return results


def iso(value: datetime | None) -> str | None:
    return value.isoformat().replace("+00:00", "Z") if value is not None else None
