"""Opt-in fixed public-location JPL captures; never required by offline tests."""

import argparse
import hashlib
import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlencode

SITES = [
    ("stockholm", 59.3293, 18.0686),
    ("oslo", 59.9139, 10.7522),
    ("helsinki", 60.1699, 24.9384),
    ("tromso", 69.6492, 18.9553),
    ("kiruna", 67.8558, 20.2253),
    ("utsjoki", 69.909, 27.028),
    ("copenhagen", 55.6761, 12.5683),
    ("reykjavik", 64.1466, -21.9426),
    ("torshavn", 62.0079, -6.7900),
    ("warsaw", 52.2297, 21.0122),
    ("edinburgh", 55.9533, -3.1883),
    ("dublin", 53.3498, -6.2603),
    ("tallinn", 59.437, 24.7536),
    ("riga", 56.9496, 24.1052),
    ("vilnius", 54.6872, 25.2797),
    ("berlin", 52.5200, 13.4050),
    ("north-pole", 90.0, 0.0),
    ("south-pole", -90.0, 0.0),
]
ROOT = Path(__file__).resolve().parents[1] / "tests/fixtures/astronomy"


def fetch(name, latitude, longitude, times):
    params = dict(
        format="text",
        COMMAND="'10'",
        OBJ_DATA="'NO'",
        MAKE_EPHEM="'YES'",
        EPHEM_TYPE="'OBSERVER'",
        CENTER="'coord@399'",
        COORD_TYPE="'GEODETIC'",
        SITE_COORD=f"'{longitude},{latitude},0'",
        QUANTITIES="'4'",
        APPARENT="'AIRLESS'",
        CSV_FORMAT="'YES'",
        EXTRA_PREC="'YES'",
        TIME_DIGITS="'SECONDS'",
    )
    params.update(times)
    url = "https://ssd.jpl.nasa.gov/api/horizons.api?" + urlencode(params)
    body = subprocess.check_output(
        ["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "45", url]
    )
    if b"$$SOE" not in body or b"$$EOE" not in body or len(body) > 1_000_000:
        raise ValueError("Missing or oversized reference table")
    (ROOT / f"{name}.txt").write_bytes(body)
    return dict(
        file=f"{name}.txt",
        latitude=latitude,
        longitude=longitude,
        request=params,
        sha256=hashlib.sha256(body).hexdigest(),
        captured_at=datetime.now(UTC).isoformat(),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-reference-network", action="store_true", required=True)
    parser.parse_args()
    dates = [
        datetime(2026, month, day, hour, tzinfo=UTC)
        for month, day in [(3, 20), (6, 21), (9, 22), (12, 21)]
        for hour in [0, 6, 12, 18]
    ]
    tlist = "'" + ",".join(str(at.timestamp() / 86400 + 2440587.5) for at in dates) + "'"
    records = []
    for name, latitude, longitude in SITES:
        records.append(fetch(name, latitude, longitude, {"TLIST": tlist}))
        print(name, flush=True)
    for name, latitude, longitude, date in [
        ("stockholm-crossings", 59.3293, 18.0686, "2026-03-20"),
        ("tromso-crossings", 69.6492, 18.9553, "2026-12-21"),
        ("helsinki-crossings", 60.1699, 24.9384, "2026-09-22"),
    ]:
        records.append(
            fetch(
                name,
                latitude,
                longitude,
                dict(START_TIME=f"'{date} 00:00'", STOP_TIME=f"'{date} 23:59'", STEP_SIZE="'1 m'"),
            )
        )
        print(name, flush=True)
    (ROOT / "manifest.json").write_text(
        json.dumps(
            dict(
                source="NASA/JPL Horizons DE441 airless topocentric Sun centre",
                documentation="https://ssd-api.jpl.nasa.gov/doc/horizons.html",
                records=records,
            ),
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
