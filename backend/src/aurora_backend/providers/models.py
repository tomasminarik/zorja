"""Internal provider contracts; no local viewing assessment is made here."""

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum


class Product(StrEnum):
    OVATION = "noaa_ovation"
    KP = "noaa_three_day"
    WEATHER = "met_locationforecast"


class SourceState(StrEnum):
    FRESH = "fresh"
    STALE = "stale"
    UNAVAILABLE = "unavailable"


class ProviderError(ValueError):
    """Safe stable code, deliberately excluding payloads and coordinates."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class GridPoint:
    longitude: int  # [-180, 179], one-degree spacing
    latitude: int
    value: float  # provider auroral signal, NOT app visibility probability


@dataclass(frozen=True)
class KpBin:
    start: datetime
    end: datetime
    kp: float


@dataclass(frozen=True)
class WeatherSample:
    time: datetime
    total_cloud: float | None
    low_cloud: float | None
    medium_cloud: float | None
    high_cloud: float | None
    fog: float | None
    next_sample_after: timedelta | None


@dataclass(frozen=True)
class Snapshot:
    id: str  # product + canonical key + raw-byte digest; stable across 304/refetch
    product: Product
    provider: str
    issued_at: datetime | None
    observed_at: datetime | None
    forecast_at: datetime | None
    fetched_at: datetime  # original successful body receipt; 304 does not rewrite it
    valid_from: datetime
    valid_until: datetime  # envelope only; weather samples are instants
    units: tuple[tuple[str, str], ...]
    coordinates: tuple[float, float] | None  # requested lon,lat for weather
    grid: tuple[GridPoint, ...] = ()
    kp: tuple[KpBin, ...] = ()
    weather: tuple[WeatherSample, ...] = ()
    validation_status: str = "validated"
    fallback_mode: str = "unknown"  # OVATION JSON exposes no driving-input flag
    cache_headers: tuple[tuple[str, str], ...] = ()

    def covers(self, instant: datetime) -> bool:
        # No implicit interpolation/tolerance for model instants.
        if self.product == Product.OVATION:
            return instant == self.forecast_at
        if self.product == Product.WEATHER:
            return any(sample.time == instant for sample in self.weather)
        return any(item.start <= instant < item.end for item in self.kp)


@dataclass(frozen=True)
class SourceHealth:
    state: SourceState
    refresh_error: str | None
    deprecated: bool
    checked_at: datetime | None
    next_refresh_at: datetime
    cache_expires_at: datetime | None


@dataclass(frozen=True)
class ProviderResult:
    snapshot: Snapshot | None
    health: SourceHealth
    retained: tuple[
        Snapshot, ...
    ] = ()  # OVATION runs only; newest stream health applies to history
