"""Option A safety boundaries and durable history; synthetic, not calibration."""

import asyncio
import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime

import httpx
import pytest
from test_contract import checker, validate_example
from test_evaluation import weather as original_weather

from aurora_backend.api.app import create_app
from aurora_backend.api.forecast import build_forecast
from aurora_backend.config.settings import Settings
from aurora_backend.domain.clock import FixedClock
from aurora_backend.domain.types import Interval, Location
from aurora_backend.evaluation.engine import assess
from aurora_backend.providers.activity import HISTORY_CAPACITY, publication_origin
from aurora_backend.providers.client import ProviderClient
from aurora_backend.providers.models import (
    GridPoint,
    Product,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
)
from aurora_backend.providers.store import CacheEntry, SnapshotStore

AT = datetime(2026, 10, 12, 21, tzinfo=UTC)
LOCATION = Location(latitude=60, longitude=20, timezone="Europe/Stockholm")
HEALTH = SourceHealth(SourceState.FRESH, None, False, AT, AT, AT + timedelta(seconds=1))


def weather(cloud=10):
    result = original_weather(cloud)
    return replace(result, health=replace(result.health, cache_expires_at=AT + timedelta(hours=1)))


def grid(offset, value=80, *, fetched=None, identity=None):
    target = AT + timedelta(minutes=offset)
    return Snapshot(
        identity or f"grid-{offset}-{value}",
        Product.OVATION,
        "NOAA SWPC",
        None,
        target - timedelta(minutes=60),
        target,
        fetched or target - timedelta(minutes=58),
        target,
        target,
        (),
        None,
        grid=(GridPoint(20, 60, value),),
    )


def inputs(left=-5, right=10, a=40, b=80):
    return ProviderResult(grid(55), HEALTH, (grid(left, a), grid(right, b)))


def run(result=None, *, at=AT, **kwargs):
    return assess(
        LOCATION,
        at,
        at,
        ovation=(result or inputs(),),
        weather=weather(),
        altitude=-15,
        **kwargs,
    )


def test_minimum_long_lead_and_provenance_not_observation_age():
    result = run()
    assert result.action == "try_now" and result.activity.value == 40
    assert result.activity.supported_interval == Interval(
        AT - timedelta(minutes=5), AT + timedelta(minutes=10)
    )
    assert result.activity.source_ids == ("grid--5-40", "grid-10-80")
    assert result.activity.temporal_policy == "retained-bracket-min-v1"
    assert AT < result.refresh_after <= AT + timedelta(minutes=10)
    assert result.confidence == "low"


@pytest.mark.parametrize(
    "left,right,expected",
    [
        (-5, 15, "available"),
        (-5, 16, "not_covered"),
        (1, 10, "not_covered"),
        (-20, -1, "not_covered"),
    ],
)
def test_gap_and_no_extrapolation(left, right, expected):
    assert run(inputs(left, right)).activity.state == expected


def test_half_open_boundary_and_exact_only_fallback():
    result = inputs(-5, 0)
    assessment = run(result)
    assert assessment.activity.supported_interval is None
    assert assessment.activity.state == "not_covered"
    assert assessment.action != "try_now"
    assert run(inputs(0, 10)).activity.supported_interval.start == AT


def test_future_receipt_and_missing_cells_cannot_form_bracket():
    result = inputs()
    for bad in (
        replace(result.retained[1], fetched_at=AT + timedelta(seconds=1)),
        replace(result.retained[1], grid=()),
        replace(result.retained[1], validation_status="invalid"),
        replace(result.retained[1], observed_at=AT + timedelta(seconds=1)),
    ):
        assert run(replace(result, retained=(result.retained[0], bad))).action != "try_now"


def test_duplicate_targets_choose_latest_observation_and_are_order_independent():
    result = inputs()
    newer = replace(
        result.retained[0],
        id="updated",
        observed_at=AT - timedelta(minutes=60),
        grid=(GridPoint(20, 60, 2),),
    )
    for retained in ((newer, *result.retained), (*result.retained, newer)):
        assessment = run(replace(result, retained=retained))
        assert assessment.activity.value == 2 and assessment.activity.state == "unknown"
        assert assessment.action != "try_now"


def test_publication_stalls_target_expiry_and_provider_failure():
    result = inputs()
    for changed in (
        replace(result, health=replace(HEALTH, state=SourceState.STALE)),
        replace(result, health=replace(HEALTH, refresh_error="transport_failure")),
        replace(result, snapshot=grid(55, fetched=AT - timedelta(minutes=20))),
        ProviderResult(grid(-21, fetched=AT), HEALTH),
    ):
        assessment = run(changed)
        assert assessment.activity.state == "stale"
        assert assessment.action != "try_now"


def test_bracket_weather_and_darkness_boundaries_and_no_planning_carryover():
    result = inputs(-1, 1)
    assert run(result).refresh_after == AT + timedelta(minutes=1)
    assert run(result, planning=True).activity.state == "unknown"
    assert (
        run(result, interval=Interval(AT, AT + timedelta(minutes=2))).activity.state
        == "not_covered"
    )
    for cloud in (None, 100):
        assessment = assess(
            LOCATION, AT, AT, ovation=(result,), weather=weather(cloud), altitude=-15
        )
        assert assessment.action != "try_now"
    assert (
        assess(LOCATION, AT, AT, ovation=(result,), weather=weather(), altitude=0).rating
        == "unfavorable"
    )


def test_earlier_weather_expiry_and_newest_forecast_do_not_extend_now():
    result = inputs()
    result = replace(result, snapshot=grid(55, 1))
    w = weather()
    w = replace(w, health=replace(w.health, cache_expires_at=AT + timedelta(seconds=30)))
    value = build_forecast(LOCATION, AT, {Product.OVATION: result, Product.WEATHER: w})
    assert value["now"]["action"] == "try_now"
    assert value["refreshAfter"] == "2026-10-12T21:00:30Z"
    assert value["upcomingActivityInstant"]["activity"] == "unknown"
    assert value["upcomingActivityInstant"]["overheadSignal"] == 1
    checker.check_forecast(value)


def test_no_lead_future_observation_is_not_usable_right_endpoint():
    result = inputs()
    right = result.retained[1]
    right = replace(right, observed_at=right.forecast_at, fetched_at=AT)
    assert (
        run(replace(result, retained=(result.retained[0], right))).activity.state == "not_covered"
    )


def test_http_payload_both_sources_interval_and_exact_upcoming_instants():
    result = inputs()
    value = build_forecast(LOCATION, AT, {Product.OVATION: result, Product.WEATHER: weather()})
    validate_example(value, "Forecast")
    checker.check_forecast(value)
    assert value["now"]["action"] == "try_now"
    assert value["upcomingActivityInstant"]["forecastAt"] == "2026-10-12T21:55:00Z"
    assert value["upcomingActivityInstant"]["sourceId"] == result.snapshot.id
    assert value["upcomingActivityInstant"]["overheadSignal"] == 80
    assert value["refreshAfter"] > value["generatedAt"]
    assert value["modelVersion"] == "visibility-v0.2-bracket-prototype"
    assert all(s["status"] == "fresh" for s in value["sources"] if s["role"] == "aurora_short_term")


def test_cold_start_only_exposes_future_point_even_without_darkness():
    result = ProviderResult(grid(55), HEALTH)
    value = build_forecast(LOCATION, AT, {Product.OVATION: result, Product.WEATHER: weather()})
    assert value["now"]["activityEvidence"]["supportedInterval"] is None
    assert value["now"]["factors"]["activity"] == "not_covered"
    assert value["upcomingActivityInstant"] is not None
    polar = Location(latitude=89, longitude=20, timezone="Europe/Stockholm")
    summer = datetime(2026, 6, 21, 12, tzinfo=UTC)
    snapshot = replace(
        grid(55),
        observed_at=summer - timedelta(minutes=5),
        fetched_at=summer,
        forecast_at=summer + timedelta(minutes=55),
        valid_from=summer + timedelta(minutes=55),
        valid_until=summer + timedelta(minutes=55),
    )
    value = build_forecast(polar, summer, {Product.OVATION: ProviderResult(snapshot, HEALTH)})
    assert value["upcoming"] is None and value["upcomingActivityInstant"] is not None
    checker.check_forecast(value)


def test_publication_metadata_never_rewrites_first_receipt():
    snapshot = grid(55, fetched=AT - timedelta(minutes=2))
    assert publication_origin(snapshot) == snapshot.fetched_at
    for modified in (
        "malformed",
        format_datetime(AT + timedelta(minutes=1)),
        format_datetime(AT - timedelta(hours=2)),
    ):
        assert (
            publication_origin(replace(snapshot, cache_headers=(("last-modified", modified),)))
            == snapshot.fetched_at
        )
    modified = AT - timedelta(minutes=3)
    assert (
        publication_origin(
            replace(snapshot, cache_headers=(("last-modified", format_datetime(modified)),))
        )
        == modified
    )


def body(offset):
    from test_contract import ROOT

    value = json.loads(
        (ROOT / "backend/tests/fixtures/providers/captured/ovation.json").read_text()
    )
    value["Observation Time"] = (
        (AT + timedelta(minutes=offset - 60)).isoformat().replace("+00:00", "Z")
    )
    value["Forecast Time"] = (AT + timedelta(minutes=offset)).isoformat().replace("+00:00", "Z")
    return json.dumps(value).encode()


def entry(offset, fetched):
    return CacheEntry(
        Product.OVATION.value, body(offset), fetched, {}, fetched, fetched, None, 0, False
    )


def test_history_survives_restart_retains_original_fetch_and_prunes(tmp_path, monkeypatch):
    monkeypatch.setattr("aurora_backend.providers.store.HISTORY_CAPACITY", 3)
    assert HISTORY_CAPACITY == 192
    path = tmp_path / "cache.sqlite"
    store = SnapshotStore(path)
    store.write(entry(-5, AT - timedelta(minutes=63)))
    store.write(entry(10, AT - timedelta(minutes=48)))
    store.write(entry(55, AT - timedelta(minutes=3)))
    assert len(store.history(AT)) == 2  # only current neighboring targets decoded
    store.close()
    store = SnapshotStore(path)
    try:
        assert len(store.history(AT)) == 2
        store.write(entry(-5, AT))  # repeated body cannot reset original receipt
        assert store.history(AT)[0][1] == AT - timedelta(minutes=63)
        store.write(entry(60, AT))
        assert store.db.execute("SELECT COUNT(*) FROM ovation_history").fetchone()[0] == 3
        assert store.history(AT + timedelta(hours=3, seconds=1)) == ()
    finally:
        store.close()


def test_client_304_and_same_body_never_revive_stalled_publication(tmp_path):
    async def exercise():
        clock = FixedClock(AT)
        requests = []

        def transport(request):
            requests.append(request)
            return httpx.Response(
                200 if len(requests) == 1 else 304,
                content=body(55) if len(requests) == 1 else b"",
                headers={"Cache-Control": "max-age=60"},
            )

        store = SnapshotStore(tmp_path / "cache.sqlite")
        client = ProviderClient(
            store,
            clock=clock,
            transport=httpx.MockTransport(transport),
            request_spacing=0,
            jitter=lambda: 0,
        )
        try:
            first = await client.get(Product.OVATION)
            client.clock = FixedClock(AT + timedelta(minutes=20))
            second = await client.get(Product.OVATION)
            assert second.health.state == SourceState.STALE
            assert first.snapshot.fetched_at == second.snapshot.fetched_at == AT
            assert len(second.retained) == 1
        finally:
            await client.close()
            store.close()

    asyncio.run(exercise())


def test_actual_http_bracket_uses_injected_received_history():
    class Sources:
        async def get(self, product, **kwargs):
            return (
                inputs()
                if product == Product.OVATION
                else weather()
                if product == Product.WEATHER
                else ProviderResult(None, replace(HEALTH, state=SourceState.UNAVAILABLE))
            )

    async def exercise():
        app = create_app(Settings(), FixedClock(AT), Sources())
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.get("/v1/forecast", params=LOCATION.model_dump())
        assert response.status_code == 200
        value = response.json()
        assert value["now"]["action"] == "try_now"
        validate_example(value, "Forecast")
        checker.check_forecast(value)

    asyncio.run(exercise())


def test_provider_history_normalization_and_http_survive_restart(tmp_path):
    """Real complete-grid parser/store/client/HTTP with mocked provider transport."""

    async def exercise():
        path = tmp_path / "cache.sqlite"
        store = SnapshotStore(path)
        clock = FixedClock(AT - timedelta(minutes=63))
        offset = -5

        def transport(request):
            payload = json.loads(body(offset))
            for row in payload["coordinates"]:
                row[2] = 40 if offset == -5 else 80
            return httpx.Response(200, json=payload, headers={"Cache-Control": "max-age=60"})

        client = ProviderClient(
            store,
            clock=clock,
            transport=httpx.MockTransport(transport),
            request_spacing=0,
            jitter=lambda: 0,
        )
        await client.get(Product.OVATION)
        offset = 10
        client.clock = FixedClock(AT - timedelta(minutes=48))
        await client.get(Product.OVATION)
        offset = 55
        client.clock = FixedClock(AT - timedelta(minutes=3))
        await client.get(Product.OVATION)
        await client.close()
        store.close()
        store = SnapshotStore(path)
        client = ProviderClient(
            store,
            clock=FixedClock(AT),
            transport=httpx.MockTransport(transport),
            request_spacing=0,
            jitter=lambda: 0,
        )

        class Sources:
            async def get(self, product, **kwargs):
                if product == Product.OVATION:
                    return await client.get(product)
                return (
                    weather()
                    if product == Product.WEATHER
                    else ProviderResult(None, replace(HEALTH, state=SourceState.UNAVAILABLE))
                )

        try:
            app = create_app(Settings(), FixedClock(AT), Sources())
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as http:
                response = await http.get("/v1/forecast", params=LOCATION.model_dump())
            assert response.status_code == 200
            value = response.json()
            assert value["now"]["action"] == "try_now"
            assert value["now"]["activityEvidence"]["forecastInstants"] == [
                "2026-10-12T20:55:00Z",
                "2026-10-12T21:10:00Z",
            ]
            validate_example(value, "Forecast")
            checker.check_forecast(value)
            assert len(client._normalizations) <= 3
        finally:
            await client.close()
            store.close()

    asyncio.run(exercise())
