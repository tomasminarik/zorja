"""Offline independent-reference comparison; prints measured errors as JSON."""

import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

from aurora_backend.astronomy.solar import solar_altitude
from aurora_backend.astronomy.windows import darkness_windows
from aurora_backend.domain.types import Interval, Location

ROOT = Path(__file__).resolve().parents[1] / "tests/fixtures/astronomy"


def main() -> None:
    manifest = json.loads((ROOT / "manifest.json").read_text())
    results = []
    for record in manifest["records"]:
        path = ROOT / record["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Reference capture hash mismatch")
        site = Location(latitude=record["latitude"], longitude=record["longitude"], timezone="UTC")
        table = path.read_text().split("$$SOE\n")[1].split("$$EOE")[0]
        samples = []
        for line in table.splitlines():
            fields = line.split(",")
            at = datetime.strptime(fields[0].strip().split(".")[0], "%Y-%b-%d %H:%M:%S")
            samples.append((at.replace(tzinfo=UTC), float(fields[4])))
        errors = [abs(solar_altitude(site, at) - reference) for at, reference in samples]
        result = dict(
            file=record["file"], samples=len(samples), max_altitude_error_degrees=max(errors)
        )
        if "crossings" in record["file"]:
            references = [
                left + (right - left) * ((-12 - a) / (b - a))
                for (left, a), (right, b) in zip(samples, samples[1:], strict=False)
                if (a <= -12) != (b <= -12)
            ]
            coverage = Interval(samples[0][0], samples[-1][0])
            windows = darkness_windows(site, coverage)
            crossings = [
                at
                for w in windows
                for at in (w.interval.start, w.interval.end)
                if at not in (coverage.start, coverage.end)
            ]
            result["max_crossing_error_seconds"] = max(
                abs((a - b).total_seconds()) for a, b in zip(crossings, references, strict=True)
            )
        results.append(result)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
