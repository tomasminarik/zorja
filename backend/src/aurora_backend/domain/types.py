from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator

from aurora_backend.domain.timezones import iana_zone


def utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("An aware timestamp is required")
    return value.astimezone(UTC)


Latitude = Annotated[float, Field(ge=-90, le=90, allow_inf_nan=False, strict=True)]
Longitude = Annotated[float, Field(ge=-180, le=180, allow_inf_nan=False, strict=True)]
SolarAltitudeDegrees = Annotated[float, Field(ge=-90, le=90, allow_inf_nan=False, strict=True)]
CloudCoverPercent = Annotated[float, Field(ge=0, le=100, allow_inf_nan=False, strict=True)]


class Location(BaseModel):
    model_config = ConfigDict(extra="forbid")
    latitude: Latitude
    longitude: Longitude
    timezone: str

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            iana_zone(value)
        except ValueError as error:
            raise ValueError("A valid IANA timezone is required") from error
        return value


@dataclass(frozen=True)
class Interval:
    start: datetime
    end: datetime

    def __post_init__(self) -> None:
        object.__setattr__(self, "start", utc(self.start))
        object.__setattr__(self, "end", utc(self.end))
        if self.start >= self.end:
            raise ValueError("Interval end must follow start")

    def contains(self, value: datetime) -> bool:
        return self.start <= utc(value) < self.end
