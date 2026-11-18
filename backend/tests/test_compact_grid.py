"""Lossless compact storage of the OVATION grid body; no network or Redis needed."""

import base64
import gzip
import hashlib
import json
from datetime import timedelta

import pytest
from test_activity_brackets import AT, body
from test_contract import ROOT

from aurora_backend.providers.compact_grid import MAX_FRAME, POINTS, compact, expand
from aurora_backend.providers.models import Product, ProviderError
from aurora_backend.providers.parsers import normalize
from aurora_backend.providers.redis_store import GRID_MARKER, decode, encode, pack, unpack
from aurora_backend.providers.store import CacheEntry

CAPTURED = ROOT / "backend/tests/fixtures/providers/captured/ovation.json"


def test_captured_and_synthetic_grids_rebuild_byte_for_byte():
    for raw in (CAPTURED.read_bytes(), body(55), body(-30)):
        data = compact(raw)
        assert data is not None and len(data) < 70_000
        assert expand(data) == raw
        assert len(gzip.compress(data)) < 10_000


def test_the_rebuilt_grid_has_the_same_snapshot_identity_and_values():
    raw = CAPTURED.read_bytes()
    at = AT + timedelta(days=400)
    rebuilt = expand(compact(raw) or b"")
    original, again = normalize(Product.OVATION, raw, at), normalize(Product.OVATION, rebuilt, at)
    assert again == original  # the API's source IDs come from this identity


def edited(change):
    data = json.loads(CAPTURED.read_text())
    change(data)
    return json.dumps(data).encode()


@pytest.mark.parametrize(
    "raw",
    [
        # Any layout that cannot be rebuilt exactly is left as it was.
        json.dumps(json.loads(CAPTURED.read_text()), separators=(",", ":")).encode(),
        edited(lambda d: d["coordinates"][7].__setitem__(2, 5.5)),
        edited(lambda d: d["coordinates"][7].__setitem__(2, 256)),
        edited(lambda d: d["coordinates"][7].__setitem__(2, -1)),
        edited(lambda d: d["coordinates"][7].__setitem__(2, True)),
        edited(lambda d: d["coordinates"].reverse()),
        edited(lambda d: d["coordinates"].pop()),
        edited(lambda d: d["coordinates"].append([0, 0, 0])),
        edited(lambda d: d["coordinates"][3].append(1)),
        edited(lambda d: d.__setitem__("note", "x" * (MAX_FRAME + 1))),
        edited(lambda d: d.__setitem__("extra", {"coordinates": []})),
        b'{"coordinates": [',
        b"not json",
        b"",
    ],
)
def test_bodies_that_cannot_be_rebuilt_exactly_are_not_compacted(raw):
    assert compact(raw) is None


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b"\x00",
        b"\x00\x01\x00\x01ab" + bytes(POINTS - 1),
        b"\x00\x01\x00\x01ab" + bytes(POINTS + 1),
        b"\xff\xff\x00\x00" + bytes(POINTS),
    ],
)
def test_malformed_compact_data_is_rejected(data):
    with pytest.raises(ValueError):
        expand(data)


def entry(raw):
    return CacheEntry(
        Product.OVATION.value,
        raw,
        AT - timedelta(minutes=3),
        {},
        AT,
        AT + timedelta(minutes=1),
        None,
        0,
        False,
    )


def test_cache_stores_the_grid_compactly_and_still_reads_the_old_form():
    raw = body(55)
    digest = hashlib.sha256(raw).hexdigest()
    packed = pack(raw, grid=True)
    assert packed.startswith(GRID_MARKER) and len(packed) < 15_000
    assert unpack(packed, digest) == raw
    # Entries written before this change (plain gzip of NOAA's bytes) still decode.
    old = pack(raw)
    assert not old.startswith(GRID_MARKER) and len(old) > 100_000
    assert unpack(old, digest) == raw
    separate = json.loads(encode(entry(raw), embed=False))
    for stored in (packed, old):
        assert decode(json.dumps(separate), AT, {digest: stored}).body == raw
    # A body that cannot be compacted falls back to the old form.
    loose = json.dumps(json.loads(raw), separators=(",", ":")).encode()
    assert not pack(loose, grid=True).startswith(GRID_MARKER)


def test_tampered_compact_body_fails_the_original_digest():
    raw = body(55)
    data = bytearray(compact(raw) or b"")
    data[-1] = (data[-1] + 1) % 256  # one grid value changed
    tampered = GRID_MARKER + base64.b64encode(gzip.compress(bytes(data))).decode()
    with pytest.raises(ValueError, match="checksum"):
        unpack(tampered, hashlib.sha256(raw).hexdigest())
    for value in (GRID_MARKER + "not base64!", GRID_MARKER):
        with pytest.raises(ValueError):
            unpack(value, hashlib.sha256(raw).hexdigest())
    separate = json.loads(encode(entry(raw), embed=False))
    with pytest.raises(ProviderError, match="cache_payload_invalid"):
        decode(json.dumps(separate), AT, {separate["digest"]: tampered})
