"""Hosted provider cache on Upstash Redis, using plain commands (docs/hosting.md).

Each instance keeps what it last read or wrote in memory and only asks Redis when
an entry is due for a refresh or past its reuse window. The large OVATION body is
stored once under its digest, so metadata and history never repeat it, and in a
lossless compact form (`compact_grid`) of about 5 KB instead of ~220 KB. Every
command and byte sent is charged to a monthly allowance (`SharedLimits`).
"""

import base64
import gzip
import hashlib
import json
import re
import secrets
import zlib
from collections import OrderedDict
from dataclasses import replace
from datetime import datetime, timedelta
from typing import Any, Protocol

import httpx
from pydantic import SecretStr

from aurora_backend.collection.cadence import slot as collection_slot
from aurora_backend.domain.clock import Clock, SystemClock
from aurora_backend.domain.types import utc
from aurora_backend.providers.activity import HISTORY_CAPACITY, RETENTION
from aurora_backend.providers.budgets import SharedLimits
from aurora_backend.providers.compact_grid import compact, expand
from aurora_backend.providers.models import Product, ProviderError
from aurora_backend.providers.parsers import MAX_BODY_BYTES, normalize
from aurora_backend.providers.storage import History, PreparedRefresh, reusable
from aurora_backend.providers.store import CacheEntry

MAX_WIRE_BYTES = 6_000_000
HOSTS = ("api.met.no", "services.swpc.noaa.gov")
RAW_RETENTION = timedelta(hours=48)
WEATHER_TTL = timedelta(hours=6)
# A replaced OVATION body is kept only as long as history can still use it.
HISTORY_BODY_TTL = RETENTION + timedelta(hours=1)
LEASE_MS = 90_000
USAGE_TTL = 40 * 86_400
COOLDOWN_CHECK = timedelta(seconds=60)
# Stored OVATION bodies in compact form start with this; base64 never contains ":".
GRID_MARKER = "grid1:"


class RedisCommands(Protocol):
    async def pipeline(self, commands: list[list[str | int]]) -> tuple[list[Any], int]:
        """Run commands in order; return their results and the bytes on the wire."""
        ...


class UpstashREST:
    def __init__(
        self,
        endpoint: str,
        token: SecretStr,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        url = httpx.URL(endpoint)
        if (
            url.scheme != "https"
            or not url.host.endswith(".upstash.io")
            or url.port not in (None, 443)
            or url.path not in ("", "/")
            or url.query
            or url.fragment
            or url.userinfo
            or not token.get_secret_value()
        ):
            raise ValueError("A private Upstash HTTPS root endpoint and token are required")
        self.endpoint = str(url.copy_with(path="/pipeline"))
        self._http = httpx.AsyncClient(
            transport=transport,
            trust_env=False,
            follow_redirects=False,
            timeout=httpx.Timeout(1.5, connect=1),
            limits=httpx.Limits(max_connections=4, max_keepalive_connections=4),
            headers={"Authorization": "Bearer " + token.get_secret_value()},
        )

    async def close(self) -> None:
        await self._http.aclose()

    async def pipeline(self, commands: list[list[str | int]]) -> tuple[list[Any], int]:
        payload = json.dumps(commands, separators=(",", ":")).encode()
        if len(payload) > MAX_WIRE_BYTES:
            raise ProviderError("cache_payload_too_large")
        try:
            async with self._http.stream(
                "POST",
                self.endpoint,
                content=payload,
                headers={"Content-Type": "application/json"},
            ) as response:
                if response.status_code != 200:
                    raise ProviderError("cache_unavailable")
                body = bytearray()
                async for chunk in response.aiter_bytes(chunk_size=65536):
                    if len(body) + len(chunk) > MAX_WIRE_BYTES:
                        raise ProviderError("cache_payload_too_large")
                    body.extend(chunk)
            values = json.loads(body)
            if not isinstance(values, list) or len(values) != len(commands):
                raise ValueError("Invalid envelope")
            results = []
            for value in values:
                if not isinstance(value, dict) or "error" in value or "result" not in value:
                    raise ValueError("Command failed")
                results.append(value["result"])
            return results, len(payload) + len(body)
        except ProviderError:
            raise
        except (httpx.HTTPError, TimeoutError, ValueError, RecursionError):
            raise ProviderError("cache_unavailable") from None


def stamp(value: datetime | None) -> str | None:
    return utc(value).isoformat(timespec="microseconds") if value else None


def read_time(value: Any) -> datetime | None:
    return utc(datetime.fromisoformat(value)) if isinstance(value, str) else None


def key_id(key: str) -> str:
    """Redis identity; weather coordinates are hashed, never used as key names."""
    if key in (Product.OVATION.value, Product.KP.value):
        return key
    match = re.fullmatch(r"met:(-?\d{1,3}\.\d{4}),(-?\d{1,2}\.\d{4})", key)
    if not match or not -180 <= float(match[1]) <= 180 or not -90 <= float(match[2]) <= 90:
        raise ProviderError("invalid_cache_key")
    return "met:" + hashlib.sha256(key.encode()).hexdigest()


def pack(body: bytes, *, grid: bool = False) -> str:
    """Gzip and base64. An OVATION grid is stored compactly when it can be rebuilt exactly."""
    compacted = compact(body) if grid else None
    if compacted is not None:
        return GRID_MARKER + base64.b64encode(gzip.compress(compacted, mtime=0)).decode()
    return base64.b64encode(gzip.compress(body, mtime=0)).decode()


def unpack(value: str, digest: str) -> bytes:
    grid = value.startswith(GRID_MARKER)
    compressed = base64.b64decode(value[len(GRID_MARKER) :] if grid else value, validate=True)
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    body = inflater.decompress(compressed, MAX_BODY_BYTES + 1)
    if len(body) > MAX_BODY_BYTES or not inflater.eof or inflater.unused_data:
        raise ValueError("Invalid compressed body")
    if grid:
        body = expand(body)
    if hashlib.sha256(body).hexdigest() != digest:
        raise ValueError("Invalid body checksum")
    return body


def encode(entry: CacheEntry, *, embed: bool = True) -> str:
    """Entry as stored. Without `embed` the body is stored separately by digest."""
    key_id(entry.key)
    origin = target = digest = None
    if entry.body is not None:
        if len(entry.body) > MAX_BODY_BYTES or entry.fetched_at is None:
            raise ProviderError("cache_payload_invalid")
        digest = hashlib.sha256(entry.body).hexdigest()
        product = Product.WEATHER if entry.key.startswith("met:") else Product(entry.key)
        coords = None
        if product == Product.WEATHER:
            lon, lat = entry.key[4:].split(",")
            coords = (float(lon), float(lat))
        # Persist only provider-validated shapes. Weather normalization needs lon/lat.
        # A body the client has just validated comes from the parser's memo.
        snapshot = normalize(product, entry.body, entry.fetched_at, coords)
        origin = snapshot.observed_at or snapshot.issued_at
        target = snapshot.forecast_at if product == Product.OVATION else None
    return json.dumps(
        {
            "key": entry.key,
            "body": pack(entry.body) if entry.body is not None and embed else None,
            "digest": digest,
            "fetched_at": stamp(entry.fetched_at),
            "headers": entry.headers,
            "checked_at": stamp(entry.checked_at),
            "next_refresh_at": stamp(entry.next_refresh_at),
            "error": entry.error,
            "failures": entry.failures,
            "deprecated": entry.deprecated,
            "origin": utc(origin).timestamp() if origin else None,
            "target": utc(target).timestamp() if target else None,
        },
        separators=(",", ":"),
        allow_nan=False,
    )


def decode(value: str, now: datetime, bodies: dict[str, str] | None = None) -> CacheEntry:
    """Read an entry; a separately stored body is looked up in `bodies` by digest."""
    try:
        doc = json.loads(value)
        body = None
        fetched = read_time(doc["fetched_at"])
        packed = doc["body"]
        if packed is None and isinstance(doc["digest"], str):
            packed = (bodies or {}).get(doc["digest"])
        # Raw provider data is never used beyond its retention, wherever it is stored.
        if packed is not None and fetched and fetched > utc(now) - RAW_RETENTION:
            body = unpack(packed, doc["digest"])
        key_id(doc["key"])
        next_refresh = read_time(doc["next_refresh_at"])
        if next_refresh is None:
            raise ValueError("Missing refresh boundary")
        if not isinstance(doc["headers"], dict) or any(
            not isinstance(k, str) or not isinstance(v, str) for k, v in doc["headers"].items()
        ):
            raise ValueError("Invalid headers")
        if type(doc["failures"]) is not int or not 0 <= doc["failures"] <= 16:
            raise ValueError("Invalid failure count")
        if type(doc["deprecated"]) is not bool or (
            doc["error"] is not None and not isinstance(doc["error"], str)
        ):
            raise ValueError("Invalid metadata")
        return CacheEntry(
            doc["key"],
            body,
            fetched,
            doc["headers"],
            read_time(doc["checked_at"]),
            next_refresh,
            doc["error"],
            doc["failures"],
            doc["deprecated"],
        )
    except (ValueError, TypeError, KeyError, zlib.error, RecursionError, AttributeError):
        raise ProviderError("cache_payload_invalid") from None


def next_month(now: datetime) -> datetime:
    return now.replace(
        year=now.year + (now.month == 12),
        month=now.month % 12 + 1,
        day=1,
        hour=0,
        minute=0,
        second=0,
        microsecond=0,
    )


class RedisProviderStore:
    # Cooldowns come from memory refreshed with each admission (see `cooldown`).
    host_lease_checks_cooldown = False
    # Stored OVATION bodies this instance holds, by digest (about 7 KB each when compact).
    BODY_CACHE_ENTRIES = 8
    # Weather entries held in memory; global entries are always kept.
    WEATHER_CACHE_ENTRIES = 64

    def __init__(
        self,
        commands: RedisCommands,
        *,
        namespace: str = "aurora-cache-v2",
        clock: Clock | None = None,
        limits: SharedLimits | None = None,
        lane: str = "forecast",
    ) -> None:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,47}", namespace):
            raise ValueError("A bounded cache namespace is required")
        if lane not in ("forecast", "collector"):
            raise ValueError("Unknown budget lane")
        self.commands, self.clock = commands, clock or SystemClock()
        self.limits, self.lane = limits, lane
        self.root = "{" + namespace + "}:"
        self._entries: OrderedDict[str, CacheEntry] = OrderedDict()
        # Digest of each entry's body as stored in Redis, known even if not loaded.
        self._stored_digests: dict[str, str | None] = {}
        # OVATION history as stored: target epoch -> entry without body.
        self._history: dict[str, str] | None = None
        self._bodies: OrderedDict[str, str] = OrderedDict()
        self._cooldowns: dict[str, datetime] = {}
        self._cooldowns_read: datetime | None = None
        self._written: set[str] = set()
        self._blocked_until: datetime | None = None
        # The minute this instance last saw the shared forecast limit reached.
        self._full_minute: int | None = None
        # Sent but not yet charged to the monthly allowance.
        self.unbilled_commands = 0
        self.unbilled_bytes = 0

    # Keys -----------------------------------------------------------------

    def _entry_key(self, key: str) -> str:
        return self.root + "entry:" + key_id(key)

    def _lease_key(self, key: str) -> str:
        return self.root + "lease:" + key_id(key)

    def _body_key(self, digest: str) -> str:
        return self.root + "body:" + digest

    def _host(self, host: str) -> None:
        if host not in HOSTS:
            raise ProviderError("invalid_provider_host")

    # Transport --------------------------------------------------------------

    async def _run(self, commands: list[list[str | int]]) -> list[Any]:
        now = utc(self.clock.now())
        if self._blocked_until and now < self._blocked_until:
            raise ProviderError("cache_budget_exhausted")
        self.unbilled_commands += len(commands)
        results, size = await self.commands.pipeline(commands)
        self.unbilled_bytes += size
        if len(results) != len(commands):
            raise ProviderError("cache_payload_invalid")
        return results

    def _cooldown_command(self) -> list[str | int]:
        return ["MGET", *(self.root + "cooldown:" + host for host in HOSTS)]

    def _read_cooldowns(self, values: Any, now: datetime) -> None:
        if not isinstance(values, list) or len(values) != len(HOSTS):
            raise ProviderError("cache_payload_invalid")
        try:
            self._cooldowns = {
                host: datetime.fromtimestamp(float(value), utc(now).tzinfo)
                for host, value in zip(HOSTS, values, strict=True)
                if value is not None
            }
        except (ValueError, TypeError, OverflowError):
            raise ProviderError("cache_payload_invalid") from None
        self._cooldowns_read = now

    def _cooldowns_due(self, now: datetime) -> bool:
        return self._cooldowns_read is None or not (
            timedelta(0) <= now - self._cooldowns_read < COOLDOWN_CHECK
        )

    # Monthly allowance --------------------------------------------------------

    async def _charge(self, extra: list[list[str | int]]) -> tuple[list[Any], int, int]:
        """Charge unbilled use plus this call; return extra results and month totals."""
        if self.limits is None:
            raise ValueError("Admission requires shared limits")
        now = utc(self.clock.now())
        usage = self.root + "usage:" + now.strftime("%Y%m")
        commands: list[list[str | int]] = [
            ["HINCRBY", usage, self.lane + "_commands", 0],
            ["HINCRBY", usage, self.lane + "_bytes", 0],
            ["EXPIRE", usage, USAGE_TTL],
            self._cooldown_command(),
            *extra,
        ]
        # This call's commands are charged in advance; its bytes on the next call.
        charged_commands = self.unbilled_commands + len(commands)
        charged_bytes = self.unbilled_bytes
        commands[0][3], commands[1][3] = charged_commands, charged_bytes
        results = await self._run(commands)
        self.unbilled_commands -= charged_commands
        self.unbilled_bytes -= charged_bytes
        self._read_cooldowns(results[3], now)
        try:
            used_commands, used_bytes = int(results[0]), int(results[1])
        except (TypeError, ValueError):
            raise ProviderError("cache_payload_invalid") from None
        command_cap = getattr(self.limits, self.lane + "_commands")
        byte_cap = getattr(self.limits, self.lane + "_bytes")
        if used_commands > command_cap or used_bytes > byte_cap:
            # Stop asking Redis until the allowance can have changed.
            self._blocked_until = min(now + timedelta(hours=24), next_month(now))
            raise ProviderError("cache_budget_exhausted")
        return results[4:], used_commands, used_bytes

    async def admit_forecast(self, owner: str) -> str:
        assert self.limits is not None
        number = int(utc(self.clock.now()).timestamp() // 60)
        if number == self._full_minute:
            # Already full this minute: refuse without spending Redis commands, so a
            # flood of refused requests cannot use up the monthly allowance.
            return "rate_limited"
        minute = self.root + "forecast-minute:" + str(number)
        try:
            results, _, _ = await self._charge([["INCR", minute], ["EXPIRE", minute, 120]])
        except ProviderError as error:
            if error.code == "cache_budget_exhausted":
                return "work_exhausted"
            raise
        if not isinstance(results[0], int):
            raise ProviderError("cache_payload_invalid")
        if results[0] > self.limits.forecasts_per_minute:
            self._full_minute = number
            return "rate_limited"
        return "admitted"

    async def claim_collection(self, owner: str, replay_id: str) -> str:
        """One collection per 10-minute slot; a signed request is valid in one slot only."""
        slot = str(collection_slot(self.clock.now()))
        replay = self.root + "collection-replay:" + replay_id
        try:
            results, _, _ = await self._charge(
                [["SET", replay, slot, "NX", "EX", 1200], ["GET", replay]]
            )
        except ProviderError as error:
            if error.code == "cache_budget_exhausted":
                return "work_exhausted"
            raise
        if results[1] != slot:
            return "duplicate"
        key = self.root + "collection:" + slot
        claimed = (await self._run([["SET", key, owner, "NX", "EX", 1200]]))[0]
        return slot if claimed == "OK" else "duplicate"

    async def finish_collection(self, owner: str, slot: str, success: bool) -> None:
        if not success:
            # Free the slot so a scheduler retry can try again.
            await self._run([["DEL", self.root + "collection:" + slot]])

    # Provider cache ---------------------------------------------------------

    def _memo(self, key: str, now: datetime) -> CacheEntry | None:
        """The remembered entry, without a body past raw-data retention."""
        entry = self._entries.get(key)
        if (
            entry is not None
            and entry.body is not None
            and entry.fetched_at is not None
            and utc(entry.fetched_at) <= utc(now) - RAW_RETENTION
        ):
            entry = replace(entry, body=None)
            self._entries[key] = entry
        return entry

    def _keep(self, key: str, entry: CacheEntry) -> None:
        self._entries[key] = entry
        self._entries.move_to_end(key)
        weather = [k for k in self._entries if k.startswith("met:")]
        for old in weather[: max(0, len(weather) - self.WEATHER_CACHE_ENTRIES)]:
            del self._entries[old]
            self._stored_digests.pop(old, None)

    def _remember(self, digest: str, packed: str) -> None:
        self._bodies[digest] = packed
        self._bodies.move_to_end(digest)
        while len(self._bodies) > self.BODY_CACHE_ENTRIES:
            self._bodies.popitem(last=False)

    async def _load_bodies(self, digests: set[str]) -> dict[str, str]:
        """Bodies by digest, from memory or one MGET. Expired bodies are absent."""
        missing = sorted(d for d in digests if d not in self._bodies)
        if missing:
            values = (await self._run([["MGET", *map(self._body_key, missing)]]))[0]
            if not isinstance(values, list) or len(values) != len(missing):
                raise ProviderError("cache_payload_invalid")
            for digest, value in zip(missing, values, strict=True):
                if isinstance(value, str):
                    self._remember(digest, value)
        return {d: self._bodies[d] for d in digests if d in self._bodies}

    @staticmethod
    def _digest(value: str) -> tuple[str | None, bool]:
        """The stored body's digest, and whether the body is stored separately."""
        try:
            doc = json.loads(value)
        except (ValueError, RecursionError):
            raise ProviderError("cache_payload_invalid") from None
        digest = doc.get("digest") if isinstance(doc, dict) else None
        if not isinstance(digest, str):
            return None, False
        return digest, doc.get("body") is None

    async def _decode(self, key: str, value: Any, now: datetime) -> CacheEntry | None:
        if value is None:
            return None
        if not isinstance(value, str):
            raise ProviderError("cache_payload_invalid")
        digest, separate = self._digest(value)
        bodies = await self._load_bodies({digest}) if digest and separate else {}
        entry = decode(value, now, bodies)
        if entry.key != key:
            raise ProviderError("cache_payload_invalid")
        if key == Product.OVATION.value and self._stored_digests.get(key) != digest:
            self._history = None  # a new run was stored: history changed too
        self._stored_digests[key] = digest
        return entry

    def _set_history(self, value: Any) -> None:
        if value == []:
            value = {}
        if isinstance(value, list):  # RESP2 flat field/value list
            value = dict(zip(value[::2], value[1::2], strict=True))
        if not isinstance(value, dict) or any(
            not isinstance(k, str) or not isinstance(v, str) for k, v in value.items()
        ):
            raise ProviderError("cache_payload_invalid")
        self._history = value

    async def prepare(
        self,
        key: str,
        host: str,
        now: datetime,
        *,
        with_history: bool = False,
        reuse_since: datetime | None = None,
    ) -> PreparedRefresh:
        self._host(host)
        now = utc(now)
        history_key = self.root + "ovation-history"
        entry = self._memo(key, now)
        if entry is not None and not (now < entry.next_refresh_at or reusable(entry, reuse_since)):
            entry = None  # due, or past reuse: another instance may have refreshed it
        commands: list[list[str | int]] = []
        if entry is None:
            commands.append(["GET", self._entry_key(key)])
            if with_history:
                commands.append(["HGETALL", history_key])
        elif with_history and self._history is None:
            commands.append(["HGETALL", history_key])
        if self._cooldowns_due(now):
            commands.append(self._cooldown_command())
        if commands:
            results = await self._run(commands)
            position = 0
            if entry is None:
                entry = await self._decode(key, results[0], now)
                position = 1
            if with_history and position < len(results) and commands[position][0] == "HGETALL":
                self._set_history(results[position])
                position += 1
            if position < len(results):
                self._read_cooldowns(results[position], now)
        if entry is None:
            entry = CacheEntry(key, None, None, {}, None, now, None, 0, False)
        self._keep(key, entry)
        history = await self._select_history(now) if with_history else None
        blocked = self._cooldowns.get(host)
        if blocked is not None and now < blocked:
            throttled = replace(
                entry,
                error="provider_throttled",
                next_refresh_at=max(entry.next_refresh_at, blocked),
            )
            return PreparedRefresh(throttled, None, history)
        if now < entry.next_refresh_at or reusable(entry, reuse_since):
            return PreparedRefresh(entry, None, history)
        owner = secrets.token_hex(32)
        acquired, latest_value = await self._run(
            [
                ["SET", self._lease_key(key), owner, "NX", "PX", LEASE_MS],
                ["GET", self._entry_key(key)],
            ]
        )
        latest = await self._decode(key, latest_value, now) or entry
        changed = latest != entry
        self._keep(key, latest)
        if changed and with_history:
            # The entry moved on after the first read; read history again later.
            self._history = None
            history = None
        if acquired != "OK":
            return PreparedRefresh(replace(latest, error="refresh_in_progress"), None, history)
        return PreparedRefresh(latest, owner, history)

    async def _select_history(self, now: datetime) -> History:
        """The latest run at or before `now` and the earliest run after it."""
        if self._history is None:
            self._set_history((await self._run([["HGETALL", self.root + "ovation-history"]]))[0])
        assert self._history is not None
        earliest = (now - RETENTION).timestamp()
        runs = []
        for target, value in self._history.items():
            doc = json.loads(value)
            fetched = read_time(doc.get("fetched_at"))
            if fetched is None or not earliest <= fetched.timestamp() <= now.timestamp():
                continue
            runs.append((float(target), value, doc.get("digest")))
        before = max((r for r in runs if r[0] <= now.timestamp()), default=None)
        after = min((r for r in runs if r[0] > now.timestamp()), default=None)
        chosen = [r for r in (before, after) if r is not None]
        bodies = await self._load_bodies({r[2] for r in chosen if isinstance(r[2], str)})
        result = []
        for _, value, _ in chosen:
            entry = decode(value, now, bodies)
            if entry.key != Product.OVATION.value:
                raise ProviderError("cache_payload_invalid")
            if entry.body is not None and entry.fetched_at is not None:
                result.append((entry.body, entry.fetched_at, entry.headers))
        return tuple(result)

    async def reserve(self, key: str, now: datetime) -> None:
        key_id(key)  # entries are created by their first write

    async def read(self, key: str) -> CacheEntry | None:
        now = utc(self.clock.now())
        if key in self._entries:
            return self._memo(key, now)
        entry = await self._decode(key, (await self._run([["GET", self._entry_key(key)]]))[0], now)
        if entry is not None:
            self._keep(key, entry)
        return entry

    async def write(self, entry: CacheEntry, owner: str) -> None:
        now = utc(self.clock.now())
        stored = entry
        ttl = RAW_RETENTION if not entry.key.startswith("met:") else WEATHER_TTL
        if entry.body is not None and entry.fetched_at is not None:
            remaining = utc(entry.fetched_at) + RAW_RETENTION - now
            if remaining <= timedelta(seconds=1):
                stored = replace(entry, body=None)
            else:
                ttl = min(ttl, remaining)
        seconds = max(1, int(ttl.total_seconds()))
        commands: list[list[str | int]]
        if entry.key == Product.OVATION.value:
            commands = await self._ovation_writes(stored, now, seconds)
        else:
            commands = [["SET", self._entry_key(entry.key), encode(stored), "EX", seconds]]
        # A successful write also releases the refresh lease.
        commands.append(["DEL", self._lease_key(entry.key)])
        try:
            await self._run(commands)
        except BaseException:
            self._history = None  # may be partly written: read it again
            raise
        self._keep(entry.key, stored)
        self._stored_digests[entry.key] = (
            hashlib.sha256(stored.body).hexdigest() if stored.body is not None else None
        )
        if len(self._written) >= 256:
            self._written.clear()
        self._written.add(owner)

    async def _ovation_writes(
        self, entry: CacheEntry, now: datetime, seconds: int
    ) -> list[list[str | int]]:
        history_key = self.root + "ovation-history"
        value = encode(entry, embed=False)
        doc = json.loads(value)
        commands: list[list[str | int]] = [
            ["SET", self._entry_key(entry.key), value, "EX", seconds]
        ]
        old_digest = self._stored_digests.get(entry.key)
        if entry.body is not None:
            digest = doc["digest"]
            packed = self._bodies.get(digest) or pack(entry.body, grid=True)
            self._remember(digest, packed)
            if digest == old_digest:
                commands.append(["EXPIRE", self._body_key(digest), seconds])
            else:
                commands.append(["SET", self._body_key(digest), packed, "EX", seconds])
                if old_digest:
                    commands.append(
                        [
                            "EXPIRE",
                            self._body_key(old_digest),
                            int(HISTORY_BODY_TTL.total_seconds()),
                        ]
                    )
        if doc["target"] is None or entry.body is None:
            return commands
        # History by target time: a newer run replaces an older one for the same target.
        self._set_history((await self._run([["HGETALL", history_key]]))[0])
        assert self._history is not None
        history = dict(self._history)
        member = repr(float(doc["target"]))
        prior = json.loads(history[member]) if member in history else None
        if prior is None or doc["origin"] >= prior["origin"]:
            copy = dict(doc)
            if prior is not None and prior["digest"] == doc["digest"]:
                copy.update(fetched_at=prior["fetched_at"], headers=prior["headers"])
            history[member] = json.dumps(copy, separators=(",", ":"))
            commands.append(["HSET", history_key, member, history[member]])
        cutoff = now - RETENTION
        expired = {
            target
            for target, stored in history.items()
            if (read_time(json.loads(stored)["fetched_at"]) or now) < cutoff
        }
        kept = sorted((t for t in history if t not in expired), key=float)
        expired.update(kept[: max(0, len(kept) - HISTORY_CAPACITY)])
        if expired:
            commands.append(["HDEL", history_key, *sorted(expired)])
            for target in expired:
                history.pop(target)
        commands.append(["EXPIRE", history_key, int(HISTORY_BODY_TTL.total_seconds())])
        self._history = history
        return commands

    async def prune_raw(self, now: datetime) -> None:
        """Retention is enforced by key expiry and when entries are read."""

    async def history(self, now: datetime) -> History:
        return await self._select_history(utc(now))

    async def cooldown(self, host: str) -> datetime | None:
        self._host(host)
        now = utc(self.clock.now())
        if self._cooldowns_due(now):
            self._read_cooldowns((await self._run([self._cooldown_command()]))[0], now)
        return self._cooldowns.get(host)

    async def throttle(self, host: str, until: datetime) -> None:
        self._host(host)
        key = self.root + "cooldown:" + host
        now = utc(self.clock.now())
        old = (await self._run([["GET", key]]))[0]
        try:
            current = float(old) if old is not None else None
        except (TypeError, ValueError):
            raise ProviderError("cache_payload_invalid") from None
        target = utc(until).timestamp()
        if current is None or target > current:
            # Relative expiry, so clock differences with Redis cannot drop it early.
            seconds = max(1, int(target - now.timestamp()) + 1)
            await self._run([["SET", key, repr(target), "EX", seconds]])
            self._cooldowns[host] = utc(until)
        elif current is not None:
            self._cooldowns[host] = datetime.fromtimestamp(current, now.tzinfo)

    async def acquire(self, key: str) -> str | None:
        owner = secrets.token_hex(32)
        result = (await self._run([["SET", self._lease_key(key), owner, "NX", "PX", LEASE_MS]]))[0]
        return owner if result == "OK" else None

    async def release(self, key: str, owner: str) -> None:
        if owner in self._written:
            self._written.discard(owner)  # released by the write itself
            return
        await self._run([["DEL", self._lease_key(key)]])

    async def acquire_host(self, host: str, spacing: float) -> str | None:
        """Request spacing is per instance (ProviderClient); cooldowns are shared."""
        self._host(host)
        blocked = self._cooldowns.get(host)
        if blocked is not None and utc(self.clock.now()) < blocked:
            return None
        return "local"

    async def release_host(self, host: str, owner: str, spacing: float) -> None:
        self._host(host)
