"""Lossless compact form of NOAA's OVATION grid body for the shared cache.

NOAA's file lists 65,160 points as text ("[lon, lat, value], ..."), about 925 KB.
The point order and spacing are fixed, so the body can be stored as its short
header and tail plus one byte per value, and rebuilt byte for byte. A body that
cannot be rebuilt exactly (different layout, decimals, order) is not compacted;
the caller then stores it as before. Every reader still checks the rebuilt
bytes against the digest of NOAA's original body.
"""

import json
import struct

LONGITUDES = range(360)
LATITUDES = range(-90, 91)
POINTS = len(LONGITUDES) * len(LATITUDES)
START = b'"coordinates": ['
# Header and tail are NOAA's small metadata fields; anything larger is unexpected.
MAX_FRAME = 4096
_LENGTHS = struct.Struct(">HH")
_CELLS: list[bytes] = []
_DIGITS = [str(value).encode() for value in range(256)]


def _cells() -> list[bytes]:
    if not _CELLS:
        _CELLS.extend(f"[{lon}, {lat}, ".encode() for lon in LONGITUDES for lat in LATITUDES)
    return _CELLS


def _render(head: bytes, values: bytes, tail: bytes) -> bytes:
    digits = _DIGITS
    rows = b"], ".join([cell + digits[value] for cell, value in zip(_cells(), values, strict=True)])
    return head + rows + b"]]" + tail


def compact(body: bytes) -> bytes | None:
    """The compact form, or None when `body` cannot be rebuilt byte for byte."""
    begin = body.find(START)
    if begin < 0 or body.find(START, begin + 1) >= 0:
        return None
    begin += len(START)
    end = body.find(b"]]", begin)
    if end < 0:
        return None
    end += 2
    head, tail = body[:begin], body[end:]
    if len(head) > MAX_FRAME or len(tail) > MAX_FRAME:
        return None
    try:
        rows = json.loads(body[begin - 1 : end])
    except (ValueError, RecursionError):
        return None
    if not isinstance(rows, list) or len(rows) != POINTS:
        return None
    values = bytearray(POINTS)
    for index, row in enumerate(rows):
        if not isinstance(row, list) or len(row) != 3:
            return None
        value = row[2]
        # Only plain integers 0-255 fit one byte; order is checked by the rebuild.
        if type(value) is not int or not 0 <= value <= 255:
            return None
        values[index] = value
    if _render(head, bytes(values), tail) != body:
        return None
    return _LENGTHS.pack(len(head), len(tail)) + head + tail + bytes(values)


def expand(data: bytes) -> bytes:
    """Rebuild NOAA's original body. Raises ValueError for malformed data."""
    if len(data) < _LENGTHS.size:
        raise ValueError("Truncated compact grid")
    head_size, tail_size = _LENGTHS.unpack_from(data)
    if head_size > MAX_FRAME or tail_size > MAX_FRAME:
        raise ValueError("Invalid compact grid frame")
    frame = _LENGTHS.size + head_size + tail_size
    if len(data) != frame + POINTS:
        raise ValueError("Invalid compact grid size")
    head = data[_LENGTHS.size : _LENGTHS.size + head_size]
    tail = data[_LENGTHS.size + head_size : frame]
    return _render(head, data[frame:], tail)
