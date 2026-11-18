from dataclasses import dataclass
from enum import StrEnum


class ErrorCode(StrEnum):
    INVALID_REQUEST = "invalid_request"
    FORECAST_UNAVAILABLE = "forecast_unavailable"


@dataclass(frozen=True)
class DomainError(Exception):
    code: ErrorCode
    message: str
