"""Versioned prototype parameters, never a visibility probability."""

from dataclasses import dataclass
from datetime import timedelta
from math import isfinite


@dataclass(frozen=True)
class Parameters:
    version: str = "visibility-v0.2-bracket-prototype"
    temporal_policy: str = "retained-bracket-min-v1"
    ovation_max_gap: timedelta = timedelta(minutes=20)
    ovation_publication_max_age: timedelta = timedelta(minutes=20)
    darkness_degrees: float = -12.0
    clear_cloud_below: float = 30.0
    obstructed_cloud_above: float = 70.0
    positive_grid_at_least: float = 10.0
    ovation_max_age: timedelta = timedelta(minutes=20)
    weather_max_age: timedelta = timedelta(hours=6)
    kp_max_age: timedelta = timedelta(hours=24)
    max_weather_spacing: timedelta = timedelta(hours=6)
    recheck_after: timedelta = timedelta(minutes=5)

    def __post_init__(self) -> None:
        if not self.version or not all(
            isfinite(v)
            for v in (
                self.darkness_degrees,
                self.clear_cloud_below,
                self.obstructed_cloud_above,
                self.positive_grid_at_least,
            )
        ):
            raise ValueError("Invalid evaluator parameters")
        if not -18 <= self.darkness_degrees <= 0:
            raise ValueError("Invalid darkness threshold")
        if not 0 <= self.clear_cloud_below <= self.obstructed_cloud_above <= 100:
            raise ValueError("Invalid cloud thresholds")
        if not 0 < self.positive_grid_at_least <= 100:
            raise ValueError("Invalid grid threshold")
        if any(
            v <= timedelta(0)
            for v in (
                self.ovation_max_age,
                self.ovation_max_gap,
                self.ovation_publication_max_age,
                self.weather_max_age,
                self.kp_max_age,
                self.max_weather_spacing,
                self.recheck_after,
            )
        ):
            raise ValueError("Durations must be positive")
        if self.temporal_policy not in {"retained-bracket-min-v1", "exact-forecast-instant-v1"}:
            raise ValueError("Unknown temporal policy")


DEFAULT_PARAMETERS = Parameters()
LEGACY_PARAMETERS = Parameters(
    version="visibility-v0.1-prototype", temporal_policy="exact-forecast-instant-v1"
)
