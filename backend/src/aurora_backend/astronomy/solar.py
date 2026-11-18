"""Offline, airless solar geometry. No viewing or auroral assessment is implied."""

from datetime import datetime, timedelta
from math import acos, cos, degrees, isfinite, radians, sin
from typing import Literal

from astral import Observer
from astral.julian import julianday, julianday_to_juliancentury
from astral.sun import elevation, eq_of_time, sun_declination

from aurora_backend.domain.types import Location, utc

DarknessCategory = Literal[
    "daylight", "civil_twilight", "nautical_twilight", "astronomical_twilight", "astronomical_night"
]


def classify_altitude(altitude: float) -> DarknessCategory:
    if not isfinite(altitude) or not -90 <= altitude <= 90:
        raise ValueError("Solar altitude must be finite and within [-90, 90]")
    if altitude >= 0:
        return "daylight"
    if altitude > -6:
        return "civil_twilight"
    if altitude > -12:
        return "nautical_twilight"
    if altitude > -18:
        return "astronomical_twilight"
    return "astronomical_night"


def _whole_second_altitude(location: Location, at: datetime) -> float:
    if abs(location.latitude) <= 89.8:
        return float(elevation(Observer(location.latitude, location.longitude), at, False))
    # Astral 3.2 clamps latitude to +/-89.8. Apply its spherical zenith equation
    # at the actual latitude instead; the solar terms still come from Astral.
    century = julianday_to_juliancentury(julianday(at))
    declination = radians(sun_declination(century))
    latitude = radians(location.latitude)
    minutes = at.hour * 60 + at.minute + at.second / 60
    angle = radians((minutes + eq_of_time(century) + 4 * location.longitude) / 4 - 180)
    cosine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(angle)
    return 90 - degrees(acos(max(-1.0, min(1.0, cosine))))


def solar_altitude(location: Location, evaluated_at: datetime) -> float:
    """Sun centre above geometric horizon at sea level; no terrain/refraction.

    Astral drops fractional seconds. Interpolate adjacent whole-second values
    so boundary refinement is continuous; never pass host-local/naive time.
    """
    at = utc(evaluated_at)
    floor = at.replace(microsecond=0)
    altitude = _whole_second_altitude(location, floor)
    if not at.microsecond:
        return altitude
    following = _whole_second_altitude(location, floor + timedelta(seconds=1))
    return altitude + (following - altitude) * at.microsecond / 1_000_000
