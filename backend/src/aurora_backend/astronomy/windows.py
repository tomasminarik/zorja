"""Bounded threshold crossings and local-night windows, independent of providers."""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from math import isfinite
from typing import Literal

from aurora_backend.astronomy.periods import PlanningPeriod, planning_periods
from aurora_backend.astronomy.solar import DarknessCategory, classify_altitude, solar_altitude
from aurora_backend.domain.types import Interval, Location, utc

MODEL_VERSION = "solar-v1-astral-3.2"
VIEWING_THRESHOLD = -12.0
SAMPLE_STEP = timedelta(minutes=10)
BOUNDARY_TOLERANCE = timedelta(milliseconds=250)
MAX_SEARCH = timedelta(days=4)


@dataclass(frozen=True)
class DarknessWindow:
    interval: Interval
    start_is_clipped: bool
    end_is_search_limited: bool


@dataclass(frozen=True)
class NightWindows:
    period: PlanningPeriod
    windows: tuple[DarknessWindow, ...]

    @property
    def darkness_status(self) -> Literal["windows_available", "no_darkness"]:
        return "windows_available" if self.windows else "no_darkness"


@dataclass(frozen=True)
class SolarWindows:
    evaluated_at: datetime
    altitude_degrees: float
    category: DarknessCategory
    coverage: Interval
    upcoming: DarknessWindow | None
    upcoming_detail: DarknessWindow | None
    planning: tuple[NightWindows, ...]
    model_version: str = MODEL_VERSION

    @property
    def upcoming_status(self) -> Literal["window_available", "no_darkness_within_horizon"]:
        return "window_available" if self.upcoming else "no_darkness_within_horizon"


def _extremum(
    value: Callable[[datetime], float], left: datetime, right: datetime, sign: int
) -> datetime:
    # Ternary refinement of a bracketed smooth daily maximum/minimum. Adding
    # extrema catches grazing windows shorter than the coarse sampling step.
    while right - left > BOUNDARY_TOLERANCE:
        third = (right - left) / 3
        a, b = left + third, right - third
        if sign * value(a) < sign * value(b):
            right = b
        else:
            left = a
    return left + (right - left) / 2


def _crossing(value: Callable[[datetime], float], left: datetime, right: datetime) -> datetime:
    left_dark = value(left) <= 0
    while right - left > BOUNDARY_TOLERANCE:
        middle = left + (right - left) / 2
        if (value(middle) <= 0) == left_dark:
            left = middle
        else:
            right = middle
    return left + (right - left) / 2


def _threshold_intervals(
    altitude: Callable[[datetime], float], coverage: Interval, threshold: float
) -> tuple[DarknessWindow, ...]:
    def value(at: datetime) -> float:
        result = altitude(at) - threshold
        if not isfinite(result):
            raise ValueError("Solar calculation returned a nonfinite value")
        return result

    times = [coverage.start]
    while times[-1] < coverage.end:
        times.append(min(times[-1] + SAMPLE_STEP, coverage.end))
    values = [value(at) for at in times]
    extra = []
    for index in range(1, len(times) - 1):
        before, current, after = values[index - 1 : index + 2]
        if current < before and current <= after:
            extra.append(_extremum(value, times[index - 1], times[index + 1], 1))
        elif current > before and current >= after:
            extra.append(_extremum(value, times[index - 1], times[index + 1], -1))
    # Search-edge extrema can lie between the first two/last two samples.
    # Include min and max there, even without a sampled three-point bracket.
    for left, right in [(times[0], times[1]), (times[-2], times[-1])]:
        extra.extend(_extremum(value, left, right, sign) for sign in (1, -1))
    times = sorted(set(times + extra))
    crossings = [
        _crossing(value, left, right)
        for left, right in zip(times, times[1:], strict=False)
        if (value(left) <= 0) != (value(right) <= 0)
    ]
    boundaries = [coverage.start, *crossings, coverage.end]
    result = []
    for left, right in zip(boundaries, boundaries[1:], strict=False):
        if left < right and value(left + (right - left) / 2) <= 0:
            result.append(
                DarknessWindow(Interval(left, right), left == coverage.start, right == coverage.end)
            )
    return tuple(result)


def darkness_windows(
    location: Location, coverage: Interval, *, threshold: float = VIEWING_THRESHOLD
) -> tuple[DarknessWindow, ...]:
    if coverage.end - coverage.start > MAX_SEARCH:
        raise ValueError("Solar search must not exceed four days")
    if not isfinite(threshold) or not -18 <= threshold <= 0:
        raise ValueError("Threshold must be finite and within [-18, 0]")
    return _threshold_intervals(lambda at: solar_altitude(location, at), coverage, threshold)


def _clip(window: DarknessWindow, interval: Interval) -> DarknessWindow | None:
    start = max(window.interval.start, interval.start)
    end = min(window.interval.end, interval.end)
    if start >= end:
        return None
    return DarknessWindow(
        Interval(start, end),
        window.start_is_clipped or start > window.interval.start,
        window.end_is_search_limited or end < window.interval.end,
    )


def calculate_windows(location: Location, evaluated_at: datetime) -> SolarWindows:
    at = utc(evaluated_at)
    # Three local noon periods can end after the 72h upcoming search. Calculate
    # four UTC days to cover those calendar boundaries, including DST changes.
    coverage = Interval(at, at + MAX_SEARCH)
    windows = darkness_windows(location, coverage)
    periods = planning_periods(
        at, location.timezone, [w.interval for w in windows], darkness_coverage=coverage
    )
    planning = tuple(
        NightWindows(
            period,
            tuple(clipped for w in windows if (clipped := _clip(w, period.interval)) is not None),
        )
        for period in periods
    )
    search = Interval(at, at + timedelta(hours=72))
    upcoming = next((clipped for w in windows if (clipped := _clip(w, search)) is not None), None)
    detail = None
    if upcoming:
        detail = _clip(
            upcoming,
            Interval(upcoming.interval.start, upcoming.interval.start + timedelta(hours=24)),
        )
    altitude = solar_altitude(location, at)
    return SolarWindows(
        at, altitude, classify_altitude(altitude), coverage, upcoming, detail, planning
    )
