import hashlib
import json
import os
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from aurora_backend.astronomy.solar import classify_altitude, solar_altitude
from aurora_backend.astronomy.windows import (
    _threshold_intervals,
    calculate_windows,
    darkness_windows,
)
from aurora_backend.domain.timezones import iana_zone
from aurora_backend.domain.types import Interval, Location

FIXTURES = Path(__file__).parent / "fixtures/astronomy"


def location(latitude=59.3293, longitude=18.0686, timezone="Europe/Stockholm"):
    return Location(latitude=latitude, longitude=longitude, timezone=timezone)


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def rows(path):
    table = path.read_text().split("$$SOE\n")[1].split("$$EOE")[0]
    for line in table.splitlines():
        fields = line.split(",")
        yield (
            datetime.strptime(fields[0].strip().split(".")[0], "%Y-%b-%d %H:%M:%S").replace(
                tzinfo=UTC
            ),
            float(fields[4]),
        )


@pytest.mark.parametrize(
    "altitude,expected",
    [
        (0, "daylight"),
        (-0.001, "civil_twilight"),
        (-6, "nautical_twilight"),
        (-12, "astronomical_twilight"),
        (-18, "astronomical_night"),
        (-90, "astronomical_night"),
    ],
)
def test_twilight_edges(altitude, expected):
    assert classify_altitude(altitude) == expected


@pytest.mark.parametrize("value", [float("nan"), float("inf"), 91, -91])
def test_invalid_altitude(value):
    with pytest.raises(ValueError):
        classify_altitude(value)


def test_jpl_independent_altitude_reference():
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    count = 0
    for record in manifest["records"]:
        path = FIXTURES / record["file"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"]
        site = location(record["latitude"], record["longitude"])
        for at, reference in rows(path):
            assert abs(solar_altitude(site, at) - reference) < 0.05, (record["file"], at)
            count += 1
    assert count >= 4000


@pytest.mark.parametrize("name", ["stockholm", "tromso", "helsinki"])
def test_crossings_against_independent_minute_reference(name):
    records = json.loads((FIXTURES / "manifest.json").read_text())["records"]
    record = next(r for r in records if r["file"] == f"{name}-crossings.txt")
    samples = list(rows(FIXTURES / record["file"]))
    reference_crossings = []
    for (left, a), (right, b) in zip(samples, samples[1:], strict=False):
        if (a <= -12) != (b <= -12):
            reference_crossings.append(left + (right - left) * ((-12 - a) / (b - a)))
    coverage = Interval(samples[0][0], samples[-1][0])
    windows = darkness_windows(location(record["latitude"], record["longitude"]), coverage)
    crossings = [
        edge
        for w in windows
        for edge in [w.interval.start, w.interval.end]
        if edge not in [coverage.start, coverage.end]
    ]
    assert len(crossings) == len(reference_crossings) >= 2
    assert all(
        abs((a - b).total_seconds()) < 60
        for a, b in zip(crossings, reference_crossings, strict=True)
    )


@pytest.mark.parametrize(
    "site",
    [
        location(69.6492, 18.9553, "Europe/Oslo"),
        location(67.8558, 20.2253),
        location(69.909, 27.028, "Europe/Helsinki"),
    ],
)
def test_midnight_sun_and_winter_polar_night(site):
    summer = calculate_windows(site, instant("2026-06-21T00:00Z"))
    assert summer.upcoming_status == "no_darkness_within_horizon"
    assert all(n.darkness_status == "no_darkness" for n in summer.planning)
    winter = calculate_windows(site, instant("2026-12-21T11:00Z"))
    assert winter.altitude_degrees < 0
    assert winter.category != "astronomical_night"
    assert winter.upcoming is not None


def test_continuous_darkness_bounded_and_detail_clipped():
    result = calculate_windows(location(90, 0, "UTC"), instant("2026-12-21T00:00Z"))
    assert result.upcoming.interval == Interval(
        result.evaluated_at, result.evaluated_at + timedelta(hours=72)
    )
    assert result.upcoming.end_is_search_limited
    assert result.upcoming.start_is_clipped
    assert result.upcoming_detail.interval.end - result.upcoming_detail.interval.start == timedelta(
        hours=24
    )
    assert result.upcoming_detail.end_is_search_limited
    assert all(w.end_is_search_limited for n in result.planning for w in n.windows)


def test_northern_bright_twilight_without_midnight_sun():
    result = calculate_windows(location(), instant("2026-06-21T22:00Z"))
    assert result.altitude_degrees < 0
    assert result.category in ["civil_twilight", "nautical_twilight"]
    assert result.upcoming is None


def test_qualifying_twilight_does_not_require_astronomical_night():
    result = calculate_windows(location(), instant("2026-05-01T22:00Z"))
    assert result.category == "astronomical_twilight"
    assert result.upcoming.interval.start == result.evaluated_at


@pytest.mark.parametrize(
    "at,label",
    [
        ("2026-10-12T01:00Z", "2026-10-11"),
        ("2026-10-12T08:00Z", "2026-10-12"),
        ("2026-10-12T10:00Z", "2026-10-12"),
    ],
)
def test_real_solar_night_labels(at, label):
    result = calculate_windows(location(), instant(at))
    assert result.planning[0].period.local_date.isoformat() == label
    assert len(result.planning) == 3
    for night in result.planning:
        for w in night.windows:
            assert w.interval.start >= result.evaluated_at
            assert (
                night.period.interval.start
                <= w.interval.start
                < w.interval.end
                <= night.period.interval.end
            )


@pytest.mark.parametrize("at,hours", [("2026-03-28T12:00Z", 23), ("2026-10-24T12:00Z", 25)])
def test_calculated_dst_windows(at, hours):
    result = calculate_windows(location(), instant(at))
    period = result.planning[0].period.interval
    assert (period.end - period.start).total_seconds() == hours * 3600
    assert result.planning[-1].period.interval.end <= result.coverage.end


def test_multiple_windows_in_clock_noon_period():
    result = calculate_windows(location(59, -120, "Europe/Stockholm"), instant("2026-03-20T11:00Z"))
    assert len(result.planning[0].windows) == 2
    first, second = result.planning[0].windows
    assert first.interval.end < second.interval.start


def test_boundary_refinement_and_immediate_sides():
    coverage = Interval(instant("2026-03-20T12:00Z"), instant("2026-03-21T12:00Z"))
    (window,) = darkness_windows(location(), coverage)
    for edge in [window.interval.start, window.interval.end]:
        assert abs(solar_altitude(location(), edge) + 12) < 0.001
    assert solar_altitude(location(), window.interval.start - timedelta(seconds=1)) > -12
    assert solar_altitude(location(), window.interval.start + timedelta(seconds=1)) < -12
    assert solar_altitude(location(), window.interval.end - timedelta(seconds=1)) < -12
    assert solar_altitude(location(), window.interval.end + timedelta(seconds=1)) > -12


def test_grazing_window_between_coarse_samples():
    start = instant("2026-03-20T00:00Z")

    def altitude(at):
        seconds = (at - start).total_seconds()
        return -12 + ((seconds - 1450) / 300) ** 2 - 0.01

    windows = _threshold_intervals(altitude, Interval(start, start + timedelta(hours=1)), -12)
    (window,) = windows
    assert abs((window.interval.start - start).total_seconds() - 1420) < 0.25
    assert abs((window.interval.end - start).total_seconds() - 1480) < 0.25


def test_positive_grazing_gap_splits_darkness():
    start = instant("2026-03-20T00:00Z")
    windows = _threshold_intervals(
        lambda at: -12 - (((at - start).total_seconds() - 1450) / 300) ** 2 + 0.01,
        Interval(start, start + timedelta(hours=1)),
        -12,
    )
    assert len(windows) == 2
    assert windows[0].interval.end < windows[1].interval.start


def test_utc_offsets_longitude_wrap_and_host_timezone():
    at = instant("2026-10-12T12:00Z")
    expected = calculate_windows(location(), at)
    previous = os.environ.get("TZ")
    try:
        for name in ["Pacific/Honolulu", "Asia/Tokyo", "UTC"]:
            os.environ["TZ"] = name
            time.tzset()
            assert (
                calculate_windows(location(), at.astimezone(iana_zone("Europe/Stockholm")))
                == expected
            )
    finally:
        if previous is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = previous
        time.tzset()
    assert solar_altitude(location(60, -180), at) == pytest.approx(
        solar_altitude(location(60, 180), at)
    )


def test_invalid_search_and_naive_timestamp():
    at = instant("2026-10-12T12:00Z")
    with pytest.raises(ValueError):
        calculate_windows(location(), at.replace(tzinfo=None))
    with pytest.raises(ValueError):
        darkness_windows(location(), Interval(at, at + timedelta(days=5)))
    with pytest.raises(ValueError):
        darkness_windows(location(), Interval(at, at + timedelta(days=1)), threshold=float("nan"))


def test_failure_does_not_turn_into_no_darkness(monkeypatch):
    def fail(*args):
        raise ArithmeticError("failed calculation")

    monkeypatch.setattr("aurora_backend.astronomy.windows.solar_altitude", fail)
    with pytest.raises(ArithmeticError):
        calculate_windows(location(), instant("2026-10-12T12:00Z"))
