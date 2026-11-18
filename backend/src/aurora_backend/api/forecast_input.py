"""Bounded forecast JSON input; errors never echo location data."""

import asyncio
import json
from typing import Any

from fastapi import Request
from pydantic import ValidationError

from aurora_backend.domain.errors import DomainError, ErrorCode
from aurora_backend.domain.types import Location

MAX_BODY = 1024


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate property")
        result[key] = value
    return result


async def forecast_location(request: Request) -> Location:
    try:
        if request.query_params or len(request.headers.getlist("content-type")) != 1:
            raise ValueError("JSON without query parameters required")
        if request.headers["content-type"].split(";")[0].strip().lower() != "application/json":
            raise ValueError("JSON required")
        if request.headers.get("content-encoding", "identity").lower() != "identity":
            raise ValueError("Encoded bodies are unsupported")
        body = bytearray()
        async with asyncio.timeout(3):
            async for part in request.stream():
                if len(body) + len(part) > MAX_BODY:
                    raise ValueError("Body too large")
                body.extend(part)
        value = json.loads(body.decode("utf-8"), object_pairs_hook=unique_object)
        return Location.model_validate(value, strict=True)
    except (ValueError, ValidationError, TimeoutError, RecursionError):
        raise DomainError(
            ErrorCode.INVALID_REQUEST, "A valid forecast JSON body is required"
        ) from None
