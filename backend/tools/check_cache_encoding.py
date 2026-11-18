"""Offline encoding sizes for committed public captures; no capacity/latency claim."""

import hashlib
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from aurora_backend.providers.redis_store import encode
from aurora_backend.providers.store import CacheEntry

CAPTURES = Path(__file__).resolve().parents[1] / "tests/fixtures/providers/captured"
AT = datetime(2026, 10, 12, 21, tzinfo=UTC)


def measure() -> dict[str, Any]:
    rows = []
    for filename, key in (
        ("ovation.json", "noaa_ovation"),
        ("met-stockholm.json", "met:18.0686,59.3293"),
    ):
        body = (CAPTURES / filename).read_bytes()
        encoded = encode(
            CacheEntry(key, body, AT, {}, AT, AT + timedelta(minutes=1), None, 0, False)
        )
        rows.append(
            {
                "sourceFile": f"backend/tests/fixtures/providers/captured/{filename}",
                "sha256": hashlib.sha256(body).hexdigest(),
                "rawBytes": len(body),
                "encodedEntryBytes": len(encoded.encode()),
                "entryToRawRatio": round(len(encoded.encode()) / len(body), 4),
            }
        )
    return {
        "kind": "offline_encoding_measurement",
        "measuredOn": "2026-10-30",
        "networkAccess": False,
        "compression": "gzip level 9, mtime 0, base64, JSON metadata",
        "cases": rows,
        "limitations": [
            "Committed public-location captures only, not live requests.",
            "No hosted latency, allocator/index size, quota or capacity measurement.",
            "History duplicates entries; request commands and transfer remain to measure.",
        ],
    }


if __name__ == "__main__":
    print(json.dumps(measure(), indent=2))
