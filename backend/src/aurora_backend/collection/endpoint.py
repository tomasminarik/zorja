"""Explicitly composed internal endpoint. Absent from the default MVP runtime."""

import asyncio
import json
import secrets
from collections import Counter
from collections.abc import Callable
from datetime import datetime

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from aurora_backend.collection.cadence import collection_due
from aurora_backend.collection.signatures import InvalidSignature, QStashVerifier, unique
from aurora_backend.domain.clock import Clock
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product, SourceState
from aurora_backend.providers.redis_store import RedisProviderStore


class Collector:
    def __init__(
        self,
        verifier: QStashVerifier,
        store: RedisProviderStore,
        client: ProviderClient,
        clock: Clock,
        *,
        due: Callable[[datetime], bool] = collection_due,
    ) -> None:
        if store.limits is None or store.lane != "collector" or client.store is not store:
            raise ValueError("Collector requires its budgeted shared-store client")
        self.verifier, self.store, self.client, self.clock = verifier, store, client, clock
        self.due = due
        self.metrics: Counter[str] = Counter()

    async def run(self, replay_id: str) -> tuple[int, str]:
        # Outside darkness only every third 10-minute call works (see cadence.py).
        # A call that is not due touches neither Redis nor NOAA.
        if not self.due(self.clock.now()):
            self.metrics["not_due"] += 1
            return 200, "not_due"
        owner = secrets.token_hex(32)
        slot = await self.store.claim_collection(owner, replay_id)
        if slot in {"duplicate", "attempt_limit"}:
            self.metrics[slot] += 1
            return 200, slot
        if slot in {"busy", "daily_limit", "work_exhausted"}:
            self.metrics[slot] += 1
            return 503, slot
        if not slot.isdigit():
            raise ValueError("Invalid collector state")
        success = False
        try:
            async with asyncio.timeout(10):
                result = await self.client.get(Product.OVATION, include_history=False)
            success = result.snapshot is not None and result.health.state == SourceState.FRESH
            self.metrics["success" if success else "source_unavailable"] += 1
            return (200, "collected") if success else (503, "source_unavailable")
        except Exception:
            self.metrics["collection_failure"] += 1
            return 503, "collection_unavailable"
        finally:
            task = asyncio.current_task()
            if task is None or not task.cancelling():
                try:
                    await self.store.finish_collection(owner, slot, success)
                except Exception:
                    self.metrics["completion_unknown"] += 1


def add_collector_route(app: FastAPI, collector: Collector) -> None:
    @app.post("/internal/collect/ovation", include_in_schema=False)
    async def collect(request: Request) -> JSONResponse:
        # Authenticate exact raw bytes before any storage/provider operation.
        signatures = request.headers.getlist("upstash-signature")
        if len(signatures) != 1 or request.url.query:
            return JSONResponse({"status": "unauthorized"}, status_code=401)
        body = bytearray()
        try:
            async with asyncio.timeout(1):
                async for chunk in request.stream():
                    if len(body) + len(chunk) > 256:
                        return JSONResponse({"status": "body_too_large"}, status_code=413)
                    body.extend(chunk)
            replay_id = collector.verifier.verify(signatures[0], bytes(body), collector.clock.now())
            # Only one fixed global task. No coordinate or personal payload accepted.
            if json.loads(body, object_pairs_hook=unique) != {"task": "ovation"}:
                return JSONResponse({"status": "invalid_task"}, status_code=400)
        except InvalidSignature:
            return JSONResponse({"status": "unauthorized"}, status_code=401)
        except (ValueError, TimeoutError, RecursionError):
            return JSONResponse({"status": "invalid_request"}, status_code=400)
        try:
            status, outcome = await collector.run(replay_id)
        except Exception:
            status, outcome = 503, "collection_unavailable"
        return JSONResponse(
            {"status": outcome},
            status_code=status,
            headers={"Retry-After": "60"} if status == 503 else {},
        )
