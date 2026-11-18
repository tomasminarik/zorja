"""Collector cadence: every 10 minutes around darkness, otherwise every 30."""

from datetime import UTC, datetime, timedelta

from aurora_backend.astronomy.solar import solar_altitude
from aurora_backend.astronomy.windows import VIEWING_THRESHOLD
from aurora_backend.collection.cadence import (
    LEAD,
    REFERENCE_POINTS,
    collection_due,
    dark_soon,
    slot,
)


def at(text):
    return datetime.fromisoformat(text).replace(tzinfo=UTC)


def test_slots_are_ten_minutes_and_every_third_one_is_due_in_daylight():
    start = at("2026-06-21T14:00:00")  # all reference points light until well after 15:30
    assert not dark_soon(start)
    due = [collection_due(start + timedelta(minutes=10 * step)) for step in range(6)]
    assert due == [True, False, False, True, False, False]
    assert slot(start + timedelta(minutes=9, seconds=59)) == slot(start)
    assert slot(start + timedelta(minutes=10)) == slot(start) + 1


def test_winter_is_dark_somewhere_around_the_clock():
    start = at("2026-12-21T00:00:00")
    assert all(dark_soon(start + timedelta(minutes=10 * step)) for step in range(144))


def test_due_starts_a_full_lead_before_darkness():
    # Find the first moment on 2026-06-21 after midday when any point is dark enough.
    moment = at("2026-06-21T12:00:00")
    while not any(solar_altitude(p, moment) <= VIEWING_THRESHOLD for p in REFERENCE_POINTS):
        moment += timedelta(minutes=1)
    assert dark_soon(moment - LEAD + timedelta(minutes=10))
    assert not dark_soon(moment - LEAD - timedelta(minutes=20))
    assert dark_soon(moment)


def test_every_launch_region_has_reference_points_and_they_are_valid():
    assert len(REFERENCE_POINTS) >= 20
    assert min(p.longitude for p in REFERENCE_POINTS) < -130  # western Canada
    assert max(p.longitude for p in REFERENCE_POINTS) > 30  # eastern Finland and Norway
    assert min(p.latitude for p in REFERENCE_POINTS) < 45  # southern Canada
