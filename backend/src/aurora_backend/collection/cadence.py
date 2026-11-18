"""When a collector call does real work: every 10 minutes around darkness, else every 30.

The schedule calls the collector every 10 minutes. A call is "due" when it is dark,
or will be within LEAD, at any reference point in the launch regions; otherwise
only every third slot (:00 and :30) is due. A call that is not due touches neither
Redis nor NOAA.

LEAD is 90 minutes because each NOAA file forecasts about 60 minutes ahead. Current
activity needs two received runs whose targets are at most 20 minutes apart and
bracket "now", so the files that describe the start of darkness are fetched about
an hour before it. 90 minutes covers that hour, the 20-minute bracket and a margin.
This is an operational cadence, not a scientific validity interval.
"""

from datetime import datetime, timedelta

from aurora_backend.astronomy.solar import solar_altitude
from aurora_backend.astronomy.windows import VIEWING_THRESHOLD
from aurora_backend.domain.types import Location, utc

SLOT = timedelta(minutes=10)
LIGHT_SLOTS = 3  # every 30 minutes outside darkness
LEAD = timedelta(minutes=90)
STEP = timedelta(minutes=10)

# Corners and extremes of the launch regions: the northernmost, southernmost,
# easternmost and westernmost places decide when darkness starts or ends somewhere.
REFERENCE_POINTS = tuple(
    Location(latitude=lat, longitude=lon, timezone="UTC")
    for lat, lon in (
        # Canada
        (42.3, -83.0),  # Windsor
        (49.3, -123.1),  # Vancouver
        (60.7, -135.1),  # Whitehorse
        (68.4, -133.7),  # Inuvik
        (62.5, -114.4),  # Yellowknife
        (63.7, -68.5),  # Iqaluit
        (82.5, -62.3),  # Alert
        (44.6, -63.6),  # Halifax
        (47.6, -52.7),  # St. John's
        # Iceland, Faroe Islands, Scotland
        (64.1, -21.9),  # Reykjavík
        (62.0, -6.8),  # Tórshavn
        (60.2, -1.1),  # Lerwick
        (55.1, -3.6),  # Dumfries
        # Norway, Sweden, Finland, Denmark, Poland
        (58.1, 8.0),  # Kristiansand
        (70.4, 31.1),  # Vardø
        (78.2, 15.6),  # Longyearbyen
        (55.6, 13.0),  # Malmö
        (67.9, 20.2),  # Kiruna
        (60.2, 24.9),  # Helsinki
        (69.9, 27.0),  # Utsjoki
        (62.7, 31.0),  # Ilomantsi
        (55.1, 15.1),  # Bornholm
        (49.8, 22.8),  # Przemyśl
        (53.4, 14.6),  # Szczecin
    )
)


def slot(now: datetime) -> int:
    return int(utc(now).timestamp() // SLOT.total_seconds())


def dark_soon(now: datetime) -> bool:
    """Dark enough for viewing now or within LEAD at any reference point.

    Sampled every 10 minutes; a darkness shorter than that can be missed, which
    only affects a few nights around midsummer at the edge of the regions.
    """
    now = utc(now)
    steps = int(LEAD / STEP)
    return any(
        solar_altitude(point, now + STEP * step) <= VIEWING_THRESHOLD
        for step in range(steps + 1)
        for point in REFERENCE_POINTS
    )


def collection_due(now: datetime) -> bool:
    return slot(now) % LIGHT_SLOTS == 0 or dark_soon(now)
