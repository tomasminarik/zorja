"""Group supplied qualifying darkness intervals; this does not calculate the Sun."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from aurora_backend.domain.timezones import iana_zone
from aurora_backend.domain.types import Interval, utc


@dataclass(frozen=True)
class PlanningPeriod:
    local_date: date
    interval: Interval


def planning_periods(
    evaluated_at: datetime,
    timezone: str,
    darkness: Sequence[Interval],
    *,
    darkness_coverage: Interval,
) -> tuple[PlanningPeriod, ...]:
    """Return three noon-to-noon periods with complete pre-noon darkness knowledge.

    Empty intervals mean no darkness only within explicit calculated coverage.
    Missing coverage is an error, not a midnight-sun/no-window inference.
    """
    instant = utc(evaluated_at)
    zone = iana_zone(timezone)
    local = instant.astimezone(zone)
    first = local.date()
    if local.time() < time(12):
        noon = utc(datetime.combine(first, time(12), zone))
        if darkness_coverage.start > instant or darkness_coverage.end < noon:
            raise ValueError("Darkness coverage must reach the next local noon")
        if any(window.start < noon and window.end > instant for window in darkness):
            first -= timedelta(days=1)
    result = []
    for offset in range(3):
        label = first + timedelta(days=offset)
        start = datetime.combine(label, time(12), zone)
        end = datetime.combine(label + timedelta(days=1), time(12), zone)
        result.append(PlanningPeriod(label, Interval(start, end)))
    return tuple(result)
