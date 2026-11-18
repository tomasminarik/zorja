"""Shared bounded provider refreshes, independent of alert evaluation cadence."""

import asyncio
import contextlib
import hashlib
import math
import random
import re
from collections.abc import Callable, Coroutine
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from email.utils import parsedate_to_datetime
from typing import Any
from urllib.parse import urljoin

import httpx

from aurora_backend.domain.clock import Clock, SystemClock
from aurora_backend.domain.types import utc
from aurora_backend.providers.activity import stream_deadline
from aurora_backend.providers.models import (
    Product,
    ProviderError,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
)
from aurora_backend.providers.parsers import MAX_BODY_BYTES, normalize
from aurora_backend.providers.storage import History, ProviderStore, SQLiteProviderStore
from aurora_backend.providers.store import CacheEntry, SnapshotStore

OVATION_URL = "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
KP_URL = "https://services.swpc.noaa.gov/text/3-day-forecast.txt"
WEATHER_URL = "https://api.met.no/weatherapi/locationforecast/2.0/compact"
DEFAULT_USER_AGENT = "Zorja/1.0 hello@tomasminarik.com"
HEADERS = {"date", "expires", "last-modified", "etag", "cache-control", "age"}
AGE_LIMITS = {
    Product.OVATION: timedelta(minutes=20),
    Product.KP: timedelta(hours=24),
    Product.WEATHER: timedelta(hours=6),
}
MIN_REFRESH = {Product.OVATION: 60, Product.KP: 300, Product.WEATHER: 60}
SHARED_PRUNE_INTERVAL = timedelta(minutes=15)
# Longest permitted reuse of a successfully checked global product (docs/decisions.md, 2026-11-03).
MAX_REUSE = {Product.OVATION: timedelta(minutes=15), Product.KP: timedelta(minutes=60)}
MAX_JITTER = 120.0
# After a successful check, weather stays usable past its HTTP expiry for as long as the next
# scheduled check can take (minimum interval plus jitter). MET's Expires is a polling hint,
# sometimes already past when the response arrives; the issue-age limit still applies.
WEATHER_EXPIRY_GRACE = timedelta(seconds=MIN_REFRESH[Product.WEATHER] + MAX_JITTER)


def http_date(value: str | None) -> datetime | None:
    if value is None:
        return None
    try:
        parsed = parsedate_to_datetime(value)
        return utc(parsed)
    except (ValueError, TypeError, OverflowError):
        return None


def retry_deadline(value: str, now: datetime) -> datetime | None:
    if not value.isdigit():
        return http_date(value)
    maximum = datetime.max.replace(tzinfo=UTC)
    remaining = int((maximum - now).total_seconds()) - 1
    seconds = remaining if len(value) > 12 else min(int(value), remaining)
    return now + timedelta(seconds=seconds)


def cache_expiry(headers: dict[str, str]) -> datetime | None:
    return http_date(headers.get("expires")) or http_date(headers.get("x-aurora-cache-expires"))


def weather_coordinates(latitude: float, longitude: float) -> tuple[float, float]:
    if (
        isinstance(latitude, bool)
        or isinstance(longitude, bool)
        or not math.isfinite(latitude)
        or not math.isfinite(longitude)
        or not -90 <= latitude <= 90
        or not -180 <= longitude <= 180
    ):
        raise ProviderError("invalid_coordinates")
    # MET requires truncation, not more than four decimals. Decimal avoids binary drift.
    from decimal import ROUND_DOWN, Decimal

    def truncate(value: float) -> float:
        return float(Decimal(str(value)).quantize(Decimal("0.0001"), rounding=ROUND_DOWN))

    lon = truncate(longitude)
    if lon == 180:
        lon = -180.0
    return lon or 0.0, truncate(latitude) or 0.0


REFRESH_IN_PROGRESS = "refresh_in_progress"
#: How long a request waits for another instance's refresh of the same source.
IN_PROGRESS_WAITS = 3
IN_PROGRESS_STEP = 0.3


_RELEASES: set[asyncio.Task[None]] = set()


async def _release(release: Coroutine[Any, Any, None]) -> None:
    """Releases a lease, also when the request was cancelled (the forecast deadline, the
    collector's timeout), so the next request for the source doesn't wait out the 90-second
    lease. A cancelled request doesn't wait for the release: it runs on its own, and its
    errors are dropped, since the lease expires in any case."""
    task = asyncio.current_task()
    if task is None or not task.cancelling():
        await release
        return
    background = asyncio.get_running_loop().create_task(_quietly(release))
    _RELEASES.add(background)
    background.add_done_callback(_RELEASES.discard)


async def _quietly(release: Coroutine[Any, Any, None]) -> None:
    with contextlib.suppress(Exception):
        await release


class ProviderClient:
    def __init__(
        self,
        store: SnapshotStore | ProviderStore,
        *,
        clock: Clock | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        user_agent: str = DEFAULT_USER_AGENT,
        jitter: Callable[[], float] | None = None,
        request_spacing: float = 1.0,
        deadline_seconds: float = 15.0,
        reuse: dict[Product, timedelta] | None = None,
    ) -> None:
        if not re.fullmatch(r"Zorja/[\w.\-]+ [^\s@]+@[^\s@]+", user_agent) or len(user_agent) > 200:
            raise ValueError("A project-identifying contact User-Agent is required")
        if request_spacing < 0 or not 0 < deadline_seconds <= 60:
            raise ValueError("Invalid request bounds")
        # Reuse skips a refresh of a recently checked global product; it never
        # refreshes earlier, overrides backoff/cooldown, or applies to weather.
        self.reuse = dict(reuse or {})
        if any(
            product not in MAX_REUSE or not timedelta(0) < window <= MAX_REUSE[product]
            for product, window in self.reuse.items()
        ):
            raise ValueError("Invalid reuse window")
        self.store: ProviderStore = (
            SQLiteProviderStore(store) if isinstance(store, SnapshotStore) else store
        )
        self.clock = clock or SystemClock()
        self.jitter = jitter or (lambda: random.uniform(0, MAX_JITTER))
        self.spacing = request_spacing
        self.deadline = deadline_seconds
        self.http = httpx.AsyncClient(
            transport=transport,
            timeout=httpx.Timeout(10, connect=5),
            limits=httpx.Limits(max_connections=2, max_keepalive_connections=2),
            headers={"User-Agent": user_agent, "Accept-Encoding": "gzip, deflate"},
            follow_redirects=False,
            trust_env=False,
        )
        self._locks: dict[str, asyncio.Lock] = {}
        self._network = asyncio.Lock()
        self._last_request: float | None = None
        self._pruned_at: datetime | None = None
        self._normalizations: dict[tuple[Product, tuple[float, float] | None, bytes], Snapshot] = {}
        if isinstance(store, SnapshotStore):
            store.prune_raw(utc(self.clock.now()))

    async def _prune_raw(self) -> None:
        now = utc(self.clock.now())
        # A shared store also prunes inside every history read and write, so a
        # separate cleanup per request only adds round trips there.
        if (
            isinstance(self.store, SQLiteProviderStore)
            or self._pruned_at is None
            or not timedelta(0) <= now - self._pruned_at < SHARED_PRUNE_INTERVAL
        ):
            # Claim before awaiting so concurrent requests do not prune again.
            self._pruned_at = now
            await self.store.prune_raw(now)
        self._normalizations = {
            key: value
            for key, value in self._normalizations.items()
            if value.fetched_at > now - timedelta(hours=48)
        }

    def _normalize(
        self,
        product: Product,
        body: bytes,
        fetched: datetime,
        coords: tuple[float, float] | None = None,
    ) -> Snapshot:
        key = (product, coords, hashlib.sha256(body).digest())
        cached = self._normalizations.get(key)
        if cached is None:
            cached = normalize(product, body, fetched, coords)
            self._normalizations[key] = cached
            if len(self._normalizations) > 70:
                self._normalizations.pop(next(iter(self._normalizations)))
        return replace(cached, fetched_at=fetched)

    async def close(self) -> None:
        await self.http.aclose()

    async def get(
        self,
        product: Product,
        *,
        latitude: float | None = None,
        longitude: float | None = None,
        include_history: bool = True,
    ) -> ProviderResult:
        coords = None
        if product == Product.WEATHER:
            if latitude is None or longitude is None:
                raise ProviderError("coordinates_required")
            coords = weather_coordinates(latitude, longitude)
            key = f"met:{coords[0]:.4f},{coords[1]:.4f}"
            url = f"{WEATHER_URL}?lat={coords[1]:.4f}&lon={coords[0]:.4f}"
        else:
            key = product.value
            url = OVATION_URL if product == Product.OVATION else KP_URL
        now = utc(self.clock.now())
        await self._prune_raw()
        new_lock = key not in self._locks
        lock = self._locks.setdefault(key, asyncio.Lock())
        async with lock:
            window = self.reuse.get(product)
            waits = 0
            while True:
                reuse_since = now - window if window else None
                try:
                    prepared = await self.store.prepare(
                        key,
                        httpx.URL(url).host,
                        now,
                        with_history=product == Product.OVATION and include_history,
                        reuse_since=reuse_since,
                    )
                except ProviderError as error:
                    if new_lock and self._locks.get(key) is lock:
                        del self._locks[key]
                    return ProviderResult(
                        None,
                        SourceHealth(SourceState.UNAVAILABLE, error.code, False, None, now, None),
                    )
                entry, owner = prepared.entry, prepared.owner
                if owner is None and entry.error == REFRESH_IN_PROGRESS:
                    # Another instance is fetching this source: give it a moment to store
                    # the result. The forecast deadline bounds the wait in any case.
                    if waits < IN_PROGRESS_WAITS:
                        waits += 1
                        await asyncio.sleep(IN_PROGRESS_STEP)
                        continue
                    # Still running: what is stored is judged on its own dates, since a
                    # refresh in progress is not a failed one. With nothing stored yet the
                    # source stays unavailable, with this reason.
                    if entry.body is not None:
                        entry = replace(entry, error=None)
                # History read with the prepared entry is valid only if nothing was rewritten.
                history = prepared.history
                if owner is not None:
                    try:
                        if utc(self.clock.now()) >= entry.next_refresh_at:
                            history = None
                            entry = await self._refresh(product, url, coords, entry, owner)
                    finally:
                        await _release(self.store.release(key, owner))
                result = await self._result(
                    product, coords, entry, include_history=include_history, history=history
                )
                if (
                    window is not None
                    and owner is None
                    and entry.error is None
                    and result.health.state == SourceState.STALE
                ):
                    # Reused evidence would be stale: try a normal refresh instead.
                    window = None
                    continue
                return result

    async def cached(
        self, product: Product, *, latitude: float, longitude: float
    ) -> ProviderResult | None:
        """Read retained evidence without reserving a key or fetching."""
        await self._prune_raw()
        coords = weather_coordinates(latitude, longitude) if product == Product.WEATHER else None
        key = f"met:{coords[0]:.4f},{coords[1]:.4f}" if coords else product.value
        entry = await self.store.read(key)
        return await self._result(product, coords, entry) if entry else None

    async def _result(
        self,
        product: Product,
        coords: tuple[float, float] | None,
        entry: CacheEntry,
        *,
        include_history: bool = True,
        history: History | None = None,
    ) -> ProviderResult:
        now = utc(self.clock.now())
        snapshot = None
        retained: tuple[Snapshot, ...] = ()
        error = entry.error
        state = SourceState.UNAVAILABLE
        if entry.body is not None and entry.fetched_at is not None:
            try:
                snapshot = self._normalize(product, entry.body, entry.fetched_at, coords)
                snapshot = replace(
                    snapshot,
                    cache_headers=tuple(
                        sorted((k, v) for k, v in entry.headers.items() if k in HEADERS)
                    ),
                )
                age_origin = snapshot.observed_at or snapshot.issued_at
                assert age_origin is not None
                expiry = self._expiry(product, entry)
                age_ok = timedelta(0) <= now - age_origin <= AGE_LIMITS[product]
                cache_ok = expiry is not None and now < expiry
                state = (
                    SourceState.FRESH
                    if age_ok and cache_ok and error is None
                    else SourceState.STALE
                )
                if product == Product.OVATION:
                    retained = tuple(
                        replace(
                            self._normalize(product, body, fetched),
                            cache_headers=tuple(sorted(headers.items())),
                        )
                        for body, fetched, headers in (
                            history
                            if history is not None
                            else (await self.store.history(now) if include_history else ())
                        )
                    )
                    active_ids = {snapshot.id, *(s.id for s in retained)}
                    self._normalizations = {
                        key: value
                        for key, value in self._normalizations.items()
                        if key[0] != Product.OVATION or value.id in active_ids
                    }
                    state = (
                        SourceState.FRESH
                        if now < stream_deadline((snapshot, *retained)) and error is None
                        else SourceState.STALE
                    )
                    if snapshot.fetched_at > now or (
                        snapshot.observed_at is not None and snapshot.observed_at > now
                    ):
                        state = SourceState.UNAVAILABLE
            except ProviderError:
                error = "persisted_snapshot_invalid"
                state = SourceState.UNAVAILABLE
                retained = ()
        return ProviderResult(
            snapshot,
            SourceHealth(
                state,
                error,
                entry.deprecated,
                entry.checked_at,
                entry.next_refresh_at,
                self._expiry(product, entry),
            ),
            retained,
        )

    def _expiry(self, product: Product, entry: CacheEntry) -> datetime | None:
        """HTTP expiry, extended by the reuse window or weather grace after a successful check."""
        expiry = cache_expiry(entry.headers)
        if product == Product.WEATHER and entry.error is None and entry.checked_at is not None:
            checked = utc(entry.checked_at)
            expiry = (checked if expiry is None else max(expiry, checked)) + WEATHER_EXPIRY_GRACE
        window = self.reuse.get(product)
        if window is None or entry.error is not None or entry.checked_at is None:
            return expiry
        reused = utc(entry.checked_at) + window
        return reused if expiry is None else max(expiry, reused)

    def _schedule(self, headers: dict[str, str], product: Product, now: datetime) -> datetime:
        expiry = http_date(headers.get("expires"))
        if expiry is None:
            # Use HTTP age-corrected max-age if supplied; otherwise a conservative local TTL.
            match = re.search(r"(?:^|,)\s*max-age=(\d+)", headers.get("cache-control", ""))
            date = http_date(headers.get("date")) or now
            try:
                age = max(0, int(headers.get("age", "0")))
            except ValueError:
                age = 0
            ttl = min(int(match[1]), 86400) if match else MIN_REFRESH[product]
            expiry = min(date + timedelta(seconds=ttl), now + timedelta(seconds=max(0, ttl - age)))
            headers["x-aurora-cache-expires"] = expiry.strftime("%a, %d %b %Y %H:%M:%S GMT")
        jitter = max(0.0, min(self.jitter(), MAX_JITTER))
        return max(expiry, now + timedelta(seconds=MIN_REFRESH[product])) + timedelta(
            seconds=jitter
        )

    async def _request(
        self, url: str, headers: dict[str, str]
    ) -> tuple[int, dict[str, str], bytes]:
        # Single bounded owner, <=1 req/s default, including redirects; never log request URLs.
        async with self._network:
            original_host = httpx.URL(url).host
            # A store whose host lease already refuses during a cooldown needs no
            # separate lookup; both paths raise the same error.
            if not getattr(self.store, "host_lease_checks_cooldown", False):
                cooldown = await self.store.cooldown(original_host)
                if cooldown is not None and self.clock.now() < cooldown:
                    raise ProviderError("provider_throttled")
            host_owner = await self.store.acquire_host(original_host, self.spacing)
            if host_owner is None:
                raise ProviderError("provider_throttled")
            try:
                for _ in range(4):
                    loop = asyncio.get_running_loop()
                    if self._last_request is not None:
                        await asyncio.sleep(
                            max(0, self.spacing - (loop.time() - self._last_request))
                        )
                    self._last_request = loop.time()
                    async with self.http.stream("GET", url, headers=headers) as response:
                        if response.status_code in {301, 302, 303, 307, 308}:
                            url = urljoin(url, response.headers.get("location", ""))
                            target = httpx.URL(url)
                            if target.scheme != "https" or target.host != original_host:
                                raise ProviderError("unsafe_redirect")
                            continue
                        selected = {k: v for k, v in response.headers.items() if k in HEADERS}
                        if response.status_code in {403, 429, 503}:
                            selected["retry-after"] = response.headers.get("retry-after", "")
                        if response.status_code in {403, 429}:
                            at = utc(self.clock.now())
                            # Persist refusal before releasing the shared host lease.
                            await self.store.throttle(
                                original_host,
                                max(
                                    at + timedelta(minutes=15),
                                    retry_deadline(selected["retry-after"], at) or at,
                                ),
                            )
                        if response.status_code not in {200, 203}:
                            return response.status_code, selected, b""
                        body = bytearray()
                        async for chunk in response.aiter_bytes(chunk_size=65536):
                            if len(body) + len(chunk) > MAX_BODY_BYTES:
                                raise ProviderError("response_too_large")
                            body.extend(chunk)
                        return response.status_code, selected, bytes(body)
                raise ProviderError("too_many_redirects")
            finally:
                await _release(self.store.release_host(original_host, host_owner, self.spacing))

    async def _refresh(
        self,
        product: Product,
        url: str,
        coords: tuple[float, float] | None,
        entry: CacheEntry,
        owner: str,
    ) -> CacheEntry:
        headers = {}
        now = utc(self.clock.now())
        modified = http_date(entry.headers.get("last-modified"))
        if entry.body is not None:
            if modified is not None and modified <= now:
                headers["If-Modified-Since"] = entry.headers["last-modified"]
            if "etag" in entry.headers:
                headers["If-None-Match"] = entry.headers["etag"]
        retry_until = None
        received: dict[str, str] = {}
        try:
            async with asyncio.timeout(self.deadline):
                status, received, body = await self._request(url, headers)
            now = utc(self.clock.now())
            if status == 304:
                if entry.body is None:
                    raise ProviderError("unexpected_304")
                # Drop old expiry/date/age; a 304 cannot revive the old cache lifetime.
                merged = {
                    k: v
                    for k, v in entry.headers.items()
                    if k
                    not in {
                        "expires",
                        "date",
                        "age",
                        "cache-control",
                        "x-aurora-cache-expires",
                    }
                }
                merged.update(received)
                next_refresh = self._schedule(merged, product, now)
                result = replace(
                    entry,
                    headers=merged,
                    checked_at=now,
                    next_refresh_at=next_refresh,
                    error=None,
                    failures=0,
                )
            elif status in {200, 203}:
                self._normalize(product, body, now, coords)
                regressed = False
                if entry.fetched_at is not None and entry.body is not None:
                    old = self._normalize(product, entry.body, entry.fetched_at, coords)
                    new = self._normalize(product, body, now, coords)
                    new_origin = new.observed_at or new.issued_at
                    old_origin = old.observed_at or old.issued_at
                    assert new_origin is not None and old_origin is not None
                    regressed = new_origin < old_origin
                if regressed:
                    # An older run from another provider cache node (MET alternates between
                    # runs for a while after an update). Keep the newer data, count the check
                    # as successful and ask again after the minimum interval.
                    jitter = max(0.0, min(self.jitter(), MAX_JITTER))
                    result = replace(
                        entry,
                        checked_at=now,
                        next_refresh_at=now + timedelta(seconds=MIN_REFRESH[product] + jitter),
                        error=None,
                        failures=0,
                    )
                else:
                    next_refresh = self._schedule(received, product, now)
                    original_fetch = entry.fetched_at if body == entry.body else now
                    result = CacheEntry(
                        entry.key,
                        body,
                        original_fetch,
                        received,
                        now,
                        next_refresh,
                        None,
                        0,
                        status == 203,
                    )
            else:
                retry_until = retry_deadline(received.get("retry-after", ""), now)
                if status in {403, 429}:
                    await self.store.throttle(
                        httpx.URL(url).host,
                        max(
                            retry_until or now,
                            now + timedelta(minutes=15),
                        ),
                    )
                raise ProviderError(
                    {403: "provider_forbidden", 429: "provider_throttled"}.get(
                        status,
                        f"provider_http_{status}",
                    )
                )
        except (ProviderError, httpx.HTTPError, TimeoutError) as error:
            now = utc(self.clock.now())
            code = error.code if isinstance(error, ProviderError) else "provider_transport_failure"
            failures = min(entry.failures + 1, 16)
            delay = max(MIN_REFRESH[product], min(60 * 2 ** (failures - 1), 3600)) + max(
                0,
                min(self.jitter(), 120),
            )
            # No inline retry loop: persistent backoff prevents request storms after restart.
            result = replace(
                entry,
                checked_at=now,
                error=code,
                failures=failures,
                next_refresh_at=max(
                    now + timedelta(seconds=delay),
                    retry_until or now,
                    http_date(received.get("expires")) or now,
                    await self.store.cooldown(httpx.URL(url).host) or now,
                ),
            )
        await self.store.write(result, owner)
        return result
