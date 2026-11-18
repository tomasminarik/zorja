"""Aurora reach groups, the southern night outlook and "active since"."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta

import pytest

from aurora_backend.api.forecast import aurora_outlook, build_forecast
from aurora_backend.astronomy import reach as reach_module
from aurora_backend.astronomy.reach import AuroraReach, aurora_reach, magnetic_latitude
from aurora_backend.domain.types import Interval, Location
from aurora_backend.evaluation.engine import active_since
from aurora_backend.providers.models import (
    GridPoint,
    KpBin,
    Product,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
)

AT = datetime(2026, 10, 12, 21, tzinfo=UTC)
EDINBURGH = Location(latitude=55.95, longitude=-3.19, timezone="Europe/London")
SOUTH = AuroraReach("south", 53.13, 6.43, 4.43)


# Values from aacgmv2 2.7.1 at 110 km, epoch 2026-11-01 (the table's source).
@pytest.mark.parametrize(
    ("lat", "lon", "expected", "group"),
    [
        (69.65, 18.96, 67.26, "under_zone"),  # Tromsø
        (64.15, -21.94, 64.19, "under_zone"),  # Reykjavík
        (62.45, -114.37, 68.52, "under_zone"),  # Yellowknife
        (59.91, 10.75, 57.16, "edge"),  # Oslo
        (59.33, 18.07, 56.40, "edge"),  # Stockholm
        (49.90, -97.14, 58.66, "edge"),  # Winnipeg
        (55.95, -3.19, 53.13, "south"),  # Edinburgh
        (57.48, -4.22, 54.98, "south"),  # Inverness, just under the edge line
        (52.23, 21.01, 48.65, "south"),  # Warsaw
        (-42.88, 147.33, 53.71, "south"),  # Hobart, southern hemisphere uses |m|
    ],
)
def test_launch_places(lat: float, lon: float, expected: float, group: str) -> None:
    reach = aurora_reach(lat, lon)
    assert reach.magnetic_latitude == pytest.approx(expected, abs=0.02)
    assert reach.group == group
    assert reach.kp_overhead == pytest.approx((66 - reach.magnetic_latitude) / 2, abs=0.01)
    assert reach.kp_low_in_north == pytest.approx(reach.kp_overhead - 2, abs=0.01)


@pytest.mark.parametrize(
    ("m", "group"),
    [
        (62.0, "under_zone"),
        (61.99, "edge"),
        (55.0, "edge"),
        (54.99, "south"),
        (-62.0, "under_zone"),
    ],
)
def test_band_edges(monkeypatch: pytest.MonkeyPatch, m: float, group: str) -> None:
    monkeypatch.setattr(reach_module, "magnetic_latitude", lambda lat, lon: m)
    assert aurora_reach(0, 0).group == group


def test_undefined_magnetic_latitude_is_south_without_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(reach_module, "magnetic_latitude", lambda lat, lon: None)
    assert aurora_reach(0, 0) == AuroraReach("south", None, None, None)


def test_lookup_wraps_longitude_and_reaches_poles() -> None:
    assert magnetic_latitude(60, 180) == pytest.approx(magnetic_latitude(60, -180))
    assert magnetic_latitude(60, 359.5) == pytest.approx(magnetic_latitude(60, -0.5))
    assert magnetic_latitude(90, 0) is not None and magnetic_latitude(-90, 0) is not None
    with pytest.raises(ValueError):
        magnetic_latitude(91, 0)


def kp_result(
    values: list[float], *, start: datetime = AT - timedelta(hours=3), state=SourceState.FRESH
) -> ProviderResult:
    bins = tuple(
        KpBin(start + timedelta(hours=3 * i), start + timedelta(hours=3 * (i + 1)), v)
        for i, v in enumerate(values)
    )
    snapshot = Snapshot(
        "kp",
        Product.KP,
        "NOAA SWPC",
        AT - timedelta(hours=1),
        None,
        None,
        AT,
        bins[0].start,
        bins[-1].end,
        (),
        None,
        kp=bins,
    )
    expires = AT + timedelta(hours=1)
    return ProviderResult(snapshot, SourceHealth(state, None, False, AT, expires, expires))


NIGHT = [Interval(AT, AT + timedelta(hours=6))]


@pytest.mark.parametrize(
    ("values", "status", "highest"),
    [
        ([1, 4.43, 2, 1], "could_reach", 4.43),  # equal to kpLowInNorth reaches
        ([1, 4.0, 4.4, 1], "not_expected", 4.4),
        ([1, 2, 6, 1], "could_reach", 6),
        ([1, 2], "not_known_yet", None),  # forecast ends inside the dark hours
    ],
)
def test_south_outlook(values: list[float], status: str, highest: float | None) -> None:
    outlook = aurora_outlook(SOUTH, kp_result(values), NIGHT, AT)
    assert outlook == {"status": status, "highestKp": highest, "sourceId": "kp"}


def test_outlook_ignores_elapsed_dark_hours() -> None:
    # Kp 7 only before now: the remaining dark hours decide.
    night = [Interval(AT - timedelta(hours=3), AT + timedelta(hours=3))]
    assert aurora_outlook(SOUTH, kp_result([7, 2]), night, AT)["status"] == "not_expected"


def test_outlook_uses_every_dark_window() -> None:
    windows = [
        Interval(AT, AT + timedelta(hours=1)),
        Interval(AT + timedelta(hours=7), AT + timedelta(hours=8)),
    ]
    assert aurora_outlook(SOUTH, kp_result([1, 1, 1, 5]), windows, AT)["highestKp"] == 5


@pytest.mark.parametrize("group", ["under_zone", "edge"])
def test_outlook_not_applicable_under_zone_and_edge(group: str) -> None:
    value = aurora_outlook(replace(SOUTH, group=group), None, NIGHT, AT)  # type: ignore[arg-type]
    assert value == {
        "status": "not_applicable",
        "highestKp": None,
        "sourceId": "noaa_three_day:unavailable",
    }


def test_outlook_missing_and_expired_forecast() -> None:
    assert aurora_outlook(SOUTH, None, NIGHT, AT)["status"] == "unavailable"
    stale = kp_result([9, 9, 9], state=SourceState.STALE)
    assert aurora_outlook(SOUTH, stale, NIGHT, AT) == {
        "status": "stale",
        "highestKp": None,
        "sourceId": "kp",
    }
    # Issued more than 24 hours ago: expired by age even if the cache said fresh.
    old = kp_result([9, 9, 9])
    old = replace(old, snapshot=replace(old.snapshot, issued_at=AT - timedelta(hours=25)))
    assert aurora_outlook(SOUTH, old, NIGHT, AT)["status"] == "stale"


def test_never_reached_places_are_not_expected_even_without_data() -> None:
    far = AuroraReach("south", 40.0, 13.0, 11.0)
    assert aurora_outlook(far, kp_result([9, 9, 9]), NIGHT, AT) == {
        "status": "not_expected",
        "highestKp": 9,
        "sourceId": "kp",
    }
    assert aurora_outlook(far, None, NIGHT, AT)["status"] == "not_expected"
    undefined = AuroraReach("south", None, None, None)
    assert aurora_outlook(undefined, kp_result([1, 2]), NIGHT, AT)["status"] == "not_expected"


def test_polar_and_daylight_nights_in_forecast() -> None:
    # Polar night at a southern-group place is impossible, so use the serializer
    # end to end: Svalbard in polar night is under the zone, Edinburgh in June
    # has no qualifying darkness and falls back to the whole night period.
    svalbard = Location(latitude=78.22, longitude=15.65, timezone="Arctic/Longyearbyen")
    winter = datetime(2026, 12, 21, 12, tzinfo=UTC)
    value = build_forecast(svalbard, winter, {Product.KP: kp_result([5] * 30, start=winter)})
    assert value["auroraReach"]["group"] == "under_zone"
    assert {n["auroraOutlook"]["status"] for n in value["planning"]} == {"not_applicable"}
    june = datetime(2026, 6, 21, 12, tzinfo=UTC)
    fresh = kp_result([5] * 30, start=june)
    fresh = replace(
        fresh,
        snapshot=replace(fresh.snapshot, issued_at=june, fetched_at=june),
        health=replace(fresh.health, cache_expires_at=june + timedelta(hours=1)),
    )
    value = build_forecast(EDINBURGH, june, {Product.KP: fresh})
    assert value["auroraReach"]["group"] == "south"
    assert all(not n["windows"] for n in value["planning"])
    assert [n["auroraOutlook"]["status"] for n in value["planning"]] == ["could_reach"] * 3


def run(minutes: int, value: float, *, received: datetime = AT) -> Snapshot:
    target = AT + timedelta(minutes=minutes)
    return Snapshot(
        f"run{minutes}",
        Product.OVATION,
        "NOAA SWPC",
        None,
        min(target - timedelta(minutes=40), received),
        target,
        received - timedelta(minutes=1),
        target,
        target,
        (),
        None,
        grid=tuple(GridPoint(lon, lat, value) for lon in (-4, -3) for lat in (55, 56)),
    )


def ovation(runs: list[Snapshot]) -> tuple[ProviderResult, ...]:
    health = SourceHealth(SourceState.FRESH, None, False, AT, AT, AT)
    return (ProviderResult(runs[-1], health, tuple(runs)),)


def test_active_since_finds_stretch_start() -> None:
    runs = [run(-60, 40), run(-45, 5), run(-30, 40), run(-15, 40), run(-5, 40), run(10, 40)]
    assert active_since(ovation(runs), EDINBURGH, AT) == (AT - timedelta(minutes=30), False)


def test_active_since_gap_breaks_stretch() -> None:
    runs = [run(-90, 40), run(-60, 40), run(-5, 40), run(10, 40)]  # 55-minute gap
    assert active_since(ovation(runs), EDINBURGH, AT) == (AT - timedelta(minutes=5), False)


def test_active_since_buffer_limited_at_retention_start() -> None:
    runs = [run(m, 40) for m in range(-200, 11, 15)]
    since, limited = active_since(ovation(runs), EDINBURGH, AT)
    assert limited and since is not None and since >= AT - timedelta(hours=3)
    assert active_since(ovation([run(-5, 40), run(10, 40)]), EDINBURGH, AT)[1] is True


def test_active_since_none_when_quiet_or_stale() -> None:
    assert active_since(ovation([run(-5, 40), run(10, 5)]), EDINBURGH, AT) == (None, False)
    assert active_since((), EDINBURGH, AT) == (None, False)
    stale = ovation([run(-5, 40, received=AT - timedelta(hours=1)), run(10, 40)])
    stale = (replace(stale[0], health=replace(stale[0].health, state=SourceState.STALE)),)
    assert active_since(stale, EDINBURGH, AT) == (None, False)


def test_forecast_now_active_since_only_when_active() -> None:
    runs = [run(-30, 40), run(-15, 40), run(-5, 40), run(10, 40)]
    value = build_forecast(EDINBURGH, AT, {Product.OVATION: ovation(runs)[0]})
    assert value["now"]["factors"]["activity"] == "supported"
    assert value["now"]["activeSince"] == "2026-10-12T20:30:00Z"
    assert value["now"]["activeSinceIsBufferLimited"] is True
    quiet = [run(-5, 1), run(10, 1)]
    value = build_forecast(EDINBURGH, AT, {Product.OVATION: ovation(quiet)[0]})
    assert value["now"]["activeSince"] is None
    assert value["now"]["activeSinceIsBufferLimited"] is False
