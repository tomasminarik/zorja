"""Strict normalization of captured provider formats, with bounded inputs."""

import hashlib
import json
import math
import re
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from typing import Any

from aurora_backend.domain.types import utc
from aurora_backend.providers.models import (
    GridPoint,
    KpBin,
    Product,
    ProviderError,
    Snapshot,
    WeatherSample,
)

MAX_BODY_BYTES = 2_000_000
FUTURE_SKEW = timedelta(minutes=5)


def timestamp(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ProviderError("invalid_timestamp")
    try:
        # NOAA older fixtures used a space and omitted Z; its documented times are UTC.
        if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", value):
            return datetime.strptime(value, "%Y-%m-%d %H:%M:%S").replace(tzinfo=UTC)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", value):
            raise ValueError
        return utc(datetime.fromisoformat(value))
    except ValueError as error:
        raise ProviderError("invalid_timestamp") from error


def number(value: Any, low: float, high: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ProviderError("invalid_number")
    if not math.isfinite(value) or not low <= value <= high:
        raise ProviderError("invalid_number")
    return float(value)


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProviderError("duplicate_json_key")
        result[key] = value
    return result


def _json(body: bytes) -> dict[str, Any]:
    try:
        value = json.loads(body, object_pairs_hook=_pairs)
        if not isinstance(value, dict):
            raise ProviderError("invalid_shape")
        return value
    except (ValueError, UnicodeError, RecursionError) as error:
        if isinstance(error, ProviderError):
            raise
        raise ProviderError("malformed_json") from error


def normalize(
    product: Product,
    body: bytes,
    fetched_at: datetime,
    coordinates: tuple[float, float] | None = None,
) -> Snapshot:
    """Validate and parse a provider body.

    Snapshots are immutable and depend only on these inputs, so the last few are
    remembered: the provider client and the cache write both validate a new grid,
    and a full grid takes about 70 ms to parse. Failures are never remembered.
    """
    return _normalize(product, body, utc(fetched_at), coordinates)


@lru_cache(maxsize=4)
def _normalize(
    product: Product,
    body: bytes,
    fetched_at: datetime,
    coordinates: tuple[float, float] | None,
) -> Snapshot:
    if len(body) > MAX_BODY_BYTES:
        raise ProviderError("response_too_large")
    key = "global" if coordinates is None else f"{coordinates[0]:.4f},{coordinates[1]:.4f}"
    identity = hashlib.sha256(product.value.encode() + key.encode() + body).hexdigest()
    try:
        if product == Product.OVATION:
            return _ovation(_json(body), identity, fetched_at)
        if product == Product.KP:
            return _kp(body.decode("utf-8"), identity, fetched_at)
        if coordinates is None:
            raise ProviderError("coordinates_required")
        return _weather(_json(body), identity, fetched_at, coordinates)
    except (KeyError, TypeError, IndexError, OverflowError, UnicodeError) as error:
        raise ProviderError("invalid_shape") from error


def _ovation(data: dict[str, Any], identity: str, fetched: datetime) -> Snapshot:
    if data["Data Format"] != "[Longitude, Latitude, Aurora]":
        raise ProviderError("unsupported_grid_format")
    observed = timestamp(data["Observation Time"])
    forecast = timestamp(data["Forecast Time"])
    if observed > fetched + FUTURE_SKEW:
        raise ProviderError("future_issue")
    if forecast < observed or forecast - observed > timedelta(hours=2):
        raise ProviderError("invalid_forecast_time")
    rows = data["coordinates"]
    if not isinstance(rows, list) or len(rows) != 360 * 181:
        raise ProviderError("incomplete_grid")
    points = []
    seen: set[tuple[int, int]] = set()
    for row in rows:
        if not isinstance(row, list) or len(row) != 3:
            raise ProviderError("invalid_grid_row")
        lon, lat = number(row[0], 0, 359), number(row[1], -90, 90)
        if not lon.is_integer() or not lat.is_integer():
            raise ProviderError("unsupported_grid_spacing")
        pair = int(lon), int(lat)
        if pair in seen:
            raise ProviderError("duplicate_grid_point")
        seen.add(pair)
        points.append(GridPoint(int((lon + 180) % 360 - 180), int(lat), number(row[2], 0, 100)))
    points.sort(key=lambda item: (item.longitude, item.latitude))
    return Snapshot(
        identity,
        Product.OVATION,
        "NOAA SWPC",
        None,
        observed,
        forecast,
        fetched,
        forecast,
        forecast,
        (("aurora", "provider_0_100"),),
        None,
        grid=tuple(points),
    )


MONTHS = {
    name: index
    for index, name in enumerate(
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1
    )
}


def _kp(text: str, identity: str, fetched: datetime) -> Snapshot:
    issues = re.findall(r"(?m)^:?Issued:\s*(\d{4}) (\w{3}) (\d{1,2}) (\d{4}) UTC\s*$", text)
    if not issues or len(set(issues)) != 1:
        raise ProviderError("missing_or_conflicting_issue")
    year, month, day, hm = issues[0]
    try:
        issued = datetime(int(year), MONTHS[month], int(day), int(hm[:2]), int(hm[2:]), tzinfo=UTC)
    except ValueError as error:
        raise ProviderError("invalid_timestamp") from error
    if issued > fetched + FUTURE_SKEW:
        raise ProviderError("future_issue")
    sections = re.split(r"(?m)^NOAA Kp index breakdown[^\n]*\n", text)[1:]
    if not sections:
        raise ProviderError("missing_kp_table")
    tables: list[tuple[KpBin, ...]] = []
    narratives = []
    for section in sections:
        lines = section.splitlines()
        header_index = next((i for i, line in enumerate(lines) if line.strip()), -1)
        if header_index < 0:
            raise ProviderError("missing_kp_header")
        header = lines[header_index]
        dates = re.findall(r"([A-Z][a-z]{2})\s+(\d{1,2})", header)
        if len(dates) != 3 or re.sub(r"([A-Z][a-z]{2})\s+(\d{1,2})", "", header).strip():
            raise ProviderError("invalid_kp_header")
        days = []
        for offset, (mon, dom) in enumerate(dates):
            target = issued.replace(hour=0, minute=0) + timedelta(days=offset)
            if mon not in MONTHS or target.month != MONTHS[mon] or target.day != int(dom):
                raise ProviderError("conflicting_kp_dates")
            days.append(target)
        bins = []
        for index in range(8):
            line = lines[header_index + 1 + index].strip()
            label = f"{index * 3:02}-{((index + 1) * 3) % 24:02}UT"
            if not line.startswith(label):
                raise ProviderError("missing_or_unordered_kp_bin")
            cleaned = re.sub(r"\s*\(G[1-5]\)", "", line[len(label) :])
            values = cleaned.split()
            if len(values) != 3 or any(not re.fullmatch(r"\d(?:\.\d+)?", v) for v in values):
                raise ProviderError("invalid_kp_values")
            for base, value in zip(days, values, strict=True):
                start = base + timedelta(hours=index * 3)
                bins.append(KpBin(start, start + timedelta(hours=3), number(float(value), 0, 9)))
        tail = "\n".join(lines[header_index + 9 :])
        if re.search(r"(?m)^\d{2}-\d{2}UT", tail):
            raise ProviderError("unexpected_kp_bin")
        rationale = re.search(
            r"Rationale:\s*(.*?)(?=\n(?:B\. NOAA|:?Product:|:?Issued:|A\. NOAA)|\Z)",
            tail,
            re.DOTALL,
        )
        narratives.append(" ".join(rationale[1].split()) if rationale else "")
        tables.append(tuple(sorted(bins, key=lambda item: item.start)))
    if any(table != tables[0] for table in tables[1:]):
        raise ProviderError("conflicting_kp_tables")
    if len(set(narratives)) > 1:
        raise ProviderError("conflicting_geomagnetic_narrative")
    bins_tuple = tables[0]
    return Snapshot(
        identity,
        Product.KP,
        "NOAA SWPC",
        issued,
        None,
        None,
        fetched,
        bins_tuple[0].start,
        bins_tuple[-1].end,
        (("kp", "index_0_9"),),
        None,
        kp=bins_tuple,
    )


CLOUD_FIELDS = (
    "cloud_area_fraction",
    "cloud_area_fraction_low",
    "cloud_area_fraction_medium",
    "cloud_area_fraction_high",
    "fog_area_fraction",
)


def _weather(
    data: dict[str, Any], identity: str, fetched: datetime, coordinates: tuple[float, float]
) -> Snapshot:
    if data["type"] != "Feature" or data["geometry"]["type"] != "Point":
        raise ProviderError("invalid_geometry")
    returned = data["geometry"]["coordinates"]
    lon, lat = number(returned[0], -180, 180), number(returned[1], -90, 90)
    if abs(lon - coordinates[0]) > 0.0001 or abs(lat - coordinates[1]) > 0.0001:
        raise ProviderError("coordinate_mismatch")
    props = data["properties"]
    issued = timestamp(props["meta"]["updated_at"])
    if issued > fetched + FUTURE_SKEW:
        raise ProviderError("future_issue")
    units = props["meta"]["units"]
    if not isinstance(units, dict) or any(not isinstance(v, str) for v in units.values()):
        raise ProviderError("invalid_units")
    samples = props["timeseries"]
    if not isinstance(samples, list) or not 1 <= len(samples) <= 500:
        raise ProviderError("invalid_timeseries")
    times = [timestamp(sample["time"]) for sample in samples]
    if any(a >= b for a, b in zip(times, times[1:], strict=False)):
        raise ProviderError("unordered_timeseries")
    weather = []
    for index, sample in enumerate(samples):
        details = sample["data"]["instant"]["details"]
        if not isinstance(details, dict):
            raise ProviderError("invalid_shape")
        values = []
        for field in CLOUD_FIELDS:
            value = details.get(field)
            if value is not None and units.get(field) != "%":
                raise ProviderError("unsupported_units")
            values.append(None if value is None else number(value, 0, 100))
        spacing = times[index + 1] - times[index] if index + 1 < len(times) else None
        weather.append(
            WeatherSample(
                times[index],
                values[0],
                values[1],
                values[2],
                values[3],
                values[4],
                spacing,
            )
        )
    return Snapshot(
        identity,
        Product.WEATHER,
        "MET Norway",
        issued,
        None,
        None,
        fetched,
        times[0],
        times[-1],
        tuple(sorted(units.items())),
        coordinates,
        weather=tuple(weather),
    )
