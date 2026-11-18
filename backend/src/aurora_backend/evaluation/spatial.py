"""One-degree interpolation; horizon experiments never drive guidance."""

from math import acos, atan2, cos, degrees, floor, radians, sin

from aurora_backend.domain.types import Location
from aurora_backend.providers.models import GridPoint, Snapshot


def local_signal(snapshot: Snapshot, location: Location, *, nearest: bool = False) -> float | None:
    grid = {(p.longitude, p.latitude): p.value for p in snapshot.grid}
    lon = (location.longitude + 180) % 360 - 180
    lat = location.latitude
    if nearest:
        return grid.get((int((floor(lon + 0.5) + 180) % 360 - 180), min(90, floor(lat + 0.5))))
    west, south = floor(lon), floor(lat)
    x, y = lon - west, lat - south
    result = 0.0
    for longitude, wx in ((west, 1 - x), (west + 1, x)):
        for latitude, wy in ((south, 1 - y), (south + 1, y)):
            weight = wx * wy
            if weight == 0:
                continue
            value = grid.get((int((longitude + 180) % 360 - 180), latitude))
            if value is None:
                return None
            result += weight * value
    return result


def horizon_candidate(
    snapshot: Snapshot,
    location: Location,
    *,
    emission_height_km: float = 110.0,
    minimum_elevation_degrees: float = 10.0,
) -> GridPoint | None:
    """Spherical geometry sensitivity experiment, not supported local activity."""
    if not 0 < emission_height_km <= 1000 or not 0 <= minimum_elevation_degrees <= 90:
        raise ValueError("Invalid horizon geometry")
    radius, shell = 6371.0, 6371.0 + emission_height_km
    lat = radians(location.latitude)
    strongest = None
    for point in snapshot.grid:
        plat = radians(point.latitude)
        cosine = sin(lat) * sin(plat) + cos(lat) * cos(plat) * cos(
            radians(point.longitude - location.longitude)
        )
        angle = acos(max(-1.0, min(1.0, cosine)))
        elevation = degrees(atan2(shell * cos(angle) - radius, shell * sin(angle)))
        if elevation < minimum_elevation_degrees:
            continue
        if strongest is None or point.value > strongest.value:
            strongest = point
    return strongest
