"""Async provider-storage boundary; SQLite keeps its existing synchronous public API."""

from dataclasses import dataclass, replace
from datetime import datetime
from typing import Protocol

from aurora_backend.providers.store import CacheEntry, SnapshotStore

History = tuple[tuple[bytes, datetime, dict[str, str]], ...]


@dataclass(frozen=True)
class PreparedRefresh:
    entry: CacheEntry
    owner: str | None
    # OVATION history read in the same atomic step, when the store supports it.
    history: History | None = None


def reusable(entry: CacheEntry, since: datetime | None) -> bool:
    """A body checked without error after `since` needs no refresh yet."""
    return (
        since is not None
        and entry.body is not None
        and entry.error is None
        and entry.checked_at is not None
        and entry.checked_at > since
    )


class ProviderStore(Protocol):
    async def prepare(
        self,
        key: str,
        host: str,
        now: datetime,
        *,
        with_history: bool = False,
        reuse_since: datetime | None = None,
    ) -> PreparedRefresh: ...
    async def reserve(self, key: str, now: datetime) -> None: ...
    async def read(self, key: str) -> CacheEntry | None: ...
    async def write(self, entry: CacheEntry, owner: str) -> None: ...
    async def prune_raw(self, now: datetime) -> None: ...
    async def history(self, now: datetime) -> History: ...
    async def cooldown(self, host: str) -> datetime | None: ...
    async def throttle(self, host: str, until: datetime) -> None: ...
    async def acquire(self, key: str) -> str | None: ...
    async def release(self, key: str, owner: str) -> None: ...
    async def acquire_host(self, host: str, spacing: float) -> str | None: ...
    async def release_host(self, host: str, owner: str, spacing: float) -> None: ...


class SQLiteProviderStore:
    """One process owns the file; ProviderClient already serializes local requests."""

    def __init__(self, store: SnapshotStore) -> None:
        self.store = store

    async def prepare(
        self,
        key: str,
        host: str,
        now: datetime,
        *,
        with_history: bool = False,
        reuse_since: datetime | None = None,
    ) -> PreparedRefresh:
        # Local reads are cheap; the client reads history separately.
        await self.reserve(key, now)
        entry = await self.read(key)
        assert entry is not None
        cooldown = await self.cooldown(host)
        if cooldown is not None and now < cooldown:
            return PreparedRefresh(
                replace(
                    entry,
                    error="provider_throttled",
                    next_refresh_at=max(entry.next_refresh_at, cooldown),
                ),
                None,
            )
        if now < entry.next_refresh_at or reusable(entry, reuse_since):
            return PreparedRefresh(entry, None)
        owner = await self.acquire(key)
        if owner is None:
            return PreparedRefresh(replace(entry, error="refresh_in_progress"), None)
        latest = await self.read(key)
        assert latest is not None
        return PreparedRefresh(latest, owner)

    async def reserve(self, key: str, now: datetime) -> None:
        self.store.reserve(key, now)

    async def read(self, key: str) -> CacheEntry | None:
        return self.store.read(key)

    async def write(self, entry: CacheEntry, owner: str) -> None:
        self.store.write(entry)

    async def prune_raw(self, now: datetime) -> None:
        self.store.prune_raw(now)

    async def history(self, now: datetime) -> History:
        return self.store.history(now)

    async def cooldown(self, host: str) -> datetime | None:
        return self.store.cooldown(host)

    async def throttle(self, host: str, until: datetime) -> None:
        self.store.throttle(host, until)

    async def acquire(self, key: str) -> str | None:
        return "local"

    async def release(self, key: str, owner: str) -> None:
        pass

    async def acquire_host(self, host: str, spacing: float) -> str | None:
        return "local"

    async def release_host(self, host: str, owner: str, spacing: float) -> None:
        pass
