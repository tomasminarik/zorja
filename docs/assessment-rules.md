# Experimental assessment decision table

Target specification, not a calibrated visibility model. The backend's experimental evaluator (`backend/src/aurora_backend/evaluation/`) implements a conservative subset. The darkness/cloud thresholds are provisional technical hypotheses. Current activity uses retained OVATION brackets (see [forecast-model.md](forecast-model.md)); there is no horizon rule, and local planning activity stays unknown. Weak overhead intensity cannot establish the low-activity row below; positive outputs remain experimental and low-confidence, and regional evaluation has not been done.

Evaluate each supported interval separately. Freshness, geographic support, forecast coverage, and sample resolution are required independently: a freshly fetched old model stays stale; a fresh source outside coverage stays `not_covered`. Missing field means `missing`; failed fetch without usable history means `unavailable`; `unknown` is undetermined evidence. A period with some supported samples is `partial`, never implicitly fully covered. Retain all applicable reasons even when a blocker determines the rating.

| Ordered condition | Rating | Action for now | Action for later/planning | Evidence confidence |
| --- | --- | --- | --- | --- |
| Known altitude >= 0 | unfavorable | wait if a later dark candidate exists; otherwise skip | skip | low; moderate only with validated calculation |
| Known altitude > -12 and < 0 | unfavorable | wait if a later dark candidate exists; otherwise skip | skip | same as above |
| Fresh, time-relevant total cloud > 70% | unfavorable | wait only for an identified later candidate without this known blocker; otherwise skip | skip | low; moderate only with complete relevant inputs |
| Fresh supported local activity is low | unfavorable | skip | skip | low/moderate according to evidence rules |
| No blocker, but any essential factor is missing, stale, unavailable, not covered, partial, or unknown | unknown | check_later | check_later | unknown if no essential evidence; otherwise low |
| Qualifying darkness <= -12, supported positive local activity, fresh complete weather 30–70% inclusive | limited | check_later | check_later | low |
| Qualifying darkness <= -12, supported positive local activity, fresh complete weather < 30% | promising | try_now only for short-term evidence covering now | check_later | moderate only after local/temporal rules validated; otherwise low |
| Successful darkness calculation has no window in the search horizon | unfavorable | skip | skip | low/moderate based on calculation evidence |
| Darkness computation unavailable, without another known blocker | unknown | check_later | check_later | unknown/low based on remaining evidence |

`limited` means adequate fresh evidence but mixed cloud obstruction; it does not conceal missing evidence. Exactly 30 and 70 are mixed. Stale heavy-cloud measurements are historical context, not a current known obstruction. Planning never uses `try_now` and never triggers viewing alerts. Before a defensible Kp/geographic mapping exists, global Kp alone yields unknown local activity; it cannot reach the last two positive rows.

`wait` identifies a later candidate with appropriate darkness, not guaranteed aurora. If the current rating is unknown, do not use wait to suggest an opportunity unsupported by essential evidence. A future window may contain unknown segments. Selecting it never transports the current OVATION value into it.

Darkness boundaries: altitude >= 0 daylight; -6 < altitude < 0 civil twilight; -12 < altitude <= -6 nautical twilight; -18 < altitude <= -12 astronomical twilight; altitude <= -18 astronomical night. At -12 qualifying darkness starts; -18 is not required. `mixed` is a period summary; `unknown` means no valid classification. Neither polar night nor season replaces solar altitude.

Confidence describes evidence quality, not a probability. Unknown/partial essential factors cap confidence at low (or unknown if no essential evidence). A known blocker can still be stated even if activity is unavailable. The scientific validity of thresholds remains unproven by software checks.
