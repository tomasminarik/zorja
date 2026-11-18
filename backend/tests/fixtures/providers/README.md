# Provider fixtures

Files in this directory are hand-authored miniature NOAA OVATION, NOAA three-day text, and MET Locationforecast shapes plus malformed/conflicting variants. `manifest.json` records their synthetic authorship, null capture time, and byte hashes. The miniature grid is incomplete and is intentionally rejected by the production parser.

`captured/` contains six original direct HTTP response bodies retrieved on 2026-10-12: complete OVATION grid, NOAA three-day text, and compact weather for public Stockholm, Oslo, Helsinki, and Berlin city centres. Its separate manifest records request URLs, exact receipt times, HTTP status/cache headers, and byte hashes. These are provider captures, not synthetic forecasts or user records. Tests use the recorded receipt time, so future execution dates do not change parser expectations.

The original Kp capture is deliberately preserved, including its contradictory repeated geomagnetic narratives. Whole-feed normalization rejects it. A test explicitly derives the first section to verify G-scale annotations; that transformed input is not presented as an original capture. Numeric duplicates and narrative consistency are tested separately. Regional weather samples verify format and missing-variable handling; they do not establish weather accuracy.

`backend/tools/capture_providers.py` documents the bounded, identifying capture procedure and refuses to overwrite this capture set. Normal repeated source retrieval must use the cache-aware provider client. Attribution: NOAA SWPC; weather data from MET Norway under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), see [MET licensing](https://api.met.no/doc/License). Raw response bodies are unmodified; normalization in tests is a derived representation.

Do not fabricate absent weather variables from layer fractions. Do not label these samples as a provider observation. See `docs/data-sources.md` for authoritative provider specifications and attribution.
