"""Hosted forecasts reuse recently checked global data (docs/decisions.md, 2026-11-03)."""

import asyncio
import json
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from uuid import uuid4

import httpx
import pytest
import test_redis_store
from test_forecast_api import CAPTURES
from test_hosted_lifecycle import Transport, configured
from test_redis_store import Commands

from aurora_backend.api.hosted import HOSTED_REUSE, hosted_application
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product, SourceState
from aurora_backend.providers.redis_store import RedisProviderStore
from aurora_backend.providers.store import SnapshotStore

engine = test_redis_store.engine
# One hour after the synthetic Kp issue time.
START = datetime(2026, 10, 12, 22, 0, tzinfo=UTC)
# The recorded Kp capture is deliberately rejected; this synthetic one parses.
KP = CAPTURES.parent / "kp-mini.txt"


class Clock:
    def __init__(self, at):
        self.at = at

    def now(self):
        return self.at


def http_date(value):
    return format_datetime(value, usegmt=True)


class Upstream:
    """NOAA-like answers: 60-second max-age, publication time as Last-Modified."""

    def __init__(self, clock, published=timedelta(0)):
        self.clock, self.published, self.requests, self.status = clock, published, [], 200

    def ovation(self):
        value = json.loads((CAPTURES / "ovation.json").read_text())
        observed = self.clock.at - self.published - timedelta(minutes=5)
        value["Observation Time"] = observed.isoformat().replace("+00:00", "Z")
        forecast = self.clock.at + timedelta(minutes=30)
        value["Forecast Time"] = forecast.isoformat().replace("+00:00", "Z")
        return json.dumps(value).encode()

    def __call__(self, request):
        name = "ovation" if request.url.path.endswith(".json") else "kp"
        self.requests.append(name)
        now = self.clock.at
        headers = {
            "date": http_date(now),
            "expires": http_date(now + timedelta(seconds=60)),
            "cache-control": "max-age=60",
            "last-modified": http_date(now - self.published),
        }
        if self.status != 200:
            return httpx.Response(self.status, headers=headers)
        body = self.ovation() if name == "ovation" else KP.read_bytes()
        return httpx.Response(200, content=body, headers=headers)


def client(tmp_path, clock, upstream, reuse=HOSTED_REUSE):
    return ProviderClient(
        SnapshotStore(tmp_path / f"{uuid4().hex}.sqlite"),
        clock=clock,
        transport=httpx.MockTransport(upstream),
        request_spacing=0,
        jitter=lambda: 0,
        reuse=reuse,
    )


def run(coroutine):
    return asyncio.run(coroutine)


def test_kp_is_reused_and_fresh_within_an_hour_then_refreshed(tmp_path):
    async def exercise():
        clock = Clock(START)
        upstream = Upstream(clock)
        sources = client(tmp_path, clock, upstream)
        try:
            first = await sources.get(Product.KP)
            assert first.health.state == SourceState.FRESH and upstream.requests == ["kp"]
            clock.at = START + timedelta(minutes=59)
            reused = await sources.get(Product.KP)
            assert upstream.requests == ["kp"]
            assert reused.health.state == SourceState.FRESH
            # refreshAfter takes this expiry: the reuse end, not the 60-second HTTP one.
            assert reused.health.cache_expires_at == START + timedelta(minutes=60)
            clock.at = START + timedelta(minutes=60)
            await sources.get(Product.KP)
            assert upstream.requests == ["kp", "kp"]
        finally:
            await sources.close()

    run(exercise())


def test_without_reuse_the_local_default_refreshes_and_expires_kp(tmp_path):
    async def exercise():
        clock = Clock(START)
        upstream = Upstream(clock)
        sources = client(tmp_path, clock, upstream, reuse=None)
        try:
            await sources.get(Product.KP)
            clock.at = START + timedelta(minutes=10)
            await sources.get(Product.KP)
            assert upstream.requests == ["kp", "kp"]
        finally:
            await sources.close()

    run(exercise())


def test_a_failed_check_is_never_reused(tmp_path):
    async def exercise():
        clock = Clock(START)
        upstream = Upstream(clock)
        sources = client(tmp_path, clock, upstream)
        try:
            await sources.get(Product.KP)
            # Refused by the provider after the window: an error entry follows.
            clock.at = START + timedelta(minutes=61)
            upstream.status = 500
            failed = await sources.get(Product.KP)
            assert failed.health.refresh_error == "provider_http_500"
            assert failed.health.state == SourceState.STALE
            # Still inside the hour after the original check, but the last check failed.
            upstream.status = 200
            clock.at = START + timedelta(minutes=70)
            recovered = await sources.get(Product.KP)
            assert upstream.requests == ["kp", "kp", "kp"]
            assert recovered.health.refresh_error is None
        finally:
            await sources.close()

    run(exercise())


def test_ovation_is_reused_for_fifteen_minutes(tmp_path):
    async def exercise():
        clock = Clock(START)
        upstream = Upstream(clock)
        sources = client(tmp_path, clock, upstream)
        try:
            await sources.get(Product.OVATION)
            clock.at = START + timedelta(minutes=14, seconds=59)
            reused = await sources.get(Product.OVATION)
            assert upstream.requests == ["ovation"]
            assert reused.health.state == SourceState.FRESH
            clock.at = START + timedelta(minutes=15)
            await sources.get(Product.OVATION)
            assert upstream.requests == ["ovation", "ovation"]
        finally:
            await sources.close()

    run(exercise())


def test_reused_ovation_that_would_be_stale_is_refreshed(tmp_path):
    async def exercise():
        clock = Clock(START)
        # Published 10 minutes before receipt: the 20-minute deadline ends at START+10.
        upstream = Upstream(clock, published=timedelta(minutes=10))
        sources = client(tmp_path, clock, upstream)
        try:
            await sources.get(Product.OVATION)
            clock.at = START + timedelta(minutes=11)
            refreshed = await sources.get(Product.OVATION)
            assert upstream.requests == ["ovation", "ovation"]
            assert refreshed.health.state == SourceState.FRESH
        finally:
            await sources.close()

    run(exercise())


def test_reuse_is_bounded_and_never_applies_to_weather(tmp_path):
    for reuse in (
        {Product.WEATHER: timedelta(minutes=5)},
        {Product.OVATION: timedelta(minutes=16)},
        {Product.KP: timedelta(minutes=61)},
        {Product.KP: timedelta(0)},
    ):
        with pytest.raises(ValueError, match="reuse"):
            ProviderClient(
                SnapshotStore(tmp_path / "bounds.sqlite"),
                transport=httpx.MockTransport(lambda r: None),
                reuse=reuse,
            )


def test_redis_reuse_takes_no_refresh_lease(engine):
    async def exercise():
        clock = Clock(START)
        upstream = Upstream(clock)
        store = RedisProviderStore(Commands(engine), namespace="reuse-" + uuid4().hex, clock=clock)
        sources = ProviderClient(
            store,
            clock=clock,
            transport=httpx.MockTransport(upstream),
            request_spacing=0,
            jitter=lambda: 0,
            reuse=HOSTED_REUSE,
        )
        try:
            await sources.get(Product.KP)
            clock.at = START + timedelta(minutes=30)
            entry = await store.read(Product.KP.value)
            prepared = await store.prepare(
                Product.KP.value,
                "services.swpc.noaa.gov",
                clock.at,
                reuse_since=clock.at - timedelta(minutes=60),
            )
            assert prepared.owner is None and prepared.entry == entry
            # Without reuse the same entry is due and gets a lease.
            due = await store.prepare(Product.KP.value, "services.swpc.noaa.gov", clock.at)
            assert due.owner is not None
            await store.release(Product.KP.value, due.owner)
            assert upstream.requests == ["kp"]
        finally:
            await sources.close()

    run(exercise())


def test_hosted_forecasts_reuse_but_the_local_default_does_not(tmp_path):
    async def exercise():
        async with hosted_application(
            configured(), redis_transport=Transport(), provider_transport=Transport()
        ) as app:
            assert app.state.forecast_service.sources.reuse == HOSTED_REUSE

    run(exercise())
    local = ProviderClient(SnapshotStore(tmp_path / "local.sqlite"))
    assert local.reuse == {}
    run(local.close())
