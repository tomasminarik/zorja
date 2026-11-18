# External data assessment

Assessment date: 2026-10-12. Documentation and endpoint contents were inspected through web access; this is not a completed adapter or a live service integration test. Linked sources are authoritative provider references. Operational behavior must be rechecked during implementation.

Adapters, a bounded persistent cache, recorded captures and live source diagnostics are implemented in `backend/src/aurora_backend/providers/`. The assessment below remains the provider background; it does not imply empirical weather validation.

## NOAA SWPC

Current implementation: the retained-bracket model ("Option A", 2026-10-13) adds retained-grid experimental local brackets and publication/forecast-target freshness. NOAA's original timestamps and point coverage remain intact. These are application heuristics, not NOAA-defined continuous validity or empirical calibration. Earlier assessment text below remains the provider background.

[OVATION product documentation](https://www.spaceweather.gov/products/aurora-30-minute-forecast) describes a 30–90 minute auroral location/intensity forecast. Solar-wind input outages may cause Kp-based fallback with no forecast lead time. The product is a regional auroral signal; our weather-adjusted local visibility assessment is a separate, unvalidated model.

[Latest OVATION JSON](https://services.swpc.noaa.gov/json/ovation_aurora_latest.json) is the proposed gridded short-term input. Verify coordinate ordering, longitude wrapping, grid completeness, numerical bounds, observation/forecast timestamps, and changes between payload versions using captured fixtures. Do not label its values as our chance of seeing aurora. Preserve the provider forecast time and avoid manufacturing a continuous validity interval unsupported by its timestamps.

[Three-day forecast text](https://services.swpc.noaa.gov/text/3-day-forecast.txt) contains issued-time and UTC three-hour Kp planning bins. Text parsing requires fixtures and strict rejection of ambiguity. During this assessment the retrieved text contained repeated geomagnetic sections with inconsistent narrative statements. Do not assume every successful download is semantically coherent; reject conflicting duplicated tables, retain last valid input as stale, and expose degraded status. Do not derive guidance from the narrative text alone.

The three-day feed covers provider UTC dates, not necessarily three complete future local nights. Kp is a global activity indicator, not a local visibility probability. Any Kp-to-geographic planning heuristic requires documented calibration; until then return unknown local activity rather than a precise viewing claim.

## Weather: proposed MET Norway Locationforecast

Use [Locationforecast 2.0](https://api.met.no/weatherapi/locationforecast/2.0/documentation) as the candidate public weather interface for the Yr preference; do not scrape the Yr website. Begin with `compact`, request `complete` only if its additional variables are necessary. Verify regional coverage and cloud quality for Nordic and Central European fixtures before confirming the choice.

The [data model](https://api.met.no/doc/locationforecast/datamodel) provides total and layer cloud fractions and weather details, with availability varying by region and forecast horizon. Missing fields stay null. Never sum cloud layers into total cloud cover or substitute humidity for measured fog. Weather at the current time is still a model forecast unless an observation feed is explicitly added.

The [integration guide](https://api.met.no/doc/locationforecast/HowTO) requires an identifying User-Agent with real contact information, HTTPS, no more than four coordinate decimals, cache metadata, and handling of throttling and deprecation. Use the confirmed contact `hello@tomasminarik.com` in the project-identifying User-Agent before making automated requests.

Follow the [terms of service](https://api.met.no/doc/TermsOfService): backend proxy, cache reuse through Expires, conditional If-Modified-Since requests, and jittered refreshes. Avoid repeated upstream requests for each app refresh. Handle 304 without losing the cached payload.

The [licensing policy](https://api.met.no/doc/License) specifies attribution to MET Norway and describes NLOD 2.0 / CC BY 4.0 licensing unless exceptions apply. Return provider attribution in the API and display it in the app. Asset licenses need separate attention if provider icons are used.

## Astronomy and remaining inputs

Calculate solar altitude and darkness intervals using a tested astronomy library, selected and verified during implementation. Test independently against reference values, especially polar latitudes. MET sunrise data may be a comparison source, but sunset alone is insufficient for twilight and polar handling.

Moon brightness/elevation, artificial light, terrain, and horizon obstruction can affect viewing. MVP must report these as unmodeled limitations until data and algorithms exist. Do not silently claim they were accounted for. No paid provider or additional dataset is approved by this assessment.
