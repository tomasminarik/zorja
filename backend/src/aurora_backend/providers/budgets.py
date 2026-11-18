"""Monthly allowances for the hosted Redis store (docs/hosting.md).

Upstash Free allows 500K commands and 10 GB of bandwidth a month. These limits
stay below both; the rest is margin for commands that are sent but not charged
(an instance stopped before charging its last forecast, refused requests).

The collector runs at most every 10 minutes: 4,464 runs in a 31-day month at about
17 commands and 12 KB each (test_steady_collection_every_ten_minutes_profile), so
about 76,000 commands and 51 MB. Forecasts get the rest; with the compact grid
they are limited by commands, not bytes.
"""

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class SharedLimits:
    forecast_commands: int = 360_000
    forecast_bytes: int = 8_000_000_000
    collector_commands: int = 90_000
    collector_bytes: int = 500_000_000
    forecasts_per_minute: int = 60

    def __post_init__(self) -> None:
        maxima = SharedLimits.__dataclass_fields__
        for name, value in asdict(self).items():
            ceiling = maxima[name].default
            if not isinstance(ceiling, int) or type(value) is not int or not 1 <= value <= ceiling:
                raise ValueError("Limits must be positive integers no greater than safe defaults")
