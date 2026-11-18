"""Hosted Redis store against a real local Valkey engine, plus mocked Upstash HTTP.

No hosted account or live provider is used. The engine cases use the project's
local Valkey build or REDIS_TEST_SERVER; otherwise they skip explicitly.
"""

import asyncio
import gzip
import json
import os
import shutil
import subprocess
import tempfile
import time
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
from pydantic import SecretStr
from test_activity_brackets import AT, LOCATION, body

from aurora_backend.api.forecast import build_forecast
from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.budgets import SharedLimits
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product, ProviderError, SourceState
from aurora_backend.providers.redis_store import (
    RedisProviderStore,
    UpstashREST,
    decode,
    encode,
    key_id,
)
from aurora_backend.providers.storage import SQLiteProviderStore
from aurora_backend.providers.store import CacheEntry, SnapshotStore


class Commands:
    """Minimal RESP client over a Unix socket; counts commands like Upstash bills them."""

    def __init__(self, path):
        self.path = path
        self.calls = 0
        self.round_trips = 0
        self.log = []

    async def execute(self, command):
        """Direct inspection for tests; not counted."""
        return (await self._send([command]))[0][0]

    async def pipeline(self, commands):
        self.calls += len(commands)
        self.round_trips += 1
        self.log.append([command[0] for command in commands])
        return await self._send(commands)

    async def _send(self, commands):
        reader, writer = await asyncio.open_unix_connection(self.path, limit=8_000_000)
        request = b""
        for command in commands:
            encoded = [str(value).encode() for value in command]
            request += b"*" + str(len(encoded)).encode() + b"\r\n"
            request += b"".join(b"$%d\r\n%s\r\n" % (len(value), value) for value in encoded)
        writer.write(request)
        await writer.drain()
        received = 0

        async def read():
            nonlocal received
            line = await reader.readline()
            received += len(line)
            tag, value = line[:1], line[1:-2]
            if tag == b"+":
                return value.decode()
            if tag == b"-":
                raise AssertionError("Redis error: " + value.decode())
            if tag == b":":
                return int(value)
            if tag == b"$":
                size = int(value)
                if size == -1:
                    return None
                result = await reader.readexactly(size + 2)
                received += len(result)
                return result[:-2].decode()
            if tag == b"*":
                size = int(value)
                return [] if size == -1 else [await read() for _ in range(size)]
            raise AssertionError("Invalid RESP response")

        try:
            return [await read() for _ in commands], len(request) + received
        finally:
            writer.close()
            await writer.wait_closed()


@pytest.fixture(scope="module")
def engine():
    local = Path(__file__).parents[1] / ".runtime/cache-test/valkey-8.1.11/src/valkey-server"
    executable = os.environ.get("REDIS_TEST_SERVER") or (
        str(local)
        if local.is_file()
        else shutil.which("valkey-server") or shutil.which("redis-server")
    )
    if not executable:
        pytest.skip("Real shared-cache tests require REDIS_TEST_SERVER; no cloud fallback")
    with tempfile.TemporaryDirectory(prefix="aurora-cache-") as directory:
        path = Path(directory)
        process = subprocess.Popen(
            [
                executable,
                "--port",
                "0",
                "--unixsocket",
                str(path / "cache.sock"),
                "--unixsocketperm",
                "700",
                "--save",
                "",
                "--appendonly",
                "no",
                "--maxmemory",
                "128mb",
                "--maxmemory-policy",
                "noeviction",
                "--dir",
                str(path),
                "--logfile",
                str(path / "engine.log"),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 5
            while not (path / "cache.sock").exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    pytest.fail(
                        "Local cache engine failed to start: " + (path / "engine.log").read_text()
                    )
                time.sleep(0.02)
            yield str(path / "cache.sock")
        finally:
            process.terminate()
            process.wait(timeout=5)


@pytest.fixture
def redis(engine):
    return RedisProviderStore(
        Commands(engine), namespace="test-" + uuid4().hex, clock=FixedClock(AT)
    )


def sibling(store, clock=None):
    """Another instance on the same namespace, with nothing in memory."""
    return RedisProviderStore(
        Commands(store.commands.path),
        namespace=store.root[1:-2],
        clock=clock or store.clock,
        limits=store.limits,
        lane=store.lane,
    )


def entry(offset=55, fetched=None):
    return CacheEntry(
        Product.OVATION.value,
        body(offset),
        fetched or AT - timedelta(minutes=3),
        {"etag": "synthetic"},
        AT,
        AT + timedelta(minutes=1),
        None,
        0,
        False,
    )


async def write(store, value):
    await store.reserve(value.key, AT)
    owner = await store.acquire(value.key)
    assert owner
    try:
        await store.write(value, owner)
    finally:
        await store.release(value.key, owner)


def test_sqlite_redis_same_received_history_original_headers_expiry_and_backoff(redis, tmp_path):
    async def exercise():
        disk = SnapshotStore(tmp_path / "cache.sqlite")
        sqlite = SQLiteProviderStore(disk)
        try:
            samples = [
                entry(-5, AT - timedelta(minutes=63)),
                entry(10, AT - timedelta(minutes=48)),
                entry(),
            ]
            for store in (sqlite, redis):
                for sample in samples:
                    await write(store, sample)
                original = await store.history(AT)
                await write(
                    store, replace(samples[1], fetched_at=AT, headers={"etag": "re-fetched"})
                )
                assert await store.history(AT) == original
                await write(
                    store,
                    replace(
                        samples[-1],
                        error="provider_throttled",
                        failures=3,
                        next_refresh_at=AT + timedelta(hours=1),
                    ),
                )
                await store.throttle("api.met.no", AT + timedelta(minutes=15))
            fresh = sibling(redis)
            for other in (redis, fresh):
                assert await sqlite.history(AT) == await other.history(AT)
                assert await sqlite.read(Product.OVATION.value) == await other.read(
                    Product.OVATION.value
                )
                assert await sqlite.cooldown("api.met.no") == await other.cooldown("api.met.no")
            assert await sqlite.history(AT + timedelta(hours=3, seconds=1)) == ()
            assert await sibling(redis).history(AT + timedelta(hours=3, seconds=1)) == ()
            await sqlite.prune_raw(AT + timedelta(hours=49))
            later = FixedClock(AT + timedelta(hours=49))
            # Raw bodies are gone after 48 hours, from Redis reads and from memory.
            for store in (sqlite, sibling(redis, later), replace_clock(redis, later)):
                value = await store.read(Product.OVATION.value)
                assert value.body is None and value.failures == 3
                assert value.next_refresh_at == AT + timedelta(hours=1)
        finally:
            disk.close()

    asyncio.run(exercise())


def replace_clock(store, clock):
    store.clock = clock
    return store


def test_future_received_targets_filter_and_same_forecast_conflict(redis):
    async def exercise():
        await write(redis, entry(-5, AT - timedelta(minutes=63)))
        await write(redis, entry(10, AT - timedelta(minutes=48)))
        original = await redis.history(AT)
        data = json.loads(body(10))
        data["Observation Time"] = (AT - timedelta(minutes=40)).isoformat().replace("+00:00", "Z")
        changed = replace(entry(10, AT), body=json.dumps(data).encode())
        await write(redis, changed)
        assert (await redis.history(AT))[1][0] == changed.body
        await write(redis, entry(55, AT + timedelta(seconds=1)))
        assert await redis.history(AT) == (original[0], (changed.body, AT, changed.headers))
        assert await sibling(redis).history(AT) == await redis.history(AT)
        assert len(await redis.history(AT + timedelta(minutes=1))) == 2

    asyncio.run(exercise())


def test_history_keeps_at_most_192_targets_and_expires(redis):
    async def exercise():
        # Valid full grids on closely spaced synthetic targets isolate the count bound.
        for index in range(193):
            await write(redis, entry(55 + index / 100, AT))
        history = redis.root + "ovation-history"
        assert await redis.commands.execute(["HLEN", history]) == 192
        nearest = await sibling(redis).history(AT)
        assert len(nearest) == 1
        assert nearest[0][0] == entry(55.01, AT).body
        # History and replaced bodies expire with retention; only the latest body stays.
        assert 0 < await redis.commands.execute(["TTL", history]) <= 4 * 3600
        bodies = await redis.commands.execute(["KEYS", redis.root + "body:*"])
        ttls = sorted([await redis.commands.execute(["TTL", key]) for key in bodies])
        assert len(bodies) == 193
        assert all(0 < ttl <= 4 * 3600 for ttl in ttls[:-1]) and ttls[-1] > 40 * 3600

    asyncio.run(exercise())


def test_fractional_receipt_retention_and_exact_target_boundaries(redis):
    async def exercise():
        fetched = AT.replace(microsecond=123456)
        value = replace(entry(), fetched_at=fetched, checked_at=fetched)
        await write(redis, value)
        retained = await redis.history(fetched)
        assert retained[0][1] == fetched
        assert await redis.history(fetched + timedelta(hours=3)) == retained
        assert await redis.history(fetched + timedelta(hours=3, microseconds=1)) == ()
        before = FixedClock(fetched + timedelta(hours=48, microseconds=-1))
        assert (await sibling(redis, before).read(value.key)).body is not None
        after = FixedClock(fetched + timedelta(hours=48))
        assert (await sibling(redis, after).read(value.key)).body is None

    asyncio.run(exercise())


def test_aurora_body_is_stored_once_and_not_sent_again(redis):
    async def exercise():
        value = entry()
        await write(redis, value)
        stored = json.loads(
            await redis.commands.execute(["GET", redis.root + "entry:noaa_ovation"])
        )
        assert stored["body"] is None and stored["digest"]
        assert await redis.commands.execute(["EXISTS", redis.root + "body:" + stored["digest"]])
        # A new instance fetches the body once; afterwards metadata reads skip it.
        reader = sibling(redis)
        assert (await reader.read(value.key)).body == value.body
        assert ["MGET"] in reader.commands.log
        reader.commands.log.clear()
        reader._entries.clear()
        assert (await reader.read(value.key)).body == value.body
        assert reader.commands.log == [["GET"]]
        # Writing the same body again refreshes its expiry instead of sending it.
        redis.commands.log.clear()
        await write(redis, replace(value, checked_at=AT + timedelta(seconds=5)))
        stored_write = [names for names in redis.commands.log if names[-1] == "DEL"][-1]
        assert stored_write.count("SET") == 1 and stored_write[1] == "EXPIRE"

    asyncio.run(exercise())


def test_weather_entries_expire_within_six_hours_and_hide_coordinates(redis):
    async def exercise():
        key = "met:18.0686,59.3293"
        weather = Path(__file__).parent / "fixtures/providers/captured/met-stockholm.json"
        data = json.loads(weather.read_text())
        value = CacheEntry(
            key, json.dumps(data).encode(), AT, {}, AT, AT + timedelta(minutes=30), None, 0, False
        )
        clock = FixedClock(AT)
        redis.clock = clock
        await write(redis, value)
        names = await redis.commands.execute(["KEYS", redis.root + "*"])
        assert not any("18.0686" in name or "59.3293" in name for name in names)
        identity = redis.root + "entry:" + key_id(key)
        assert 0 < await redis.commands.execute(["TTL", identity]) <= 6 * 3600
        assert await sibling(redis).read(key) == value

    asyncio.run(exercise())


def test_refresh_lease_is_exclusive_and_released_by_a_write(redis):
    async def exercise():
        value = entry()
        owner = await redis.acquire(value.key)
        assert owner and await redis.acquire(value.key) is None
        other = sibling(redis)
        assert await other.acquire(value.key) is None
        await redis.write(value, owner)
        assert redis.commands.log[-1][-1] == "DEL"  # the write releases the lease
        calls = redis.commands.calls
        await redis.release(value.key, owner)
        assert redis.commands.calls == calls
        winner = await other.acquire(value.key)
        assert winner
        await other.release(value.key, winner)
        assert await sibling(redis).read(value.key) == value

    asyncio.run(exercise())


def test_shared_cooldown_is_monotonic_and_namespaced(redis):
    async def exercise():
        await redis.throttle("api.met.no", AT + timedelta(minutes=15))
        await redis.throttle("api.met.no", AT + timedelta(minutes=1))
        assert await redis.cooldown("api.met.no") == AT + timedelta(minutes=15)
        other = sibling(redis)
        assert await other.cooldown("api.met.no") == AT + timedelta(minutes=15)
        assert await other.acquire_host("api.met.no", 0) is None
        assert await other.acquire_host("services.swpc.noaa.gov", 0) == "local"
        isolated = RedisProviderStore(
            redis.commands, namespace="separate-" + uuid4().hex, clock=FixedClock(AT)
        )
        assert await isolated.cooldown("api.met.no") is None
        for host in ("example.com", "services.swpc.noaa.gov.evil"):
            with pytest.raises(ProviderError, match="invalid_provider_host"):
                await redis.throttle(host, AT)

    asyncio.run(exercise())


def test_concurrent_clients_only_one_upstream_request(redis):
    async def exercise():
        calls = []

        async def handler(request):
            calls.append(request)
            await asyncio.sleep(0.05)
            return httpx.Response(200, content=body(55), headers={"Cache-Control": "max-age=60"})

        clients = [
            ProviderClient(
                sibling(redis),
                clock=FixedClock(AT),
                transport=httpx.MockTransport(handler),
                jitter=lambda: 0,
                request_spacing=0,
            )
            for _ in range(2)
        ]
        try:
            results = await asyncio.gather(*(client.get(Product.OVATION) for client in clients))
            assert len(calls) == 1
            # The second client waits for the first one's refresh instead of reporting it.
            assert all(result.snapshot is not None for result in results)
            assert all(result.health.state == SourceState.FRESH for result in results)
            warm = await clients[1].get(Product.OVATION)
            assert warm.snapshot is not None and len(calls) == 1
        finally:
            for client in clients:
                await client.close()

    asyncio.run(exercise())


def test_client_restart_304_and_forecast_contract_match_sqlite(redis, tmp_path):
    async def exercise():
        from test_activity_brackets import weather
        from test_contract import checker, validate_example

        for sample in (
            entry(-5, AT - timedelta(minutes=63)),
            entry(10, AT - timedelta(minutes=48)),
            entry(),
        ):
            await write(redis, sample)
        sample = await redis.read(Product.OVATION.value)
        await write(redis, replace(sample, next_refresh_at=AT))
        calls = []

        def handler(request):
            calls.append(request)
            return httpx.Response(304, headers={"Cache-Control": "max-age=60"})

        client = ProviderClient(
            sibling(redis),
            clock=FixedClock(AT),
            transport=httpx.MockTransport(handler),
            request_spacing=0,
            jitter=lambda: 0,
        )
        try:
            result = await client.get(Product.OVATION)
            assert len(calls) == 1
            assert result.snapshot.fetched_at == sample.fetched_at
            assert len(result.retained) == 2
            payload = build_forecast(
                LOCATION, AT, {Product.OVATION: result, Product.WEATHER: weather()}
            )
            validate_example(payload, "Forecast")
            checker.check_forecast(payload)
            # Captured grid at this public point can be weak, but temporal support is preserved.
            assert payload["now"]["activityEvidence"]["supportedInterval"] is not None
        finally:
            await client.close()
        assert (await sibling(redis).read(Product.OVATION.value)).fetched_at == sample.fetched_at

    asyncio.run(exercise())


def test_two_clients_shared_403_backoff_prevents_other_key_request(redis):
    async def exercise():
        calls = []

        def handler(request):
            calls.append(request)
            return httpx.Response(403, headers={"Retry-After": "1800"})

        first, second = (
            ProviderClient(
                store,
                clock=FixedClock(AT),
                transport=httpx.MockTransport(handler),
                jitter=lambda: 0,
                request_spacing=0,
            )
            for store in (redis, sibling(redis))
        )
        try:
            result = await first.get(Product.OVATION)
            assert result.health.refresh_error == "provider_forbidden"
            kp = await second.get(Product.KP)
            assert kp.health.refresh_error == "provider_throttled"
            assert len(calls) == 1
            assert await second.store.cooldown("services.swpc.noaa.gov") == AT + timedelta(
                minutes=30
            )
        finally:
            await first.close()
            await second.close()

    asyncio.run(exercise())


def test_reused_global_data_needs_no_redis_on_a_warm_instance(redis):
    async def exercise():
        from aurora_backend.api.hosted import HOSTED_REUSE

        def handler(request):
            return httpx.Response(200, content=body(55), headers={"Cache-Control": "max-age=60"})

        clock = FixedClock(AT)
        client = ProviderClient(
            redis,
            clock=clock,
            transport=httpx.MockTransport(handler),
            jitter=lambda: 0,
            request_spacing=0,
            reuse=HOSTED_REUSE,
        )
        try:
            first = await client.get(Product.OVATION)
            assert first.snapshot is not None
            calls = redis.commands.calls
            redis.clock = client.clock = FixedClock(AT + timedelta(seconds=30))
            again = await client.get(Product.OVATION)
            assert again.snapshot == first.snapshot
            assert redis.commands.calls == calls
            # Later, only the shared provider cooldowns are checked again.
            redis.clock = client.clock = FixedClock(AT + timedelta(minutes=5))
            assert (await client.get(Product.OVATION)).snapshot == first.snapshot
            assert redis.commands.log[-1] == ["MGET"] and redis.commands.calls == calls + 1
        finally:
            await client.close()

    asyncio.run(exercise())


def test_bounded_cached_fallback_does_not_wait_for_a_slow_remote_store(tmp_path):
    from aurora_backend.api.service import ForecastService

    async def exercise():
        disk = SnapshotStore(tmp_path / "local.sqlite")

        class Stalled(ProviderClient):
            async def get(self, *args, **kwargs):
                await asyncio.sleep(10)

            async def cached(self, *args, **kwargs):
                await asyncio.sleep(10)

        client = Stalled(disk, clock=FixedClock(AT))
        try:
            start = time.monotonic()
            result = await ForecastService(client, deadline=0.25).collect(LOCATION, AT)
            assert result == {} and time.monotonic() - start < 0.5
        finally:
            await client.close()
            disk.close()

    asyncio.run(exercise())


def test_cancellation_never_waits_for_remote_lease_release(tmp_path):
    async def exercise():
        disk = SnapshotStore(tmp_path / "cancel.sqlite")

        class RemoteLike(SQLiteProviderStore):
            async def release(self, key, owner):
                await asyncio.sleep(10)

            async def release_host(self, host, owner, spacing):
                await asyncio.sleep(10)

        async def stalled(request):
            await asyncio.sleep(10)

        client = ProviderClient(
            RemoteLike(disk), clock=FixedClock(AT), transport=httpx.MockTransport(stalled)
        )
        try:
            start = time.monotonic()
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(client.get(Product.OVATION), timeout=0.05)
            assert time.monotonic() - start < 0.3
        finally:
            await client.close()
            disk.close()

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(429),
        httpx.Response(500),
        httpx.Response(200, json=[{"error": "ERR private provider text"}]),
        httpx.Response(200, json=[{"result": 1}, {"result": 2}]),
        httpx.Response(200, content=b"{broken"),
        httpx.Response(200, json={"result": 1}),
        httpx.Response(200, json=[{}]),
    ],
)
def test_rest_safe_errors(response):
    async def exercise():
        rest = UpstashREST(
            "https://synthetic.upstash.io",
            SecretStr("synthetic-secret"),
            transport=httpx.MockTransport(lambda request: response),
        )
        try:
            with pytest.raises(ProviderError, match="cache_unavailable") as error:
                await rest.pipeline([["GET", "key"]])
            assert "private provider text" not in str(error.value)
        finally:
            await rest.close()

    asyncio.run(exercise())


def test_rest_pipeline_framing_credentials_redirects_timeout_and_bounds():
    async def exercise():
        def handler(request):
            assert request.url.path == "/pipeline" and request.url.query == b""
            assert request.headers["authorization"] == "Bearer synthetic-secret"
            assert json.loads(request.content) == [["SET", "a", "1"], ["GET", "a"]]
            return httpx.Response(200, json=[{"result": "OK"}, {"result": "1"}])

        rest = UpstashREST(
            "https://synthetic.upstash.io",
            SecretStr("synthetic-secret"),
            transport=httpx.MockTransport(handler),
        )
        try:
            results, size = await rest.pipeline([["SET", "a", "1"], ["GET", "a"]])
            assert results == ["OK", "1"] and size > 0
        finally:
            await rest.close()
        for response in (
            httpx.Response(307, headers={"Location": "https://example.com"}),
            httpx.Response(200, content=b"x" * 6_000_001),
        ):
            rest = UpstashREST(
                "https://synthetic.upstash.io",
                SecretStr("secret"),
                transport=httpx.MockTransport(lambda r, response=response: response),
            )
            try:
                with pytest.raises(ProviderError):
                    await rest.pipeline([["GET", "key"]])
            finally:
                await rest.close()

        def timeout(request):
            raise httpx.ReadTimeout("secret-bearing exception", request=request)

        rest = UpstashREST(
            "https://synthetic.upstash.io",
            SecretStr("secret"),
            transport=httpx.MockTransport(timeout),
        )
        try:
            with pytest.raises(ProviderError, match="cache_unavailable") as error:
                await rest.pipeline([["GET", "key"]])
            assert "secret-bearing" not in str(error.value)
        finally:
            await rest.close()

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://test.upstash.io",
        "https://example.com",
        "https://test.upstash.io/?token=secret",
        "https://user:secret@test.upstash.io",
        "https://test.upstash.io/not-root",
    ],
)
def test_reject_unsafe_endpoint(endpoint):
    with pytest.raises(ValueError):
        UpstashREST(endpoint, SecretStr("secret"))


def test_encoding_size_checksum_and_raw_expiry():
    value = entry()
    encoded = encode(value)
    assert len(encoded) < len(value.body)
    assert decode(encoded, AT) == value
    assert decode(encoded, value.fetched_at + timedelta(hours=48)).body is None
    separate = json.loads(encode(value, embed=False))
    assert separate["body"] is None
    bodies = {separate["digest"]: json.loads(encoded)["body"]}
    assert decode(json.dumps(separate), AT, bodies) == value
    assert decode(json.dumps(separate), AT).body is None
    for field, replacement in [
        ("body", "invalid-base64!"),
        ("digest", "invalid"),
        ("failures", True),
        ("headers", {"x": 1}),
        ("next_refresh_at", None),
    ]:
        doc = json.loads(encoded)
        doc[field] = replacement
        with pytest.raises(ProviderError, match="cache_payload_invalid"):
            decode(json.dumps(doc), AT)
    # Gzip bomb is stopped before more than the provider bound is allocated.
    doc = json.loads(encoded)
    import base64

    doc["body"] = base64.b64encode(gzip.compress(b"x" * 2_000_001)).decode()
    with pytest.raises(ProviderError, match="cache_payload_invalid"):
        decode(json.dumps(doc), AT)


def test_invalid_keys_and_namespaces_are_bounded():
    for key in ("other", "met:nan,1", "met:181.0000,60.0000", "met:20.0000,91.0000"):
        with pytest.raises(ProviderError, match="invalid_cache_key"):
            key_id(key)
    for name in ("", "{bad}", "x" * 49):
        with pytest.raises(ValueError):
            RedisProviderStore(None, namespace=name)


@pytest.mark.parametrize("month", [11, 12])
def test_exhausted_allowance_stops_redis_use_until_the_next_utc_month(month):
    class Exhausted:
        calls = 0

        async def pipeline(self, commands):
            self.calls += 1
            # Monthly usage above the cap, then the cooldown and minute results.
            return [10**9, 0, 1, [None, None], 1, 1], 100

    async def exercise():
        at = datetime(2026, month, 30 if month == 11 else 31, 23, 59, tzinfo=UTC)
        commands = Exhausted()
        store = RedisProviderStore(commands, clock=FixedClock(at), limits=SharedLimits())
        for _ in range(2):
            assert await store.admit_forecast("blocked") == "work_exhausted"
        with pytest.raises(ProviderError, match="cache_budget_exhausted"):
            await store.read(Product.KP.value)
        assert commands.calls == 1
        store.clock = FixedClock(at + timedelta(minutes=1))
        assert await store.admit_forecast("new-month") == "work_exhausted"
        assert commands.calls == 2

    asyncio.run(exercise())


def test_cancelled_refresh_still_releases_its_lease(tmp_path):
    """A refresh cut off by the forecast deadline frees the source for the next request."""

    async def exercise():
        disk = SnapshotStore(tmp_path / "release.sqlite")
        released = []

        class Leased(SQLiteProviderStore):
            async def release(self, key, owner):
                released.append(key)

        async def stalled(request):
            await asyncio.sleep(10)

        client = ProviderClient(
            Leased(disk), clock=FixedClock(AT), transport=httpx.MockTransport(stalled)
        )
        try:
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(client.get(Product.OVATION), timeout=0.05)
            await asyncio.sleep(0)
            assert released == [Product.OVATION.value]
        finally:
            await client.close()
            disk.close()

    asyncio.run(exercise())


def test_refresh_held_elsewhere_is_not_a_failure(tmp_path, monkeypatch):
    """Another instance refreshing a source neither marks stored data stale nor gives a
    reason to new data: the request waits briefly, then judges what is stored on its dates."""
    import aurora_backend.providers.client as client_module

    monkeypatch.setattr(client_module, "IN_PROGRESS_STEP", 0)

    async def exercise():
        disk = SnapshotStore(tmp_path / "held.sqlite")
        held = False

        class Busy(SQLiteProviderStore):
            async def acquire(self, key):
                return None if held else "local"

        def handler(request):
            return httpx.Response(200, content=body(55), headers={"Cache-Control": "max-age=60"})

        client = ProviderClient(
            Busy(disk),
            clock=FixedClock(AT),
            transport=httpx.MockTransport(handler),
            jitter=lambda: 0,
            request_spacing=0,
        )
        try:
            held = True
            empty = await client.get(Product.OVATION)
            assert empty.snapshot is None
            assert empty.health.state == SourceState.UNAVAILABLE
            assert empty.health.refresh_error == "refresh_in_progress"
            held = False
            first = await client.get(Product.OVATION)
            assert first.health.state == SourceState.FRESH
            # Due for a refresh, still valid, and another instance is fetching it.
            client.clock = FixedClock(AT + timedelta(seconds=61))
            held = True
            again = await client.get(Product.OVATION)
            assert again.snapshot is not None and again.snapshot.id == first.snapshot.id
            assert again.health.refresh_error is None
        finally:
            await client.close()
            disk.close()

    asyncio.run(exercise())
