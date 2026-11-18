# Experimental viewing model

Executable prototype identifier: `visibility-v0.2-bracket-prototype` (the retained-bracket model, called "Option A" on the [decisions page](decisions.md)); prior exact-instant prototype: `visibility-v0.1-prototype`; earlier target proposal identifier: `visibility-v0-proposal`. This document defines target semantics. The backend's conservative prototype implements a subset; no empirical validation is claimed. Executable rules and parameters are in `backend/src/aurora_backend/evaluation/model.py` and [assessment-rules.md](assessment-rules.md). Do not expose a numerical visibility probability or a composite score disguised as one.

## What Zorja forecasts (2026-11-09)

**Status: decided 2026-11-09; the backend fields and the contract are implemented (2026-11-12, [api.md](api.md#what-zorja-forecasts--2026-11-12)).** The app shows them with the approved words: 3 Nights place lines, notes, storm marks and Clear sky tags, the Tonight place line, and Now's "since" lead and quiet line ([App copy](copy.md#what-zorja-forecasts-approved-2026-11-12)). It replaces the planning parts of the sections below.

### The three questions

Zorja answers three questions, each on its own time scale (decided 2026-11-09):

| Question | Asked | Answered from |
| --- | --- | --- |
| Should I go out now? | In the evening, at home | Darkness, cloud and live aurora now |
| Is tonight worth it, and when? | Afternoon or evening | Tonight's clear dark window, and how often aurora reaches this place |
| Which of the next nights should I plan for? | Days ahead | Clear dark time per night, and the storm outlook where it helps |

### What can be known, and how far ahead

| Input | Known ahead | Precision | Local or global |
| --- | --- | --- | --- |
| Darkness | Any time | Exact | Local |
| Cloud | Hours to days, worse with distance | Hourly samples | Local |
| Live aurora (NOAA OVATION) | About 30–90 minutes | Good | Local |
| Storm outlook (NOAA three-day Kp) | 1–3 days | The day, not the hour; it misses many active nights (see [Check against last winter](#check-against-last-winter)) | Global |
| How often aurora reaches a place | Fixed | Depends on the place | Local |

Exactly when aurora appears during a night cannot be forecast: it depends on the solar wind's magnetic direction, which is measured only about an hour before it reaches Earth. Live aurora data never carries over into a later hour or night. NOAA's 27-day outlook is too coarse to use.

### Aurora reach: how places differ

The same storm outlook means different things in different places (decided 2026-11-09). NOAA's [viewing tips](https://www.spaceweather.gov/content/tips-viewing-aurora) give the rule Zorja uses: the aurora zone's southern edge sits at about 66° magnetic latitude at Kp 0 and moves about 2° south per Kp step, to about 48° at Kp 9. These are averages.

**Magnetic latitude.** Zorja uses corrected magnetic latitude (AACGM-v2 at 110 km, the frame the aurora-zone rule is described in). A simple tilted-dipole calculation is 2–5° too far north on the Atlantic side of Europe (Edinburgh 5.0°, Inverness 4.8°, Reykjavík 4.6°, Tórshavn 4.1°, Halifax 3.0°, Oslo 2.5°), which would put Scotland and Iceland in the wrong group. The backend reads it from a precomputed 1° table generated once with the free `aacgmv2` package (MIT licence). Bilinear lookup in the table is within 0.003° of the package across the launch regions, and the value moves about 0.02° by 2030. So the backend gains no runtime dependency and works offline. Regenerate the table when a new IGRF model is released.

**Two Kp values per place.** From the magnetic latitude *m*:
- *Overhead*: Kp ≥ (66 − m) / 2 puts the zone's southern edge overhead.
- *Low in the north*: 2 Kp (4°) less. Aurora's lower edge, about 110 km up, stands at least 10° above the horizon from about 500 km (4.5° of latitude) away, and taller rays reach further. Haze, terrain and light pollution make lower views unreliable, so 10° is the cut-off.

**Three groups:**

| Group | Magnetic latitude | Examples | What decides a night |
| --- | --- | --- | --- |
| Under the zone | 62° or more | Tromsø, Kiruna, Rovaniemi, Oulu, Reykjavík, Yellowknife, Whitehorse | Cloud and darkness; aurora overhead on most nights |
| Edge | 55° to under 62° | Trondheim, Tórshavn, Oslo, Stockholm, Helsinki, Winnipeg | Cloud and darkness; aurora often low in the north, overhead on active nights |
| South | under 55° | Inverness, Edinburgh, Copenhagen, Gdańsk, Warsaw, Kraków, Toronto, Vancouver, Halifax | A storm first, then cloud and darkness |

Inverness sits at 54.98° (aacgmv2 2.7.1, 2026), just under the edge line, so it is South; it was listed under Edge on 2026-11-09 by mistake.

Very far south (under 44°) not even Kp 9 brings aurora low into the northern sky by this rule, so the outlook always reads "not expected" there, even though the biggest storms (May 2024) have gone further. Southern-hemisphere places use the absolute magnetic latitude. Where corrected magnetic latitude is undefined (near the magnetic equator), the place is South with an outlook that is always "not expected". The Kp numbers are never shown in the app.

### Check against last winter

A sanity check on the 180 nights from 1 October 2025 to 30 March 2026, run on 2026-11-09 with free data and no accounts: observed Kp (GFZ Potsdam), NOAA's archived daily three-day forecasts (NOAA NCEI), cloud reanalysis (Open-Meteo, ERA5) and the Abisko magnetometer (INTERMAGNET via BGS). The night's highest Kp over its dark hours (sun 12° or more below the horizon) was compared with each place's two Kp values. It checks that the rules give sensible answers; it is not a calibration and is not described as one.

| Place (group) | Nights aurora reached it by observed Kp | Forecast the evening before said "reaches", and it did | Forecast said "not expected", but it reached |
| --- | --- | --- | --- |
| Kiruna (Under) | 180 of 180 | 180 of 180 | none |
| Oslo (Edge) | 137 | 110 of 140 | 27 of 40 |
| Stockholm (Edge) | 126 | 94 of 123 | 32 of 57 |
| Edinburgh (South) | 35 | 15 of 43 | 20 of 137 |
| Gdańsk (South) | 15 | 5 of 11 | 10 of 169 |
| Warsaw (South) | 5 | 2 of 3 | 3 of 177 |

Forecasts issued two evenings before were slightly worse. Under the zone, the Abisko magnetometer was disturbed by 50 nT or more within an hour on 57 of 68 clear, dark nights (84%), and on 8 of the 17 nights whose Kp stayed under 3. A disturbed local magnetometer marks active aurora overhead; it is a proxy, because last winter's all-sky camera images are not publicly archived.

What it shows:
1. Under the zone and at the edge, aurora reaches the place on most dark nights, and the forecast's "not expected" is wrong more often than right. So the night outlook is not shown there; cloud and darkness decide.
2. In the south, aurora reaches the place on few nights. A night forecast to reach it is two to five times more likely to get aurora than an average night (Edinburgh 35% against 19%, Gdańsk 45% against 8%), but most aurora nights still come without such a forecast. So the outlook helps choose a night but must never sound like a promise, and "not expected" must never sound like "impossible".
3. Overhead versus low in the north can't be told apart by the forecast (Oslo's forecast "overhead" nights were overhead 15 times out of 41). The night outlook therefore has two values, not three.

### How each answer is built

**Now.** Darkness, cloud and live aurora now give go, wait or skip, as today ([assessment rules](assessment-rules.md)), with two additions:
- "Active since": when live aurora is active now, the start of the current unbroken active stretch in the last three hours of received OVATION data the backend already keeps. That is a past measurement, not a forecast; if the stretch reaches the start of the retained data, it says so ("for over three hours").
- Under the zone and at the edge, a quiet moment doesn't discourage, because the night there doesn't rest on the next hour ("Quiet right now. It often picks up here").

**Tonight.** The answer is the clear dark window: the times when it is both dark enough (sun 12° or more below the horizon) and clear (cloud under 30 %), with its start and end. Darkness and cloud become reasons ("clouds clear around 22:40"), not separate rows to compare. Aurora is one line for the place:
- Under the zone: aurora shows overhead on most clear, dark nights here.
- Edge: aurora often shows low in the northern sky here, and overhead on active nights.
- South: the night outlook, *could reach here* (the night's highest forecast Kp over its dark hours reaches the place's low-in-the-north value) or *not expected* (lower), with *not known yet* when the forecast doesn't cover the night.

Live aurora is the current state (the Now answer). In the Tonight redesign (decided 2026-11-10) it is drawn on tonight's arc only as far as the live data reaches, up to about 90 minutes ahead, and never beyond.

**Next nights.** Each night gets its clear dark window and its length, and the same aurora line as Tonight: the fixed place line under the zone and at the edge, the night's outlook in the south. The best night (decided 2026-11-09) is the one with the most clear dark time; in the south, the one with the most clear dark time among nights that *could reach here*, or the most clear dark time if no night could. Tonight-first and ties follow the 3 Nights Best tag rule in [App copy](copy.md), applied within those nights. In the 3 Nights redesign (decided 2026-11-10) each night is shown as its dark hours in 4 to 6 slots, and in the south a slot is marked when its 3-hour Kp forecast reaches the place's low-in-the-north value.

**Clear sky windows.** A window is at least 1 hour of clear, dark time, and a cloudy break, however short, always splits two windows (decided 2026-11-10). On 182 winter nights (October 2025 to March 2026) in six launch-region places, from archived hourly cloud cover (Open-Meteo, ERA5 and ECMWF IFS), half to four fifths of nights had no window, up to about a third of clear nights had two or more, three or more was rare (7 % at most) and the most common break between windows was one cloudy hour. MET Norway's forecast is hourly for about the first 2.5 days and 6-hourly after that, so windows start and end on the hour unless darkness cuts them, and the third night comes in 6-hour blocks.

None of this is a probability or a score. It stays an experimental, unvalidated assessment (see the start of this page).

### Not part of the forecast

General patterns, such as aurora being most common around midnight and around the equinoxes, belong in viewing tips, not in the forecast (decided 2026-11-09).

### API changes

All additive and optional in v1 (`/v1/forecast` stays 1.0.x); no existing field changes meaning, and the planning rating stays as it is (local planning activity remains unknown). They go into `docs/api.md` and `api/openapi.json` with the code, not before.

| Field | Contents |
| --- | --- |
| `auroraReach` (on Forecast) | `group`: `under_zone`, `edge` or `south` · `magneticLatitude` (degrees, AACGM-v2, 110 km) · `kpOverhead` and `kpLowInNorth` (may be above 9, meaning never by this rule) · `method`: `aacgm-v2-noaa-oval-v1`. Null when coordinates can't be placed. |
| `planning[].auroraOutlook` | `status`: `could_reach`, `not_expected`, `not_applicable` (Under and Edge), `not_known_yet` (forecast doesn't cover the night's dark hours), `stale` or `unavailable` · `highestKp` (null unless `could_reach` or `not_expected`) · `sourceId`. Uses the night's dark windows, or the whole night period if it has none. `globalKpContext` stays as it is. |
| `now.activeSince` | RFC3339 instant or null (not active now, or unknown) · `activeSinceIsBufferLimited`: true when the active stretch reaches the start of the retained three hours. |

As built (2026-11-12): the outlook ignores dark hours already past, like `globalKpContext`; places the rule never reaches are always `not_expected`, with or without a Kp forecast; `activeSince` is the forecast time of the first retained run in the stretch, and the flag means the stretch may have started earlier (the backend may also hold less than three hours after a gap in collection).

Unknown enum values fall back to neutral presentation, as for every other field.

### Copy

The night detail's Low / Moderate / High outlook is replaced by the aurora line above (2026-11-09). Copy for the place and outlook lines is in [App copy](copy.md), written with the Figma work; the wording on this page describes meaning only.

## Evaluation sequence

Current coverage parameters follow the retained-bracket model (`visibility-v0.2-bracket-prototype`). A three-hour retained buffer supplies received endpoints; at most 20-minute brackets use their minimum bilinear signal with explicit supportedInterval. The newest future grid is additionally exposed at its exact forecast instant. Provider point coverage is never rewritten as a backend interval, and observations remain unvalidated. Historical review passages at the end describe the superseded gate, not current defaults.

1. Validate coordinates, timestamps, source freshness, and temporal/geographic coverage.
2. Calculate solar altitude and candidate viewing intervals at the user's location.
3. Align auroral and weather inputs to each interval; no input applies outside its supported temporal coverage.
4. Evaluate local auroral potential, cloud obstruction, and other modeled factors separately.
5. Apply blockers before selecting a qualitative assessment and recommended action.
6. Return source provenance, missing inputs, limitations, and decision reasons.

## Time and darkness

Evaluate now separately from the next window. Search the next 72 hours for sufficiently dark conditions. The proposed viewing threshold is solar altitude <= -12 degrees (nautical darkness or darker); -18 degrees marks astronomical darkness. These are initial product heuristics requiring evaluation, not claims that aurora is impossible in brighter twilight.

Distinguish daylight, civil twilight, nautical twilight, astronomical twilight, and astronomical night using conventional solar altitude boundaries 0, -6, -12, and -18 degrees. Sunrise/sunset definitions involving refraction are separate from these altitude classifications.

Candidate windows are intervals below the chosen viewing threshold. If already below it, start the current window at evaluation time. Cap continuous darkness at the search horizon, flag the end as search-limited, and expose the first 24 hours in upcoming detail. If no qualifying interval exists, return `no_darkness_within_horizon` with `upcoming: null`; do not calculate a nonexistent next sunset. This includes midnight sun and seasons where only brighter twilight occurs. Polar night is not proof of astronomical darkness: use actual solar altitude.

The confirmed planning horizon is the next three relevant viewing nights. Use local noon-to-noon periods as grouping boundaries, labeling each with its starting local date. After midnight, include the remaining current night if qualifying darkness remains before the next local noon; after that night has finished, begin with tonight rather than yesterday’s completed night. At or after local noon, start with the period containing evaluation time. Return that first period and the following two periods, including explicit no-window states where seasonal darkness is absent; do not skip ahead months looking for a night. This avoids counting the after-midnight half of one night twice. Build boundaries with the IANA timezone, not a fixed 24-hour addition; DST produces different durations. Do not extend source coverage to fill the third entry.

## Aurora and weather

Use OVATION for a spatial short-term signal, preserving its actual forecast time. Geographic interpolation and any nearby horizon-view treatment must be explicit and tested; do not use a blanket 1000 km visibility radius. Direct grid intensity alone can miss aurora visible toward the horizon. Central European behavior needs evaluation before release.

Use three-hour Kp forecast bins only for planning. A planning geographic heuristic is a separate model component; no geographic threshold table is accepted yet. Current OVATION values must not persist into tonight or tomorrow. Unsupported intervals have unknown local activity even if a global Kp outlook exists.

Weather evaluation uses cloud fraction, available cloud layers, and available fog information at the relevant time. Preserve original sampling resolution. Do not imply minute-level clearing from hourly or six-hourly data. Proposed cloud bands: <30% favorable, 30–70% mixed, >70% obstructed. These are tunable heuristics; thin high cloud and broken cloud complicate real viewing. Missing total cloud fraction yields unknown weather, not a clear sky.

## Output semantics

| Field | Values and meaning |
| --- | --- |
| Rating | `unfavorable`, `limited`, `promising`, `unknown` — experimental viewing assessment |
| Action | `try_now`, `wait`, `skip`, `check_later` |
| Basis | `short_term`, `planning`, `unavailable` — auroral basis for this assessment |
| Confidence | `low`, `moderate`, `unknown` — evidence quality, never a calibrated probability |

`promising` requires suitable darkness, adequate weather, a supported local auroral signal, and fresh essential inputs. A current assessment may recommend `try_now` only if short-term evidence covers now. Planning entries never recommend `try_now` or trigger viewing alerts. `wait` means a specifically identified later candidate window exists, not a promise of aurora. `skip` applies to clear blockers for the evaluated interval; `check_later` applies to uncertainty without a concrete opportunity.

Known blockers may yield `unfavorable` even with missing auroral inputs: daylight or heavy cloud still blocks useful guidance. Without such a blocker, essential missing or stale inputs yield `unknown`. Low activity with fresh relevant evidence is different from missing activity.

Reason codes include `daylight`, `twilight_too_bright`, `cloud_obstruction`, `low_activity`, `activity_not_covered`, `weather_missing`, `source_stale`, `source_unavailable`, `no_darkness_within_horizon`, `unmodeled_local_conditions`, and `experimental_model`. Reasons carry an effect (`blocker`, `limitation`, `information`) and an English explanation. Code is stable; prose can evolve.

## Freshness policy proposal

Keep fetched time, provider issued time, and valid coverage separate. OVATION now uses the publication/target freshness and 20-minute maximum bracketing gap of the retained-bracket model, rather than rejecting forecast lead with a 20-minute observation-age ceiling. HTTP transport expiry governs refresh, not OVATION scientific target coverage. Three-day Kp retains a 24-hour issue ceiling. On the hosted service, a successfully checked Kp is reused and counts as fresh for up to 60 minutes and OVATION is reused for up to 15 minutes (decided 2026-11-03). Neither operational freshness nor target grace supplies extrapolated local activity. MET cache refresh follows Expires; freshness also requires relevant time samples and an acceptable model issue age. Start with a six-hour weather model age ceiling and evaluate regional differences. Version all changes to thresholds and age policies.

Background alert checks target 15 minutes with a 30-minute fallback; this is an operational cadence, not a scientific validity interval. Keep age ceilings and coverage rules independent of it. Never carry a previous `promising` state to the next tick, extend short-term data into future nights, or reset an old issue age through a new fetch. Foreground revalidation remains governed by actual evidence/condition boundaries.

No continuous local activity interval is inferred from one grid. The implemented retained-bracket rule ("Option A") uses the minimum signal of two already-received targets no more than 20 minutes apart, with explicit experimental support [t1, t2). No bracket means not-covered current activity. Independent scientific validation was not made a precondition (decisions, 2026-10-13) and is not claimed.

## Required validation

Test noon storms, clear/dark weak activity, strong activity under cloud, source expiry, NOAA fallback lead time, geographically unsupported activity, missing weather layers, longitude wrap, midnight sun, polar night, twilight without astronomical night, local midnight, DST, and partial coverage of the third planning night. Record replay fixtures for Northern and Central Europe. Compare to observations before strengthening claims. User sightings, if added, need bias-aware evaluation; they are not automatically ground truth.

## Specification additions

See [assessment-rules.md](assessment-rules.md) for the ordered rating/action table, exact cloud-band edges, twilight boundaries, and evidence-confidence limits. The 0.2.0 contract carries explicit factors and disjoint planning windows. Calendar grouping of supplied darkness intervals is implemented and tested in the foundation; solar altitude and bounded darkness windows are implemented and independently compared with JPL reference values (`backend/tools/check_solar_reference.py`). The conservative viewing evaluator prototype is implemented; full regional activity support remains open.


## Historical frontend review clarification (before Option A)

The foreground request floor is 60 seconds and is separate from evidence expiry. An expired assessment can remain visible as timestamped history while its active recommendation is withdrawn. This does not change observation-age ceilings or permit current OVATION to cover future intervals. Global Kp is now exposed on planning nights as provider-native bins with explicit source/coverage status. Future interval basis is planning only when fresh Kp context covers the representative sample; local activity remains unknown/not-covered until a separate geographic/temporal rule is supported. No threshold, visibility probability, observation age or matching tolerance was changed by this review response. Reason provenance and context semantics were clarified without claiming a new calibrated model.

At the time of this review, short-term activity coverage had to be resolved before further client work. The then-current exact-instant/20-minute policy remained conservative and cannot make the recorded long-lead forecast actionable. Do not fix that by increasing a matching tolerance or age ceiling merely to enable alerts. A follow-up must assess provider update/issue/forecast semantics and retained forecasts with primary sources and regional replay, then document any supported interval or horizon treatment. Existing rating/factor fields can express the qualitative result, but backend matching/spatial metadata may require an additive activity-evidence field distinct from provider `Source.validFrom/validUntil`; those fields must not silently become backend tolerance windows. v1 is not frozen while this design is open.


## Historical interface freeze boundary (before Option A)

The v1 interface was frozen at 1.0.0 with optional activityEvidence metadata. At the initial freeze, supportedInterval was always null; the then-current exact-instant model and scientific gates had not been relaxed. The retained-bracket model (2026-10-13) subsequently implemented the experimental coverage rule. Earlier statements that the interface must remain unfrozen are superseded only for interface design; no scientific nonzero interval has been validated. Further model work, including regional validation, remains open.
