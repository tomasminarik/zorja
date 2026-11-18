"""Single-process bounded API admission and provider collection."""

import asyncio
import time
from collections import Counter
from dataclasses import replace
from datetime import datetime
from typing import Protocol

from aurora_backend.domain.types import Location
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product, ProviderResult, SourceState


class Sources(Protocol):
    async def get(
        self, product: Product, *, latitude: float | None = None, longitude: float | None = None
    ) -> ProviderResult: ...


class ForecastService:
    def __init__(
        self,
        sources: Sources | None = None,
        deadline: float = 3.0,
        coordinate_decimals: int | None = None,
    ) -> None:
        self.sources = sources
        # Hosted: providers and the shared cache see only a rough area (docs/privacy.md).
        self.coordinate_decimals = coordinate_decimals
        self.deadline = deadline
        self.metrics: Counter[str] = Counter()
        self.health: dict[str, str] = {}
        self._minute = int(time.monotonic() // 60)
        self._requests = 0
        self._active = 0

    def admit(self) -> bool:
        minute = int(time.monotonic() // 60)
        if minute != self._minute:
            self._minute, self._requests = minute, 0
        if self._requests >= 60 or self._active >= 4:
            self.metrics["rate_limited"] += 1
            return False
        self._requests += 1
        self._active += 1
        self.metrics["requests"] += 1
        return True

    def release(self) -> None:
        self._active -= 1

    async def collect(
        self,
        location: Location,
        at: datetime,
        *,
        budget_seconds: float | None = None,
    ) -> dict[Product, ProviderResult]:
        if self.sources is None:
            return {}
        latitude, longitude = location.latitude, location.longitude
        if self.coordinate_decimals is not None:
            # The rough area the app sends, whatever precision another client sends.
            latitude = round(latitude, self.coordinate_decimals)
            longitude = round(longitude, self.coordinate_decimals)
        tasks = {
            p: asyncio.create_task(self.sources.get(p, latitude=latitude, longitude=longitude))
            for p in Product
        }
        try:
            budget = self.deadline if budget_seconds is None else min(self.deadline, budget_seconds)
            done, pending = await asyncio.wait(tasks.values(), timeout=max(0.001, budget - 0.2))
            results = {}
            for product, task in tasks.items():
                if task in done:
                    try:
                        results[product] = task.result()
                    except Exception:
                        self.metrics["provider_failure"] += 1
                else:
                    self.metrics["provider_deadline"] += 1
                    if isinstance(self.sources, ProviderClient):
                        try:
                            cached = await asyncio.wait_for(
                                self.sources.cached(
                                    product,
                                    latitude=latitude,
                                    longitude=longitude,
                                ),
                                timeout=0.05,
                            )
                            if cached is not None:
                                if product == Product.OVATION:
                                    cached = replace(
                                        cached,
                                        health=replace(
                                            cached.health,
                                            state=SourceState.STALE,
                                            refresh_error="provider_deadline",
                                        ),
                                    )
                                results[product] = cached
                        except Exception:
                            self.metrics["provider_failure"] += 1
            return results
        finally:
            # Cancellation releases provider locks; never leave unbounded background refreshes.
            for task in tasks.values():
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks.values(), return_exceptions=True)
