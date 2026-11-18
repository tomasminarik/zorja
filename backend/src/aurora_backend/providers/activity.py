"""OVATION operational freshness, separate from forecast matching and HTTP TTL."""

from datetime import datetime, timedelta
from email.utils import parsedate_to_datetime

from aurora_backend.domain.types import utc
from aurora_backend.providers.models import Snapshot

RETENTION = timedelta(hours=3)
HISTORY_CAPACITY = 192
PUBLICATION_MAX_AGE = timedelta(minutes=20)
TARGET_MAX_AGE = timedelta(minutes=20)


def publication_origin(snapshot: Snapshot) -> datetime:
    """Use Last-Modified, bounded by first receipt; refetch/304 cannot revive a run.

    First receipt is the fallback when publication metadata is absent/invalid.
    It is operational evidence of receipt, not a rewritten observation timestamp.
    """
    fetched = utc(snapshot.fetched_at)
    modified = dict(snapshot.cache_headers).get("last-modified")
    if modified:
        try:
            value = utc(parsedate_to_datetime(modified))
            if value <= fetched and (snapshot.observed_at is None or value >= snapshot.observed_at):
                return value
        except (ValueError, TypeError, OverflowError):
            pass
    return fetched


def stream_deadline(
    snapshots: tuple[Snapshot, ...],
    publication_max_age: timedelta = PUBLICATION_MAX_AGE,
    target_max_age: timedelta = TARGET_MAX_AGE,
) -> datetime:
    """Both continued publication and newest forecast target bound usable history."""
    return min(
        max(publication_origin(s) for s in snapshots) + publication_max_age,
        max(s.forecast_at for s in snapshots if s.forecast_at is not None) + target_max_age,
    )
