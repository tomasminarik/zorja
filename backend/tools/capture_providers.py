"""Explicit, bounded public-provider capture; never part of offline startup."""

import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1] / "tests/fixtures/providers/captured"
URLS = {
    "ovation.json": "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json",
    "kp.txt": "https://services.swpc.noaa.gov/text/3-day-forecast.txt",
    **{
        f"met-{name}.json": (
            f"https://api.met.no/weatherapi/locationforecast/2.0/compact?lat={lat}&lon={lon}"
        )
        for name, lat, lon in [
            ("stockholm", "59.3293", "18.0686"),
            ("oslo", "59.9139", "10.7522"),
            ("helsinki", "60.1699", "24.9384"),
            ("berlin", "52.5200", "13.4050"),
        ]
    },
}


def main() -> None:
    if (ROOT / "manifest.json").exists():
        raise SystemExit("Recorded captures already exist; preserve them and their cache policy")
    ROOT.mkdir(parents=True, exist_ok=True)
    records = []
    with httpx.Client(
        timeout=30,
        headers={"User-Agent": "Zorja/1.0 hello@tomasminarik.com"},
        follow_redirects=False,
    ) as client:
        for name, url in URLS.items():
            with client.stream("GET", url) as response:
                response.raise_for_status()
                body = bytearray()
                for chunk in response.iter_bytes():
                    body.extend(chunk)
                    if len(body) > 2_000_000:
                        raise ValueError("Provider response exceeds capture limit")
                (ROOT / name).write_bytes(body)
                records.append(
                    {
                        "name": name,
                        "url": url,
                        "capturedAt": datetime.now(UTC).isoformat(),
                        "status": response.status_code,
                        "headers": {
                            key: value
                            for key, value in response.headers.items()
                            if key
                            in {
                                "date",
                                "expires",
                                "last-modified",
                                "content-type",
                                "cache-control",
                                "etag",
                                "age",
                            }
                        },
                        "sha256": hashlib.sha256(body).hexdigest(),
                    }
                )
                print(name, response.status_code, len(body))
    (ROOT / "manifest.json").write_text(
        json.dumps(
            {
                "kind": "direct-provider-capture",
                "locations": "Fixed public city centres, not personal device records",
                "files": records,
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
