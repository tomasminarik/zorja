"""Bounded local SQLite cache. A process lease prevents duplicate upstream owners."""

import fcntl
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from aurora_backend.domain.types import utc
from aurora_backend.providers.activity import HISTORY_CAPACITY, RETENTION
from aurora_backend.providers.models import Product, ProviderError
from aurora_backend.providers.parsers import MAX_BODY_BYTES, normalize


@dataclass(frozen=True)
class CacheEntry:
    key: str
    body: bytes | None
    fetched_at: datetime | None
    headers: dict[str, str]
    checked_at: datetime | None
    next_refresh_at: datetime
    error: str | None
    failures: int
    deprecated: bool


class SnapshotStore:
    """Latest valid body per key plus bounded OVATION history; failed refreshes retain bodies.

    No user/device storage or production database selection. One owner per cache
    file; later API/worker deployments must coordinate a shared refresh owner.
    """

    def __init__(self, path: Path, weather_capacity: int = 64) -> None:
        if not 1 <= weather_capacity <= 256:
            raise ValueError("Weather capacity must be 1–256")
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lease = path.with_suffix(path.suffix + ".lease").open("a+b")
        try:
            fcntl.flock(self._lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self._lease.close()
            raise ProviderError("cache_already_owned") from error
        self.capacity = weather_capacity
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA journal_mode=DELETE")
        self.db.execute("PRAGMA journal_size_limit=0")
        # Fixed finite upper bound for pages, including overhead and the two global feeds.
        page_size = int(self.db.execute("PRAGMA page_size").fetchone()[0])
        maximum_pages = (weather_capacity + HISTORY_CAPACITY + 4) * 2_100_000 // page_size
        self.db.execute(f"PRAGMA max_page_count={maximum_pages}")
        self.db.execute("""CREATE TABLE IF NOT EXISTS provider_cache (
            key TEXT PRIMARY KEY, body BLOB, fetched_at TEXT, headers TEXT NOT NULL,
            checked_at TEXT, next_refresh_at TEXT NOT NULL, error TEXT,
            failures INTEGER NOT NULL, deprecated INTEGER NOT NULL
        )""")
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS host_cooldown (host TEXT PRIMARY KEY, until TEXT)"
        )
        self.db.execute("""CREATE TABLE IF NOT EXISTS ovation_history (
            forecast_at TEXT PRIMARY KEY, observed_at TEXT NOT NULL, body BLOB NOT NULL,
            fetched_at TEXT NOT NULL, headers TEXT NOT NULL
        )""")
        self.db.commit()
        existing = self.read(Product.OVATION.value)
        if existing and existing.body and existing.fetched_at:
            try:
                self.write(
                    existing
                )  # backfill the prior latest-only cache during additive migration
            except ProviderError:
                pass  # corrupt cached input remains explicit unavailable data at read/normalization

    def close(self) -> None:
        self.db.close()
        self._lease.close()

    def cooldown(self, host: str) -> datetime | None:
        row = self.db.execute("SELECT until FROM host_cooldown WHERE host=?", (host,)).fetchone()
        return datetime.fromisoformat(row[0]) if row else None

    def throttle(self, host: str, until: datetime) -> None:
        if host not in {"api.met.no", "services.swpc.noaa.gov"}:
            raise ProviderError("invalid_provider_host")
        with self.db:
            self.db.execute(
                "INSERT OR REPLACE INTO host_cooldown VALUES (?,?)",
                (
                    host,
                    until.isoformat(),
                ),
            )

    def read(self, key: str) -> CacheEntry | None:
        row = self.db.execute("SELECT * FROM provider_cache WHERE key=?", (key,)).fetchone()
        if row is None:
            return None
        return CacheEntry(
            row[0],
            row[1],
            datetime.fromisoformat(row[2]) if row[2] else None,
            json.loads(row[3]),
            datetime.fromisoformat(row[4]) if row[4] else None,
            datetime.fromisoformat(row[5]),
            row[6],
            row[7],
            bool(row[8]),
        )

    def reserve(self, key: str, now: datetime) -> None:
        if self.read(key) is not None:
            return
        if key.startswith("met:"):
            count = self.db.execute(
                "SELECT COUNT(*) FROM provider_cache WHERE key LIKE 'met:%'"
            ).fetchone()[0]
            if count >= self.capacity:
                raise ProviderError("weather_capacity_exhausted")
        elif key not in {"noaa_ovation", "noaa_three_day"}:
            raise ProviderError("invalid_cache_key")
        self.write(CacheEntry(key, None, None, {}, None, now, None, 0, False))

    def write(self, entry: CacheEntry) -> None:
        if entry.body is not None and len(entry.body) > MAX_BODY_BYTES:
            raise ProviderError("response_too_large")
        with self.db:
            if entry.key == Product.OVATION.value and entry.body and entry.fetched_at:
                # Includes existing latest cache on its next write; no schema reset.
                snapshot = normalize(Product.OVATION, entry.body, entry.fetched_at)
                assert snapshot.forecast_at and snapshot.observed_at
                previous = self.db.execute(
                    "SELECT observed_at, body, fetched_at, headers FROM ovation_history "
                    "WHERE forecast_at=?",
                    (snapshot.forecast_at.isoformat(),),
                ).fetchone()
                if previous is None or snapshot.observed_at >= datetime.fromisoformat(previous[0]):
                    fetched, headers = entry.fetched_at, entry.headers
                    if previous and previous[1] == entry.body:
                        fetched, headers = (
                            datetime.fromisoformat(previous[2]),
                            json.loads(previous[3]),
                        )
                    self.db.execute(
                        "INSERT OR REPLACE INTO ovation_history VALUES (?,?,?,?,?)",
                        (
                            snapshot.forecast_at.isoformat(),
                            snapshot.observed_at.isoformat(),
                            entry.body,
                            fetched.isoformat(),
                            json.dumps(headers),
                        ),
                    )
                self._prune_history(entry.checked_at or entry.fetched_at)
            self.db.execute(
                """INSERT OR REPLACE INTO provider_cache VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    entry.key,
                    entry.body,
                    entry.fetched_at.isoformat() if entry.fetched_at else None,
                    json.dumps(entry.headers),
                    entry.checked_at.isoformat() if entry.checked_at else None,
                    entry.next_refresh_at.isoformat(),
                    entry.error,
                    entry.failures,
                    int(entry.deprecated),
                ),
            )

    def _prune_history(self, now: datetime) -> None:
        self.db.execute(
            "DELETE FROM ovation_history WHERE fetched_at < ?",
            ((now - RETENTION).isoformat(),),
        )
        self.db.execute(
            """DELETE FROM ovation_history WHERE forecast_at NOT IN (
                SELECT forecast_at FROM ovation_history ORDER BY forecast_at DESC LIMIT ?
            )""",
            (HISTORY_CAPACITY,),
        )

    def prune_raw(self, now: datetime) -> None:
        """Retain latest raw bodies for at most 48 hours without clearing refresh backoff.

        The retained-history three-hour bound remains independent. Reserved keys
        still consume capacity; removal cannot create a provider-request loophole.
        """
        with self.db:
            self.db.execute(
                "UPDATE provider_cache SET body=NULL WHERE fetched_at <= ?",
                ((utc(now) - timedelta(hours=48)).isoformat(),),
            )
            self._prune_history(utc(now))

    def history(self, now: datetime) -> tuple[tuple[bytes, datetime, dict[str, str]], ...]:
        """Load only the nearest received targets around now, not 192 full grids.

        All runs remain on disk for three hours; foreground CPU and memory remain
        bounded by two endpoint grids plus the separately returned latest run.
        """
        now = utc(now)
        with self.db:
            self._prune_history(now)
        return tuple(
            (body, datetime.fromisoformat(fetched), json.loads(headers))
            for body, fetched, headers in self.db.execute(
                """SELECT body, fetched_at, headers FROM ovation_history WHERE forecast_at IN (
                    SELECT forecast_at FROM ovation_history
                    WHERE forecast_at <= ? AND fetched_at <= ?
                    ORDER BY forecast_at DESC LIMIT 1
                ) OR forecast_at IN (
                    SELECT forecast_at FROM ovation_history
                    WHERE forecast_at > ? AND fetched_at <= ?
                    ORDER BY forecast_at LIMIT 1
                ) ORDER BY forecast_at""",
                (now.isoformat(),) * 4,
            )
        )
