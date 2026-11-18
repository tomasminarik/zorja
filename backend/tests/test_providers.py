import asyncio
import hashlib
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest

from aurora_backend.domain.clock import FixedClock
from aurora_backend.providers.client import ProviderClient, http_date, weather_coordinates
from aurora_backend.providers.models import Product, ProviderError, SourceState
from aurora_backend.providers.parsers import MAX_BODY_BYTES, normalize
from aurora_backend.providers.store import SnapshotStore

FIXTURES = Path(__file__).parent / "fixtures/providers"
CAPTURES = FIXTURES / "captured"
AT = datetime(2026, 10, 12, 19, 45, 11, tzinfo=UTC)
COORDS = (18.0686, 59.3293)


def weather_body():
    return (CAPTURES / "met-stockholm.json").read_bytes()


def headers(at=AT, ttl=60):
    return {
        "Expires": (at + timedelta(seconds=ttl)).strftime("%a, %d %b %Y %H:%M:%S GMT"),
        "Last-Modified": "Mon, 12 Oct 2026 19:36:36 GMT",
    }


def test_direct_capture_hashes_and_manifest():
    manifest = json.loads((CAPTURES / "manifest.json").read_text())
    assert manifest["kind"] == "direct-provider-capture"
    for item in manifest["files"]:
        assert hashlib.sha256((CAPTURES / item["name"]).read_bytes()).hexdigest() == item["sha256"]
        assert item["status"] == 200


def test_captured_full_grid_normalized_without_visibility_claim():
    result = normalize(Product.OVATION, (CAPTURES / "ovation.json").read_bytes(), AT)
    assert len(result.grid) == 65160
    assert len({(p.longitude, p.latitude) for p in result.grid}) == 65160
    assert min(p.longitude for p in result.grid) == -180
    assert max(p.longitude for p in result.grid) == 179
    assert result.valid_from == result.valid_until == result.forecast_at
    assert result.fallback_mode == "unknown"
    assert result.covers(result.forecast_at)
    assert not result.covers(result.forecast_at + timedelta(seconds=1))


@pytest.mark.parametrize(
    "change,code",
    [
        (lambda d: d["coordinates"].pop(), "incomplete_grid"),
        (lambda d: d["coordinates"].__setitem__(1, d["coordinates"][0]), "duplicate_grid_point"),
        (lambda d: d["coordinates"][0].__setitem__(2, 101), "invalid_number"),
        (lambda d: d["coordinates"][0].__setitem__(2, True), "invalid_number"),
        (lambda d: d["coordinates"][0].__setitem__(0, 0.5), "unsupported_grid_spacing"),
        (
            lambda d: d.__setitem__("Data Format", "[Latitude, Longitude, Aurora]"),
            "unsupported_grid_format",
        ),
        (lambda d: d.__setitem__("Observation Time", "2026-10-12T20:00:00Z"), "future_issue"),
        (lambda d: d.__setitem__("Forecast Time", "2026-10-12T18:00:00Z"), "invalid_forecast_time"),
    ],
)
def test_grid_corruption(change, code):
    data = json.loads((CAPTURES / "ovation.json").read_bytes())
    change(data)
    with pytest.raises(ProviderError, match=code):
        normalize(Product.OVATION, json.dumps(data).encode(), AT)


@pytest.mark.parametrize(
    "filename,code",
    [
        ("ovation-mini.json", "incomplete_grid"),
        ("ovation-malformed.json", "invalid_shape"),
    ],
)
def test_synthetic_partial_grids_are_never_accepted(filename, code):
    with pytest.raises(ProviderError, match=code):
        normalize(Product.OVATION, (FIXTURES / filename).read_bytes(), AT + timedelta(hours=2))


def valid_kp_text():
    return (FIXTURES / "kp-mini.txt").read_text()


def test_kp_bins_are_utc_half_open_and_duplicates_must_agree():
    text = valid_kp_text()
    result = normalize(Product.KP, text.encode(), AT + timedelta(hours=2))
    assert len(result.kp) == 24
    assert result.kp[0].kp == 2
    assert result.covers(result.kp[0].start)
    assert not result.covers(result.valid_until)
    repeated = normalize(Product.KP, (text + "\n" + text).encode(), AT + timedelta(hours=2))
    assert repeated.kp == result.kp
    with pytest.raises(ProviderError, match="conflicting_kp_tables"):
        normalize(
            Product.KP,
            (text + "\n" + text.replace("2.00", "9.00")).encode(),
            AT + timedelta(hours=2),
        )


def test_direct_kp_conflicting_narrative_is_explicitly_rejected():
    with pytest.raises(ProviderError, match="conflicting_geomagnetic_narrative"):
        normalize(Product.KP, (CAPTURES / "kp.txt").read_bytes(), AT)


@pytest.mark.parametrize(
    "issue,dates",
    [
        ("2026 Dec 31", "Dec 31    Jan 01    Jan 02"),
        ("2028 Feb 28", "Feb 28    Feb 29    Mar 01"),
    ],
)
def test_kp_month_year_and_leap_rollover(issue, dates):
    text = valid_kp_text().replace("2026 Oct 12", issue)
    text = text.replace("Oct 12    Oct 13    Oct 14", dates)
    result = normalize(Product.KP, text.encode(), datetime(2029, 1, 1, tzinfo=UTC))
    assert result.kp[-1].end - result.kp[0].start == timedelta(days=3)


@pytest.mark.parametrize(
    "transform,code",
    [
        (lambda t: t.replace("03-06UT", "00-03UT"), "missing_or_unordered_kp_bin"),
        (lambda t: t.replace("2.00", "10.00"), "invalid_kp_values"),
        (lambda t: t.replace("Oct 14", "Oct 15"), "conflicting_kp_dates"),
        (lambda t: t.replace("UTC", "EST"), "missing_or_conflicting_issue"),
        (lambda t: t.replace("2026 Oct 12 2100", "2026 Oct 13 2100"), "future_issue"),
    ],
)
def test_kp_malformed_and_future_issue(transform, code):
    with pytest.raises(ProviderError, match=code):
        normalize(Product.KP, transform(valid_kp_text()).encode(), AT + timedelta(hours=2))


@pytest.mark.parametrize(
    "name,coords",
    [
        ("stockholm", COORDS),
        ("oslo", (10.7522, 59.9139)),
        ("helsinki", (24.9384, 60.1699)),
        ("berlin", (13.405, 52.52)),
    ],
)
def test_regional_weather_captures_preserve_sampling_and_missing_variables(name, coords):
    result = normalize(Product.WEATHER, (CAPTURES / f"met-{name}.json").read_bytes(), AT, coords)
    assert result.coordinates == coords
    assert result.weather[0].total_cloud is not None
    assert all(sample.low_cloud is None and sample.fog is None for sample in result.weather)
    assert {sample.next_sample_after for sample in result.weather} >= {
        timedelta(hours=1),
        timedelta(hours=6),
        None,
    }
    assert result.covers(result.weather[0].time)
    assert not result.covers(result.weather[0].time + timedelta(minutes=1))


@pytest.mark.parametrize(
    "transform,code",
    [
        (lambda d: d["geometry"]["coordinates"].__setitem__(0, 20), "coordinate_mismatch"),
        (
            lambda d: d["properties"]["meta"]["units"].__setitem__("cloud_area_fraction", "1"),
            "unsupported_units",
        ),
        (lambda d: d["properties"]["timeseries"].reverse(), "unordered_timeseries"),
        (
            lambda d: d["properties"]["timeseries"][0]["data"]["instant"]["details"].__setitem__(
                "cloud_area_fraction", float("nan")
            ),
            "invalid_number",
        ),
        (
            lambda d: d["properties"]["meta"].__setitem__("updated_at", "2026-10-13T00:00:00Z"),
            "future_issue",
        ),
    ],
)
def test_bad_weather(transform, code):
    data = json.loads(weather_body())
    transform(data)
    with pytest.raises(ProviderError, match=code):
        normalize(Product.WEATHER, json.dumps(data).encode(), AT, COORDS)


def test_missing_total_is_not_inferred_from_layers_or_humidity():
    data = json.loads(weather_body())
    details = data["properties"]["timeseries"][0]["data"]["instant"]["details"]
    del details["cloud_area_fraction"]
    result = normalize(Product.WEATHER, json.dumps(data).encode(), AT, COORDS)
    assert result.weather[0].total_cloud is None and result.weather[0].fog is None


@pytest.mark.parametrize(
    "body,code",
    [
        (b'{"type": "Feature", "type": "Other"}', "duplicate_json_key"),
        (b"[]", "invalid_shape"),
        (b"{", "malformed_json"),
        (b" " * (MAX_BODY_BYTES + 1), "response_too_large"),
    ],
)
def test_changed_shapes_and_size_bounds(body, code):
    with pytest.raises(ProviderError, match=code):
        normalize(Product.WEATHER, body, AT, COORDS)


def test_precision_truncates_and_wraps_dateline():
    assert weather_coordinates(59.329399, 18.068699) == COORDS
    assert weather_coordinates(-59.329399, -18.068699) == (-18.0686, -59.3293)
    assert weather_coordinates(0, 180) == (-180, 0)
    for lat, lon in [(float("nan"), 0), (91, 0), (0, 181)]:
        with pytest.raises(ProviderError):
            weather_coordinates(lat, lon)


def run(coro):
    return asyncio.run(coro)


async def weather(client, lat=COORDS[1], lon=COORDS[0]):
    return await client.get(Product.WEATHER, latitude=lat, longitude=lon)


def make_client(tmp_path, handler, **kwargs):
    store = SnapshotStore(tmp_path / "cache.sqlite", kwargs.pop("capacity", 2))
    client = ProviderClient(
        store,
        transport=httpx.MockTransport(handler),
        clock=FixedClock(AT),
        jitter=lambda: 0,
        request_spacing=0,
        **kwargs,
    )
    return store, client


def test_concurrent_requests_share_one_fetch_until_expiry(tmp_path):
    calls = []

    async def handler(request):
        calls.append(request)
        await asyncio.sleep(0.01)
        return httpx.Response(200, content=weather_body(), headers=headers())

    async def scenario():
        store, client = make_client(tmp_path, handler)
        try:
            results = await asyncio.gather(*(weather(client) for _ in range(20)))
            assert len(calls) == 1
            assert all(r.health.state == SourceState.FRESH for r in results)
            assert len({r.snapshot.id for r in results}) == 1
            assert "hello@tomasminarik.com" in calls[0].headers["User-Agent"]
            client.clock = FixedClock(AT + timedelta(seconds=59))
            await weather(client)
            assert len(calls) == 1
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_304_preserves_identity_and_scientific_age(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        if len(calls) == 1:
            return httpx.Response(200, content=weather_body(), headers=headers())
        assert request.headers["If-Modified-Since"] == headers()["Last-Modified"]
        return httpx.Response(304, headers=headers(AT + timedelta(hours=7), 600))

    async def scenario():
        store, client = make_client(tmp_path, handler)
        try:
            first = await weather(client)
            client.clock = FixedClock(AT + timedelta(hours=7))
            second = await weather(client)
            assert first.snapshot.id == second.snapshot.id
            assert first.snapshot.fetched_at == second.snapshot.fetched_at == AT
            assert second.health.state == SourceState.STALE
            assert second.health.refresh_error is None
            assert second.health.checked_at == client.clock.now()
        finally:
            await client.close()
            store.close()

    run(scenario())


@pytest.mark.parametrize(
    "failure,code",
    [
        (httpx.Response(200, content=b"{"), "malformed_json"),
        (httpx.Response(429, headers={"Retry-After": "1800"}), "provider_throttled"),
        (httpx.Response(503), "provider_http_503"),
    ],
)
def test_failure_retains_history_and_persists_backoff_across_restart(tmp_path, failure, code):
    calls = []

    def handler(request):
        calls.append(request)
        return (
            httpx.Response(200, content=weather_body(), headers=headers())
            if len(calls) == 1
            else failure
        )

    async def scenario():
        store, client = make_client(tmp_path, handler)
        first = await weather(client)
        client.clock = FixedClock(AT + timedelta(minutes=1))
        second = await weather(client)
        assert second.snapshot.id == first.snapshot.id
        assert second.health.state == SourceState.STALE
        assert second.health.refresh_error == code
        await client.close()
        store.close()
        store = SnapshotStore(tmp_path / "cache.sqlite", 2)
        client = ProviderClient(
            store,
            transport=httpx.MockTransport(handler),
            clock=FixedClock(AT + timedelta(seconds=61)),
            jitter=lambda: 0,
        )
        try:
            third = await weather(client)
            assert len(calls) == 2
            assert third.snapshot.id == first.snapshot.id
            assert third.health.refresh_error == code
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_unavailable_is_distinct_from_stale_and_capacity_is_hard(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(503)

    async def scenario():
        store, client = make_client(tmp_path, handler, capacity=1)
        try:
            first = await weather(client)
            assert first.health.state == SourceState.UNAVAILABLE and first.snapshot is None
            second = await weather(client, lat=60)
            assert second.health.refresh_error == "weather_capacity_exhausted"
            assert len(calls) == 1
            assert len(client._locks) == 1
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_single_owner_lease(tmp_path):
    store = SnapshotStore(tmp_path / "cache.sqlite")
    try:
        with pytest.raises(ProviderError, match="cache_already_owned"):
            SnapshotStore(tmp_path / "cache.sqlite")
    finally:
        store.close()
    other = SnapshotStore(tmp_path / "cache.sqlite")
    other.close()


def test_refresh_cadence_never_extends_source_validity(tmp_path):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                200,
                content=(CAPTURES / "ovation.json").read_bytes(),
                headers=headers(ttl=1200),
            ),
        )
        try:
            first = await client.get(Product.OVATION)
            assert first.health.state == SourceState.FRESH
            assert first.snapshot.forecast_at > AT  # future forecast, never an observation of now
            for minutes in [15, 30]:
                client.clock = FixedClock(AT + timedelta(minutes=minutes))
                later = await client.get(Product.OVATION)
                assert later.health.state == SourceState.STALE
                assert not later.snapshot.covers(client.clock.now())
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_weather_stays_fresh_until_the_next_scheduled_check(tmp_path):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                200,
                content=weather_body(),
                headers=headers(ttl=60),
            ),
        )
        client.jitter = lambda: 120
        try:
            await weather(client)
            # Past Expires but before the next scheduled check (60 s + jitter): still fresh.
            client.clock = FixedClock(AT + timedelta(seconds=61))
            result = await weather(client)
            assert result.health.state == SourceState.FRESH
            assert result.health.checked_at == AT
            assert result.health.next_refresh_at == AT + timedelta(seconds=180)
            assert result.health.cache_expires_at == AT + timedelta(seconds=240)
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_weather_expired_on_arrival_is_fresh_after_a_successful_check(tmp_path):
    # MET sometimes answers with an Expires already in the past (seen for Tromsø, 2026-11-12).
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(200, content=weather_body(), headers=headers(ttl=-30)),
        )
        try:
            result = await weather(client)
            assert result.health.state == SourceState.FRESH
            assert result.health.cache_expires_at == AT + timedelta(seconds=180)
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_weather_goes_stale_when_the_refresh_fails(tmp_path):
    responses = iter(
        [httpx.Response(200, content=weather_body(), headers=headers(ttl=60)), httpx.Response(500)]
    )

    async def scenario():
        store, client = make_client(tmp_path, lambda r: next(responses))
        client.jitter = lambda: 0
        try:
            await weather(client)
            client.clock = FixedClock(AT + timedelta(seconds=61))
            result = await weather(client)
            assert result.health.refresh_error == "provider_http_500"
            assert result.health.state == SourceState.STALE
        finally:
            await client.close()
            store.close()

    run(scenario())


@pytest.mark.parametrize(
    "status,code",
    [
        (304, "unexpected_304"),
        (403, "provider_forbidden"),
        (203, None),
    ],
)
def test_special_http_statuses(tmp_path, status, code):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                status,
                content=weather_body() if status == 203 else b"",
                headers=headers(),
            ),
        )
        try:
            result = await weather(client)
            assert result.health.refresh_error == code
            assert result.health.deprecated == (status == 203)
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_response_deadline_and_oversize_are_safe_errors(tmp_path):
    async def handler(request):
        await asyncio.sleep(1)
        return httpx.Response(200)

    async def scenario():
        store, client = make_client(tmp_path, handler, deadline_seconds=0.01)
        try:
            result = await weather(client)
            assert result.health.refresh_error == "provider_transport_failure"
        finally:
            await client.close()
            store.close()
        store, client = make_client(
            tmp_path / "large",
            lambda r: httpx.Response(
                200,
                content=b" " * (MAX_BODY_BYTES + 1),
            ),
        )
        try:
            result = await weather(client)
            assert result.health.refresh_error == "response_too_large"
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_http_dates_and_age_corrected_cache_control(tmp_path):
    assert http_date("bad") is None
    assert http_date("Mon, 12 Oct 2026 19:45:11 GMT") == AT

    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                200, content=weather_body(), headers={"Cache-Control": "max-age=120", "Age": "60"}
            ),
        )
        try:
            result = await weather(client)
            # max-age 120 less Age 60, plus the weather grace (60 s minimum + 120 s jitter).
            assert result.health.cache_expires_at == AT + timedelta(seconds=60 + 180)
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_noaa_shared_global_fetch_and_cache_restart(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(
            200, content=(CAPTURES / "ovation.json").read_bytes(), headers=headers()
        )

    async def scenario():
        store, client = make_client(tmp_path, handler)
        results = await asyncio.gather(*(client.get(Product.OVATION) for _ in range(10)))
        assert len(calls) == 1
        first_id = results[0].snapshot.id
        await client.close()
        store.close()
        store, client = make_client(tmp_path, handler)
        try:
            restored = await client.get(Product.OVATION)
            assert restored.snapshot.id == first_id
            assert len(calls) == 1
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_same_body_refetch_does_not_reset_issue_or_fetch_age(tmp_path):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                200,
                content=weather_body(),
                headers=headers(AT + timedelta(hours=7), 60),
            ),
        )
        first = await weather(client)
        client.clock = FixedClock(AT + timedelta(hours=7, minutes=1))
        try:
            second = await weather(client)
            assert second.snapshot.id == first.snapshot.id
            assert second.snapshot.fetched_at == AT
            assert second.health.state == SourceState.STALE
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_recovery_and_regressed_run(tmp_path):
    calls = []
    data = json.loads(weather_body())
    data["properties"]["meta"]["updated_at"] = "2026-10-12T18:00:00Z"
    old = json.dumps(data).encode()
    responses = [
        httpx.Response(200, content=weather_body(), headers=headers()),
        httpx.Response(200, content=old, headers=headers(AT + timedelta(minutes=1))),
        httpx.Response(200, content=weather_body(), headers=headers(AT + timedelta(minutes=2))),
    ]

    def handler(request):
        calls.append(request)
        return responses[len(calls) - 1]

    async def scenario():
        store, client = make_client(tmp_path, handler)
        try:
            first = await weather(client)
            client.clock = FixedClock(AT + timedelta(minutes=1))
            second = await weather(client)
            # An older run from another cache node is not a failure: the newer data stays.
            assert second.health.refresh_error is None
            assert second.health.state == SourceState.FRESH
            assert second.health.checked_at == AT + timedelta(minutes=1)
            assert second.snapshot.id == first.snapshot.id
            client.clock = FixedClock(AT + timedelta(minutes=2))
            third = await weather(client)
            assert third.health.refresh_error is None
            assert third.health.state == SourceState.FRESH
            assert third.snapshot.id == first.snapshot.id
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_host_throttle_blocks_other_keys_and_survives_restart(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(429, headers={"Retry-After": "Mon, 12 Oct 2026 20:45:11 GMT"})

    async def scenario():
        store, client = make_client(tmp_path, handler, capacity=3)
        await weather(client)
        second = await weather(client, lat=60)
        assert second.health.refresh_error == "provider_throttled"
        assert len(calls) == 1
        await client.close()
        store.close()
        store = SnapshotStore(tmp_path / "cache.sqlite", 3)
        client = ProviderClient(store, clock=FixedClock(AT), transport=httpx.MockTransport(handler))
        try:
            third = await weather(client, lat=61)
            assert third.health.refresh_error == "provider_throttled"
            assert third.health.next_refresh_at == AT + timedelta(hours=1)
            assert len(calls) == 1
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_redirect_bounds_and_contact_configuration(tmp_path):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                302,
                headers={"Location": "http://other.example/data"},
            ),
        )
        try:
            result = await weather(client)
            assert result.health.refresh_error == "unsafe_redirect"
            with pytest.raises(ValueError, match="User-Agent"):
                ProviderClient(store, user_agent="python-httpx")
        finally:
            await client.close()
            store.close()

    run(scenario())


def test_live_kp_first_section_annotations_and_partial_coverage():
    # Explicitly derived from capture; never presented as the original whole feed.
    body = (CAPTURES / "kp.txt").read_text().split("\nProduct:", 1)[0].encode()
    result = normalize(Product.KP, body, AT)
    assert result.kp[10].kp == 5  # 13 Oct, 06–09 UTC (G1 annotation)
    assert result.valid_until == datetime(2026, 10, 15, tzinfo=UTC)
    assert not result.covers(datetime(2026, 10, 15, 1, tzinfo=UTC))


def test_zero_lead_ovation_does_not_invent_fallback_flag():
    data = json.loads((CAPTURES / "ovation.json").read_bytes())
    data["Forecast Time"] = data["Observation Time"]
    result = normalize(Product.OVATION, json.dumps(data).encode(), AT)
    assert result.forecast_at == result.observed_at
    assert result.fallback_mode == "unknown"


def test_optional_weather_layers_and_fog_retain_percent_units_and_zero():
    data = json.loads((FIXTURES / "met-mini.json").read_bytes())
    data["properties"]["meta"]["units"]["fog_area_fraction"] = "%"
    data["properties"]["timeseries"][0]["data"]["instant"]["details"]["fog_area_fraction"] = 0
    result = normalize(Product.WEATHER, json.dumps(data).encode(), AT + timedelta(hours=2), COORDS)
    assert result.weather[0].total_cloud == 20
    assert result.weather[0].low_cloud == 5
    assert result.weather[0].medium_cloud == 10
    assert result.weather[0].high_cloud == 15
    assert result.weather[0].fog == 0
    assert result.weather[1].total_cloud is None
    assert result.weather[1].low_cloud == 0
    assert result.weather[1].fog is None


def test_retry_after_longer_than_a_week_is_not_shortened(tmp_path):
    async def scenario():
        store, client = make_client(
            tmp_path,
            lambda r: httpx.Response(
                429,
                headers={"Retry-After": str(30 * 86400)},
            ),
        )
        try:
            result = await weather(client)
            assert result.health.next_refresh_at == AT + timedelta(days=30)
        finally:
            await client.close()
            store.close()

    run(scenario())
