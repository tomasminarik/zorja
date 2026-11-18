"""Signed collector requests and monthly Redis allowances; no cloud usage."""

import asyncio
import base64
import hashlib
import hmac
import json
import secrets
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import httpx
import pytest
import test_redis_store
from pydantic import SecretStr
from test_activity_brackets import body as old_grid
from test_redis_store import Commands

from aurora_backend.api.app import create_app
from aurora_backend.collection.endpoint import Collector
from aurora_backend.collection.signatures import InvalidSignature, QStashVerifier
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.budgets import SharedLimits
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import Product
from aurora_backend.providers.redis_store import RedisProviderStore

engine = test_redis_store.engine

CURRENT = SecretStr("synthetic-current-signing-key-" + "c" * 32)
NEXT = SecretStr("synthetic-next-signing-key-" + "n" * 32)
DESTINATION = "https://synthetic.example/internal/collect/ovation"
BODY = b'{"task":"ovation"}'


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def signed(at, *, payload=None, body=BODY, key=CURRENT, header=None):
    now = int(at.timestamp())
    claims = {
        "iss": "Upstash",
        "sub": DESTINATION,
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "jti": "synthetic_" + uuid4().hex,
        "body": b64(hashlib.sha256(body).digest()),
    }
    claims.update(payload or {})
    head = b64(json.dumps(header or {"alg": "HS256", "typ": "JWT"}).encode())
    data = b64(json.dumps(claims).encode())
    sig = b64(
        hmac.new(
            key.get_secret_value().encode(), (head + "." + data).encode(), hashlib.sha256
        ).digest()
    )
    return head + "." + data + "." + sig


def verifier():
    return QStashVerifier(DESTINATION, CURRENT, NEXT)


@pytest.fixture
def at():
    return datetime.now(UTC)


@pytest.fixture
def budgeted(engine, at):
    return RedisProviderStore(
        Commands(engine),
        namespace="budget-" + uuid4().hex,
        clock=FixedClock(at),
        limits=SharedLimits(),
    )


def collector_store(engine, at, limits=None):
    return RedisProviderStore(
        Commands(engine),
        namespace="collector-" + uuid4().hex,
        limits=limits or SharedLimits(),
        lane="collector",
        clock=FixedClock(at),
    )


async def usage(store):
    key = store.root + "usage:" + store.clock.now().strftime("%Y%m")
    values = await store.commands.execute(["HGETALL", key])
    return {name: int(value) for name, value in zip(values[::2], values[1::2], strict=True)}


def test_rotating_keys_body_hash_and_exact_expiry(at):
    for key in (CURRENT, NEXT):
        token = signed(at, key=key)
        assert len(verifier().verify(token, BODY, at)) == 64
        with pytest.raises(InvalidSignature):
            verifier().verify(token, BODY + b" ", at)
    token = signed(at)
    expires = datetime.fromtimestamp(int(at.timestamp()) + 300, UTC)
    verifier().verify(token, BODY, expires - timedelta(microseconds=1))
    with pytest.raises(InvalidSignature):
        verifier().verify(token, BODY, expires)


@pytest.mark.parametrize(
    "claims",
    [
        {"iss": "other"},
        {"sub": "https://wrong.example/internal/collect/ovation"},
        {"exp": True},
        {"iat": "123"},
        {"nbf": False},
        {"body": "invalid"},
        {"jti": ""},
        {"jti": "x" * 129},
        {"jti": "../unsafe"},
        {"iat": 0},
        {"exp": 0},
    ],
)
def test_claims_fail_closed(at, claims):
    with pytest.raises(InvalidSignature):
        verifier().verify(signed(at, payload=claims), BODY, at)


def test_small_clock_drift_is_accepted(at):
    now = int(at.timestamp())
    token = signed(at, payload={"iat": now + 30, "nbf": now + 30, "exp": now + 300})
    assert len(verifier().verify(token, BODY, at)) == 64


def test_future_oversized_wrong_algorithm_and_duplicate_claims(at):
    now = int(at.timestamp())
    for token in (
        signed(at, payload={"nbf": now + 61}),
        signed(at, payload={"iat": now + 61, "exp": now + 120}),
        signed(at, payload={"exp": now + 301}),
        signed(at, header={"alg": "none"}),
        signed(at, header={"alg": "HS256", "crit": ["x"]}),
        "bad",
        "x" * 8193,
    ):
        with pytest.raises(InvalidSignature):
            verifier().verify(token, BODY, at)
    token = signed(at)
    head, payload, _ = token.split(".")
    duplicate = (
        base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)).decode()[:-1]
        + ',"iss":"Upstash"}'
    )
    payload = b64(duplicate.encode())
    sig = b64(
        hmac.new(
            CURRENT.get_secret_value().encode(), (head + "." + payload).encode(), hashlib.sha256
        ).digest()
    )
    with pytest.raises(InvalidSignature):
        verifier().verify(head + "." + payload + "." + sig, BODY, at)


def make_grid(at):
    data = json.loads(old_grid(55))
    data["Observation Time"] = (at - timedelta(minutes=5)).isoformat().replace("+00:00", "Z")
    data["Forecast Time"] = (at + timedelta(minutes=55)).isoformat().replace("+00:00", "Z")
    return json.dumps(data).encode()


def grid_upstream(at, calls):
    def handler(request):
        calls.append(request)
        assert request.url.host == "services.swpc.noaa.gov" and not request.url.query
        return httpx.Response(200, content=make_grid(at), headers={"Cache-Control": "max-age=60"})

    return handler


def always(now):
    return True


def collector_app(store, at, transport, *, clock=None, due=always):
    clock = clock or FixedClock(at)
    client = ProviderClient(
        store, clock=clock, transport=transport, jitter=lambda: 0, request_spacing=0
    )
    collector = Collector(verifier(), store, client, clock, due=due)
    return create_app(Settings(), clock, collector=collector), client, collector


def test_signed_collector_http_refreshes_global_grid_only(engine, at):
    async def exercise():
        store = collector_store(engine, at)
        upstream = []
        app, client, collector = collector_app(
            store, at, httpx.MockTransport(grid_upstream(at, upstream))
        )
        try:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                response = await http.post(
                    "/internal/collect/ovation",
                    content=BODY,
                    headers={"Upstash-Signature": signed(at)},
                )
                assert response.status_code == 200 and response.json()["status"] == "collected"
                result = await http.post(
                    "/internal/collect/ovation",
                    content=BODY,
                    headers={"Upstash-Signature": signed(at, key=NEXT)},
                )
                assert result.json()["status"] == "duplicate"
            assert len(upstream) == 1
            assert await store.read(Product.OVATION.value) is not None
            assert collector.metrics["success"] == 1
            # Commands are charged when the next request is claimed.
            used = store.commands.calls
            # About 16 for the first collection and 7 for the duplicate.
            print("LOCAL_COLLECTOR_PROFILE", json.dumps({"collection_and_duplicate": used}))
            assert used <= 25
            assert (await usage(store))["collector_commands"] == used - store.unbilled_commands
        finally:
            await client.close()

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "variant,expected",
    [
        ("unsigned", 401),
        ("wrong_body", 401),
        ("duplicate_headers", 401),
        ("query", 401),
        ("oversized", 413),
        ("wrong_task", 400),
    ],
)
def test_collector_rejects_before_storage(engine, at, variant, expected):
    async def exercise():
        store = collector_store(engine, at)

        async def forbidden(request):
            raise AssertionError("Unauthorized request touched provider")

        app, client, _ = collector_app(store, at, httpx.MockTransport(forbidden))
        data, path = BODY, "/internal/collect/ovation"
        headers = [("Upstash-Signature", signed(at))]
        if variant == "unsigned":
            headers = []
        if variant == "wrong_body":
            data = BODY + b" "
        if variant == "duplicate_headers":
            headers *= 2
        if variant == "query":
            path += "?latitude=60"
        if variant == "oversized":
            data = b"x" * 257
        if variant == "wrong_task":
            data = b'{"task":"weather","latitude":60}'
            headers = [("Upstash-Signature", signed(at, body=data))]
        try:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                result = await http.post(path, content=data, headers=headers)
                assert result.status_code == expected
            assert store.commands.calls == 0
        finally:
            await client.close()

    asyncio.run(exercise())


def test_one_collection_per_slot_and_a_signed_request_is_valid_in_one_slot(engine, at):
    async def exercise():
        store = collector_store(engine, at)
        slot = await store.claim_collection("first", "a" * 64)
        assert slot.isdigit()
        assert await store.claim_collection("second", "b" * 64) == "duplicate"
        # A failed attempt frees the slot for a retry.
        await store.finish_collection("first", slot, False)
        assert await store.claim_collection("retry", "c" * 64) == slot
        await store.finish_collection("retry", slot, True)
        assert await store.claim_collection("after-success", "d" * 64) == "duplicate"
        # The same request in the next slot is refused.
        store.clock = FixedClock(at + timedelta(minutes=10))
        assert await store.claim_collection("replayed", "a" * 64) == "duplicate"
        assert (await store.claim_collection("next", "e" * 64)).isdigit()

    asyncio.run(exercise())


def test_collector_provider_failure_is_bounded_and_never_accepted_as_fresh(engine, at):
    async def exercise():
        store = collector_store(engine, at)
        calls = []

        def handler(request):
            calls.append(request)
            return httpx.Response(503, headers={"Retry-After": "60"})

        _, client, job = collector_app(store, at, httpx.MockTransport(handler))
        try:
            for replay in ("a", "b", "c"):
                assert await job.run(replay * 64) == (503, "source_unavailable")
            assert len(calls) == 1  # provider backoff survives the retries
        finally:
            await client.close()

    asyncio.run(exercise())


def test_concurrent_signed_callbacks_cannot_duplicate_global_fetch(engine, at):
    async def exercise():
        store = collector_store(engine, at)
        calls = []

        async def handler(request):
            calls.append(request)
            await asyncio.sleep(0.05)
            return httpx.Response(200, content=make_grid(at))

        app, client, _ = collector_app(store, at, httpx.MockTransport(handler))
        try:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://synthetic.example"
            ) as http:
                replies = await asyncio.gather(
                    *(
                        http.post(
                            "/internal/collect/ovation",
                            content=BODY,
                            headers={"Upstash-Signature": signed(at)},
                        )
                        for _ in range(2)
                    )
                )
                assert sorted(reply.json()["status"] for reply in replies) == [
                    "collected",
                    "duplicate",
                ]
                assert len(calls) == 1
        finally:
            await client.close()

    asyncio.run(exercise())


def test_forecast_minute_limit_is_shared_between_instances(budgeted):
    async def exercise():
        limits = SharedLimits(forecasts_per_minute=3)
        budgeted.limits = limits
        second = test_redis_store.sibling(budgeted)
        results = [
            await store.admit_forecast(secrets.token_hex(8))
            for store in (budgeted, second, budgeted, second)
        ]
        assert results == ["admitted"] * 3 + ["rate_limited"]
        # Once an instance has seen the minute full, it refuses without asking Redis.
        calls = second.commands.calls
        assert await second.admit_forecast("refused") == "rate_limited"
        assert second.commands.calls == calls
        budgeted.clock = second.clock = FixedClock(budgeted.clock.now() + timedelta(minutes=1))
        assert await second.admit_forecast("next-minute") == "admitted"

    asyncio.run(exercise())


def test_default_runtime_does_not_expose_collector_and_applies_shared_limit(budgeted, at):
    async def exercise():
        budgeted.limits = SharedLimits(forecasts_per_minute=1)
        default = create_app(Settings(), FixedClock(at))
        app = create_app(Settings(), FixedClock(at), shared_admission=budgeted)
        assert await budgeted.admit_forecast("first") == "admitted"
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=default), base_url="https://test"
        ) as http:
            assert (await http.post("/internal/collect/ovation")).status_code == 404
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://test"
        ) as http:
            result = await http.get(
                "/v1/forecast",
                params={"latitude": 60, "longitude": 20, "timezone": "Europe/Stockholm"},
            )
            assert result.status_code == 429 and result.headers["retry-after"] == "60"
            assert result.json()["code"] == "rate_limited"
        assert app.state.forecast_service._active == 0

    asyncio.run(exercise())


def test_forecast_allowance_exhaustion_keeps_the_collector_lane(engine, at):
    async def exercise():
        limits = SharedLimits(forecast_commands=40)
        forecasts = RedisProviderStore(
            Commands(engine), namespace="lanes-" + uuid4().hex, limits=limits, clock=FixedClock(at)
        )
        assert await forecasts.admit_forecast("one") == "admitted"
        await forecasts.read(Product.KP.value)
        while (result := await forecasts.admit_forecast("more")) == "admitted":
            pass
        assert result == "work_exhausted"
        calls = forecasts.commands.calls
        assert await forecasts.admit_forecast("blocked") == "work_exhausted"
        assert forecasts.commands.calls == calls  # the instance stops asking Redis
        collector = RedisProviderStore(
            Commands(engine),
            namespace=forecasts.root[1:-2],
            limits=limits,
            lane="collector",
            clock=FixedClock(at),
        )
        assert (await collector.claim_collection("job", "a" * 64)).isdigit()
        used = await usage(forecasts)
        assert used["forecast_commands"] > 40 and used["collector_commands"] > 0

    asyncio.run(exercise())


def test_byte_allowance_is_enforced(engine, at):
    async def exercise():
        store = RedisProviderStore(
            Commands(engine),
            namespace="bytes-" + uuid4().hex,
            limits=SharedLimits(forecast_bytes=2_000),
            clock=FixedClock(at),
        )
        assert await store.admit_forecast("one") == "admitted"
        await store.commands.execute(["SET", "{" + store.root[1:-2] + "}:filler", "x" * 5_000])
        await store._run([["GET", "{" + store.root[1:-2] + "}:filler"]])
        assert await store.admit_forecast("two") == "work_exhausted"

    asyncio.run(exercise())


def recorded_app(store):
    from aurora_backend.api.replay import RecordedSources

    captures = Path(__file__).parent / "fixtures/providers/captured"
    recorded = RecordedSources(captures, "stockholm")
    clock = FixedClock(recorded.at)
    store.clock = clock
    upstream = []

    def respond(request):
        upstream.append(request)
        name = (
            "met-stockholm.json"
            if request.url.host == "api.met.no"
            else "ovation.json"
            if request.url.path.endswith(".json")
            else "kp.txt"
        )
        return httpx.Response(
            200, content=(captures / name).read_bytes(), headers=recorded.entries[name]["headers"]
        )

    from aurora_backend.api.hosted import HOSTED_REUSE

    client = ProviderClient(
        store,
        clock=clock,
        transport=httpx.MockTransport(respond),
        request_spacing=0,
        jitter=lambda: 0,
        reuse=HOSTED_REUSE,
    )
    app = create_app(Settings(response_deadline=5), clock, client, shared_admission=store)
    return app, client, upstream


QUERY = {"latitude": 59.3293, "longitude": 18.0686, "timezone": "Europe/Stockholm"}


def test_forecast_command_and_byte_profile(budgeted):
    """Measured per-forecast cost for the decision record; bounds guard regressions."""

    async def exercise():
        from test_contract import validate_example

        app, client, upstream = recorded_app(budgeted)
        cold_instance = test_redis_store.sibling(budgeted)
        profile = {}
        try:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://test"
            ) as http:
                for mode in ("cold", "warm"):
                    calls, size = budgeted.commands.calls, budgeted.unbilled_bytes
                    response = await http.post("/v1/forecast", json=QUERY)
                    assert response.status_code == 200
                    validate_example(response.json(), "Forecast")
                    profile[mode] = budgeted.commands.calls - calls
                assert len(upstream) == 3
            # Another instance with nothing in memory, data already in Redis.
            other, other_client, other_upstream = recorded_app(cold_instance)
            try:
                async with httpx.AsyncClient(
                    transport=httpx.ASGITransport(app=other), base_url="https://test"
                ) as http:
                    assert (await http.post("/v1/forecast", json=QUERY)).status_code == 200
                profile["new_instance"] = cold_instance.commands.calls
                profile["new_instance_bytes"] = cold_instance.unbilled_bytes
                assert other_upstream == []
            finally:
                await other_client.close()
        finally:
            await client.close()
        del size
        print("LOCAL_FORECAST_PROFILE", json.dumps(profile, sort_keys=True))
        assert profile["warm"] <= 6
        assert profile["cold"] <= 30
        assert profile["new_instance"] <= 12
        assert profile["new_instance_bytes"] < 40_000  # compact grid (was ~225 KB)

    asyncio.run(exercise())


def test_cancelled_shared_admission_releases_local_capacity(budgeted, at):
    async def exercise():
        async def stalled(owner):
            await asyncio.sleep(10)

        budgeted.admit_forecast = stalled
        app = create_app(Settings(), FixedClock(at), shared_admission=budgeted)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://test"
        ) as http:
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(
                    http.get(
                        "/v1/forecast",
                        params={"latitude": 60, "longitude": 20, "timezone": "Europe/Stockholm"},
                    ),
                    timeout=0.05,
                )
        assert app.state.forecast_service._active == 0

    asyncio.run(exercise())


def test_deadline_keeps_local_capacity_until_evaluation_ends(budgeted, monkeypatch):
    import threading

    entered, unblock = threading.Event(), threading.Event()

    def blocked(*args):
        entered.set()
        assert unblock.wait(10)
        return {}

    monkeypatch.setattr("aurora_backend.api.app.build_forecast", blocked)

    async def exercise():
        app = create_app(Settings(response_deadline=0.5), shared_admission=budgeted)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="https://test"
        ) as http:
            pending = asyncio.create_task(http.post("/v1/forecast", json=QUERY))
            try:
                assert await asyncio.to_thread(entered.wait, 5)
                assert (await asyncio.wait_for(pending, 5)).status_code == 503
                assert app.state.forecast_service._active == 1
            finally:
                unblock.set()
                await asyncio.gather(pending, return_exceptions=True)
            for _ in range(100):
                if app.state.forecast_service._active == 0:
                    break
                await asyncio.sleep(0.01)
            assert app.state.forecast_service._active == 0

    asyncio.run(exercise())


class MovingClock:
    def __init__(self, at):
        self.instant = at

    def now(self):
        return self.instant


def test_a_call_that_is_not_due_touches_neither_redis_nor_noaa(engine, at):
    async def exercise():
        store = collector_store(engine, at)

        async def forbidden(request):
            raise AssertionError("A call that is not due touched the provider")

        _, client, job = collector_app(
            store, at, httpx.MockTransport(forbidden), due=lambda now: False
        )
        try:
            assert await job.run("a" * 64) == (200, "not_due")
            assert store.commands.calls == 0 and job.metrics["not_due"] == 1
        finally:
            await client.close()

    asyncio.run(exercise())


async def sent_bytes(store):
    """Bytes charged to the allowance plus those not yet charged."""
    return (await usage(store)).get("collector_bytes", 0) + store.unbilled_bytes


def test_steady_collection_every_ten_minutes_profile(engine, at):
    """Measured per-collection cost for the hosting page; bounds guard regressions."""

    async def exercise():
        clock = MovingClock(at)
        store = collector_store(engine, at)
        store.clock = clock

        def handler(request):
            return httpx.Response(
                200, content=make_grid(clock.now()), headers={"Cache-Control": "max-age=60"}
            )

        _, client, job = collector_app(store, at, httpx.MockTransport(handler), clock=clock)
        commands, sizes, cpu = [], [], []
        try:
            for step in range(8):
                clock.instant = at + timedelta(minutes=10 * step)
                calls, size = store.commands.calls, await sent_bytes(store)
                started = time.process_time()
                assert await job.run(f"{step:064d}") == (200, "collected")
                cpu.append(time.process_time() - started)
                commands.append(store.commands.calls - calls)
                sizes.append(await sent_bytes(store) - size)
        finally:
            await client.close()
        steady = {
            "commands": max(commands[2:]),
            "bytes": max(sizes[2:]),
            # Includes building the synthetic grid; not asserted (machine dependent).
            "cpu_ms": round(1000 * max(cpu[2:])),
        }
        print("LOCAL_STEADY_COLLECTION_PROFILE", json.dumps(steady))
        assert steady["commands"] <= 18
        assert steady["bytes"] < 40_000

    asyncio.run(exercise())
