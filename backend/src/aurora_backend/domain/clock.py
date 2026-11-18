from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol

from aurora_backend.domain.types import utc


class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)


@dataclass(frozen=True)
class FixedClock:
    instant: datetime

    def __post_init__(self) -> None:
        object.__setattr__(self, "instant", utc(self.instant))

    def now(self) -> datetime:
        return self.instant
