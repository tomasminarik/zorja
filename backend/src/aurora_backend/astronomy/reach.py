"""How far aurora usually reaches a place, from its corrected magnetic latitude.

NOAA's viewing rule: the aurora zone's southern edge sits at about 66° magnetic
latitude at Kp 0 and moves about 2° towards the equator per Kp step. These are
averages for a planning outlook, never a live or validated visibility rating.
"""

import base64
import struct
import zlib
from dataclasses import dataclass
from functools import cache
from math import floor
from typing import Literal

from aurora_backend.astronomy import aacgm_table

METHOD = "aacgm-v2-noaa-oval-v1"
ZONE_EDGE_AT_KP0 = 66.0
DEGREES_PER_KP = 2.0
LOW_IN_NORTH_KP = 2.0  # aurora about 4° poleward stands at least 10° above the horizon
UNDER_ZONE_FROM = 62.0
EDGE_FROM = 55.0

Group = Literal["under_zone", "edge", "south"]


@dataclass(frozen=True)
class AuroraReach:
    group: Group
    magnetic_latitude: float | None  # absolute degrees; None where AACGM is undefined
    kp_overhead: float | None  # may exceed 9: never overhead by this rule
    kp_low_in_north: float | None

    def as_json(self) -> dict[str, object]:
        return {
            "group": self.group,
            "magneticLatitude": self.magnetic_latitude,
            "kpOverhead": self.kp_overhead,
            "kpLowInNorth": self.kp_low_in_north,
            "method": METHOD,
        }


@cache
def _table() -> tuple[int, ...]:
    raw = zlib.decompress(base64.b64decode("".join(aacgm_table.DATA)))
    values = struct.unpack(f"<{len(raw) // 2}h", raw)
    if len(values) != 181 * 360:
        raise ValueError("Magnetic latitude table has the wrong size")
    return values


def magnetic_latitude(latitude: float, longitude: float) -> float | None:
    """Signed corrected magnetic latitude by bilinear lookup, or None if undefined."""
    if not -90 <= latitude <= 90:
        raise ValueError("Latitude out of range")
    table = _table()
    lon = (longitude + 180) % 360 - 180
    west, south = floor(lon), min(floor(latitude), 89)
    x, y = lon - west, latitude - south
    result = 0.0
    for column, wx in ((west, 1 - x), (west + 1, x)):
        for row, wy in ((south, 1 - y), (south + 1, y)):
            weight = wx * wy
            if weight == 0:
                continue
            value = table[(row + 90) * 360 + (column + 180) % 360]
            if value == aacgm_table.UNDEFINED:
                return None
            result += weight * value / 100
    return result


def aurora_reach(latitude: float, longitude: float) -> AuroraReach:
    signed = magnetic_latitude(latitude, longitude)
    if signed is None:
        return AuroraReach("south", None, None, None)
    m = abs(signed)
    overhead = (ZONE_EDGE_AT_KP0 - m) / DEGREES_PER_KP
    group: Group = "under_zone" if m >= UNDER_ZONE_FROM else "edge" if m >= EDGE_FROM else "south"
    return AuroraReach(
        group,
        round(m, 2),
        round(overhead, 2),
        round(overhead - LOW_IN_NORTH_KP, 2),
    )
