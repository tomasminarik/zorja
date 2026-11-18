# App copy

Approved 2026-11-05. Every sentence the app can show, and the API values that pick it. The Figma screens show one example of each; this list covers the rest. The API's own `summary` and `message` strings are never shown.

## Rules

- Headlines are Title Case and end with a full stop. Times are local, 24-hour, with an en dash for ranges (`23:00–03:30`).
- Capital letters (2026-11-10): Title Case for anything that names something or is tapped (headlines and card titles with a full stop; section headings such as "Tonight's Forecast", buttons, tags and menu items without one). Sentence case for anything that is a sentence or a value (notes, place lines, slot words, "Dark sky 17:17–05:41").
- No percentages, scores, Kp numbers or chances anywhere (see [decisions](decisions.md)).
- Pick the copy in this order: app state (loading, offline, error) → `now.action` → the first `blocker` reason → factors. `information` reasons (`experimental_model`, `unmodeled_local_conditions`) are covered once in About, not on every screen.
- "Tonight" is the first planning night. On a night that started before midnight and is still dark, it stays "Tonight" until the night's period ends at noon.
- `<Day>` is the short weekday for rows ("Thu 6") and the full weekday in headlines ("Thursday").
- `<window>` is the planning or upcoming window: `Until HH:MM` if it has started, `HH:MM–HH:MM` if it is later, `From HH:MM` if its end is search-limited.

## Now

| When (API) | Headline | Lead | Bottom line |
| --- | --- | --- | --- |
| `action: try_now` | Go Out Right Now. | Dark, clear and aurora active overhead. | Tonight Best `<window>`. |
| `try_now` during polar night (darkness window covers the whole day) | Go Out Right Now. | It’s polar night, dark all day. Clear until `HH:MM`, aurora active. | Today Best Until `HH:MM`. |
| `wait`, blocker `cloud_obstruction` | Wait Until `HH:MM`. | Cloud clears around `HH:MM`, and it stays dark all night. ¹ | Tonight Best `<window>`. |
| `wait`, blocker `daylight` | Too Bright Until `HH:MM`. | Aurora is active, but daylight hides it. Tonight is checked on its own. ² | Tonight Best `<window>`. |
| `wait`, blocker `twilight_too_bright` | Dark Enough At `HH:MM`. | It’s twilight now, still too bright for faint aurora. | Tonight Best `<window>`. |
| `skip`, blocker `cloud_obstruction` | Skip Tonight. | Thick cloud all night, whatever the aurora does. | `<Day>` Looks Clearer. ³ |
| `skip`, blocker `low_activity` | Quiet Right Now. | Dark and clear, but there’s little aurora overhead. It can pick up quickly. | Tonight Clear `<window>`. ⁵ |
| `skip`, blocker `no_darkness_within_horizon` | Too Bright All Night. | The sun stays too high here for aurora to show. | Next 3 Nights No Darkness. |
| `wait` or `skip`, blocker `daylight` or `twilight_too_bright`, no dark window tonight (the backend sends `wait` when a later night gets dark) | Too Bright Tonight. | It doesn’t get dark enough here tonight. | `<Day>` Gets Dark. ³ |
| `check_later`, rating `limited` (30–70 % cloud) | Partly Cloudy. | It’s dark and aurora is active, but cloud comes and goes. Watch for gaps. | Tonight Dark `<dark window>`. |
| `check_later`, `weather_missing` | Clouds Not Known. | It’s dark and aurora is active, but there’s no cloud forecast right now. | Look Up And Check. |
| `check_later`, `activity_not_covered` or activity `unknown`/`unavailable` | Aurora Not Known. | It’s dark and clear, but there’s no live aurora data for here right now. | Look Up And Check. |
| `check_later`, `source_stale` | Out Of Date Since `HH:MM`. | Zorja can’t get fresh data right now. Don’t rely on the last forecast. | Checking Again At `HH:MM`. ⁴ |
| `check_later`, `source_unavailable`, no other blocker | Can’t Check Right Now. | Some of the data Zorja needs isn’t available. It tries again soon. | Checking Again At `HH:MM`. ⁴ |

¹ The second clause depends on darkness: "and it stays dark all night" when darkness lasts to the window's end; otherwise "and it stays dark until `HH:MM`".
² Use "Aurora is active, but…" only when `upcomingActivityInstant.activity` is `supported`; otherwise "Daylight hides any aurora. Tonight is checked on its own."
³ The nearest planning night with more clear dark time. If there is none: "Next 3 Nights Look Cloudy." (cloud) or nothing.
⁴ `refreshAfter`, or the next retry time if that is later.
⁵ Low activity is about the next hour only, so the screen says "right now" and never skips the night. The bottom line gives tonight's clear dark window; without one it is "Tonight Cloudy After `HH:MM`." or nothing.

The line above the headline is "Updated `HH:MM`" (`generatedAt`); when offline it is the red Offline tag plus "Updated `HH:MM`"; when stale it is "Last update `HH:MM`".

## Tonight

Headline: "Tonight Best `<window>`." · quiet now: "Tonight Clear `<window>`." · "Tonight Partly Cloudy." · "Tonight Aurora Not Known." · "Tonight Cloudy All Night." · "Tonight No Dark Hours." · "Tonight Clouds Not Known." · "Tonight Waiting For Data." · polar night: "Dark All Day. Best Until `HH:MM`." · loading: "Tonight Checking The Sky."

| Row | Values |
| --- | --- |
| Dark Sky | `Until HH:MM` · `From HH:MM` · `HH:MM–HH:MM` · All Day · None · Checking |
| Clear Sky | `Until HH:MM` · `HH:MM–HH:MM` · Clear All Night · Partly Cloudy · Mostly Cloudy · Overcast · Not Known · Out Of Date · Checking |
| Aurora | Active Now (`supported`) · Quiet Now (`low`) · Not Known (no live data for this place) · Not Known Yet (no short-term data for that time) · Out Of Date · Checking |

Clear Sky: Overcast = no clear dark time; Mostly Cloudy = some, but under half of the dark time; Partly Cloudy = rating `limited`, drawn as a hatched yellow bar over the partly cloudy time **(proposed 2026-11-09, was short yellow pieces with gaps)**.

Under the aurora bar: "Next Hour Only" (short-term data covers about an hour).

Notes under the chart, one at most, in this order: stale ("Last update `HH:MM`. Cloud and aurora data are hidden until fresh data arrives, so an old forecast isn’t mistaken for tonight’s."), weather missing ("There’s no cloud forecast for this place right now. Zorja will check again soon."), daytime ("Live aurora data only reaches about an hour ahead. Check again after dark."), twilight ("The lighter blue is twilight: getting dark, but still too bright for faint aurora."), no darkness ("Aurora needs a dark sky. It won’t get dark enough here in the next three days.").

Card under the chart: "Give Your Eyes 20 Minutes." with More Tips when tonight has a window; "`<Day>` Looks Clearer." with See 3 Nights when tonight is skip and another night is better.

### Tonight redesign (approved in Figma 2026-11-10)

Figma: Screens → Tonight and 3 Nights. Built 2026-11-10; the Tonight copy above (16-hour chart headlines and notes) no longer describes the app. Where the table has no line, Tonight uses Now's headline and lead (Go, Too Bright Tonight, Can't Check). The Tonight place line follows the place's group and tonight's storm outlook ([What Zorja forecasts](#what-zorja-forecasts-approved-2026-11-12)).

- Grey top: the place line, the headline and one lead sentence (for example "Go Out At 22:40." and "It's too cloudy to see anything now."). The full headline and lead set is written with the build, from the table above. There is no clear sky windows row.
- Section heading: "Tonight's Forecast". Under it, one note about the time under the needle (below).
- Time stamp above the needle: "Now `HH:MM`" at the present time, "`HH:MM`" anywhere else.
- Card under the forecast: "Give Your Eyes 20 Minutes." with More Tips.

When brightness alone decides (daytime, twilight or midnight sun with aurora quiet), the note names only the light: "Too bright until `HH:MM`.", or "Too bright all night." in midnight sun. On Tonight and 3 Nights the last update reads "Updated `HH:MM`" in every state.

The note's tense follows the time under the needle, not the present: "is" now; "should" and "will" within the live aurora data (up to about 90 minutes ahead); beyond that, aurora is never stated as on or quiet. "Should" is the only forecast word, never "likely" or a chance.

Now:

| Sky | Aurora on | Aurora quiet | No live aurora data |
| --- | --- | --- | --- |
| Clear and dark | Aurora is on, and the sky is clear. | Clear and dark, but aurora is quiet. | Clear and dark. No live aurora data here. |
| Partly cloudy | Aurora is on, with gaps in the clouds. | Some gaps in the clouds. Aurora is quiet. | Some gaps in the clouds. No live aurora data here. |
| Cloudy | Aurora is on, but clouds cover it. | Cloudy, and aurora is quiet. | Cloudy. No live aurora data here. |
| Too bright | Aurora is on, but it's too bright to see it. | Too bright until `HH:MM`. | Too bright until `HH:MM`. |

Within the live aurora data ("should stay" when aurora is on now, "should be" when it isn't):

| Sky | Aurora on | Aurora quiet | No live aurora data |
| --- | --- | --- | --- |
| Clear and dark | Aurora should stay on, and the sky will be clear. | Clear and dark, but aurora should stay quiet. | Clear and dark. No live aurora data here. |
| Partly cloudy | Aurora should stay on, with gaps in the clouds. | Some gaps in the clouds. Aurora should stay quiet. | Some gaps in the clouds. No live aurora data here. |
| Cloudy | Aurora should stay on, but clouds will cover it. | Cloudy, and aurora should stay quiet. | Cloudy. No live aurora data here. |
| Too bright | Aurora should stay on, but it'll be too bright to see it. | Too bright until `HH:MM`. | Too bright until `HH:MM`. |

Beyond the live aurora data:

| Sky | Note |
| --- | --- |
| Clear and dark | Clear and dark. Aurora can only be known about 90 minutes ahead. |
| Partly cloudy | Some gaps in the clouds. Aurora can only be known about 90 minutes ahead. |
| Cloudy | Cloudy. |
| Too bright | Too bright until `HH:MM`. |
| Past the end of the weather forecast | Weather not known yet. |

State copy (approved 2026-11-10). Headline · lead · note under "Tonight's Forecast" at now:

| State | Headline | Lead | Note |
| --- | --- | --- | --- |
| Wait for cloud | Go Out At `HH:MM`. | It’s too cloudy to see anything now. | Aurora is on, but clouds cover it. |
| Skip, overcast | Skip Tonight. | Thick cloud all night, whatever the aurora does. | Aurora is on, but clouds cover it. |
| Daytime | Go Out At `HH:MM`. | It’s too bright to see anything now. | Too bright until `HH:MM`. |
| Twilight | Go Out At `HH:MM`. | It’s twilight now, still too bright for faint aurora. | Aurora is on, but it’s too bright to see it. |
| Midnight sun | Too Bright All Night. | The sun stays too high here for aurora to show. | Too bright all night. |
| Polar night, go now | Go Out Right Now. | It’s polar night, dark all day. Clear until `HH:MM`. | Aurora is on, and the sky is clear. |
| Quiet | Quiet Right Now. | Clear and dark, but there’s little aurora overhead. | Clear and dark, but aurora is quiet. |
| Partly cloudy | Partly Cloudy. | Cloud comes and goes. Watch for gaps. | Aurora is on, with gaps in the clouds. |
| Aurora not known | Aurora Not Known. | It’s clear and dark, but there’s no live aurora data for here. | Clear and dark. No live aurora data here. |
| Weather missing | Clouds Not Known. | There’s no cloud forecast for this place right now. | Aurora is on. No cloud forecast here right now. |
| Out of date | Out Of Date Since `HH:MM`. | Zorja can’t get fresh data right now. Don’t rely on the last forecast. | Updated `HH:MM`. Cloud and aurora are hidden until fresh data arrives. |
| Loading | Checking The Sky. | Looking at darkness, clouds and aurora over `<place>`. | Checking the sky. |

Offline with a current forecast adds the red Offline tag and "Updated `HH:MM`" above the headline. The tips card is hidden when tonight has no window to plan for; on Skip it reads "`<Day>` Looks Clearer." with See 3 Nights.

## 3 Nights

Figma: Screens → Tonight and 3 Nights, and the 3 Nights frames of Forecast and App states. Approved 2026-11-10, built 2026-11-11. The place line, the group notes, the southern storm marks and the Clear sky tag follow the API's `auroraReach` and each night's `auroraOutlook` (since 2026-11-12, [What Zorja forecasts](forecast-model.md#api-changes)); without them the grey top shows only when offline and the note only in the states below.

- Grey top: the place line only, by group. Under the zone: "In `<Place>`, aurora shows most clear nights, so the clearest night is the best one." Edge: "In `<Place>`, aurora often shows low in the northern sky, so the clearest night is the best one." South: "Aurora reaches here only in storms, so the best night is a clear one a storm could reach."
- Section heading: "Next Three Nights". Note, under the zone and at the edge: "Clear, dark hours decide here. Aurora itself can only be known about 90 minutes ahead." South: "Most of the time aurora comes without warning. It needs darkness and a clear sky."
- One card per night, in date order. Top row: a tag on the left and, on the Best night only, the green Add To Calendar button on the right (calendar icon only, "Add To Calendar" as its accessibility label); a card with neither has no top row. Then the full weekday ("Tuesday") with the date under it ("10th November") and "Dark sky `HH:MM`–`HH:MM`" under the date ("Dark sky all day" in polar night, "Dark sky from `HH:MM`" when the darkness runs past the search; tonight's dark sky starts when it actually got dark, not when the forecast was made), and a large Sky icon for the night as a whole. Then the forecast slots: a Sky icon over the hour ("17"); the hour is yellow only when the slot is fully clear. A slot with no dark time has no icon.
- Tags: "Best" (yellow, by the Best tag rule below), "Skip" (no clear dark window), and in the south "Clear sky" (clear, but no storm forecast to reach the place). Other nights, and nights whose weather isn't known, have no tag.
- Add To Calendar (2026-11-13: a button in the Best night's card, replacing the card under the nights). The event starts at the Best night's clear window, or now if it has begun: title "Look for the aurora", from the window start to its end, with the place name as location and the note "Give your eyes 20 minutes to adjust. A Zorja outlook, not a promise."
- No clear sky window chips.
- States (approved 2026-11-10): out of date notes "Updated `HH:MM`. Cloud is hidden until fresh data arrives." with dashed Unknown slots and no tags; midnight sun puts "Aurora needs a dark sky. It won’t get dark enough here in the next three days." in the note and each card reads Skip and "No dark hours" with no slots; while checking, each card reads "Checking"; two clear nights within 30 minutes have no Best tag and no Add To Calendar button. Offline with a current forecast puts the red Offline tag and "Updated `HH:MM`" in the grey top. Offline without a forecast and errors show Now's message.

Best tag rule (2026-11-09); with the redesign, southern places apply it only among the nights a storm could reach, when there are any (see [decisions](decisions.md), 2026-11-09): tonight whenever it is clear; otherwise the clear night with the most clear dark time (weather `favorable` inside its darkness windows), with no tag when another clear night is within 30 minutes; with no clear night, the night with the most clear dark time. No tag when no night has any. Planning ratings can't be `promising` yet, because global Kp gives no local activity, so the tag must not depend on the rating.

## What Zorja forecasts (approved 2026-11-12)

Approved 2026-11-12 and built the same day. The API sends the place group (`auroraReach`), each night's southern outlook (`auroraOutlook`) and when current activity started (`now.activeSince`); see [api.md](api.md#what-zorja-forecasts--2026-11-12). 3 Nights already uses its approved lines above. These lines complete the place group's words on Tonight and Now.

Tonight place line (grey top, above the headline):

| Group, tonight's `auroraOutlook` | Place line |
| --- | --- |
| Under the zone | In `<Place>`, aurora shows overhead on most clear, dark nights. |
| Edge | In `<Place>`, aurora often shows low in the northern sky, and overhead on active nights. |
| South, `could_reach` | A storm forecast tonight could bring aurora this far south. |
| South, `not_expected` | No storm is forecast to reach here tonight. Aurora can still come without warning. |
| South, `not_known_yet`, `stale`, `unavailable` | Tonight's storm forecast isn't known yet. |

Now, when aurora is on (`now.activeSince` set):

| Case | Lead |
| --- | --- |
| `activeSinceIsBufferLimited` false | Dark, clear and aurora active overhead since `HH:MM`. |
| `activeSinceIsBufferLimited` true | Dark, clear and aurora active overhead since at least `HH:MM`. |

Now, Quiet Right Now, under the zone and at the edge (a quiet hour doesn't decide the night there): "Dark and clear, but there's little aurora overhead. It often picks up here." In the south the approved lead stays.

## App states and errors

| State | Headline | Lead | Action |
| --- | --- | --- | --- |
| Loading | Checking The Sky. | Looking at darkness, clouds and aurora over `<place>`. | – |
| Forecast expired, next check running or due (no error) | Out Of Date Since `HH:MM`. | Zorja is getting fresh data. Don’t rely on the last forecast until it arrives. | Checking Again At `HH:MM` only while waiting for the request floor (2026-11-13) |
| Offline, forecast still valid | normal screen | Offline tag next to the update time | – |
| Offline, no valid forecast | No Connection. | Your phone is offline, so Zorja can’t check the sky. It tries again when you’re back online. | – |
| `forecast_unavailable`, server error | Can’t Check Right Now. | Something went wrong on Zorja’s side. It isn’t your connection. | Try Again |
| `rate_limited` | Can’t Check Right Now. | Zorja is busy. It tries again at `HH:MM`. | Try Again (off until then) |
| `invalid_request` | Can’t Check Right Now. | Something went wrong on Zorja’s side. It isn’t your connection. | Try Again |

## Location and places

| State | Copy |
| --- | --- |
| Welcome (first launch) | **Know When To Look Up.** Zorja checks darkness, clouds and aurora above you, and tells you whether to go out, wait or skip. · Get Started · Free. No account, no ads, no tracking. |
| Location ask (first launch) | **The Sky Above You.** Zorja checks the sky where you are. · Your location is read once when needed, never tracked. · Zorja sends only a rough area, just to get your forecast. · No account, no history of where you’ve been. · Use My Location · Choose A Place Instead |
| Places from first launch | **Choose A Place.** (Back, search and Pick On Map only) |
| Location off, no place | **Where Are You?** Location is off for Zorja, so it can’t check the sky where you are. Choose a place, or turn location on. · Choose A Place · Turn On Location |
| Location not found | **Can’t Find You.** Your phone couldn’t work out where you are. Try again in a moment, or choose a place. · Try Again · Choose A Place |
| Search, no match | No places match “`<text>`”. Try a nearby town, or pick the spot on the map. · Pick On Map |
| Search, offline | You’re offline, so search can’t look up places. Your saved places still work. |
| Map, offline | **Pinned Spot** `<lat>`° N, `<lon>`° E · You’re offline, so the map may not load and search can’t look up places. You can still save this spot. |
| Map, not moved yet | Move the map to place the pin. (Use This Place is off) |
| Swipe on a place | Remove |
| Map, pinned spot named | **Near `<town>`** `<Country>`, `<lat>`° N, `<lon>`° E (town from Apple's reverse lookup; **Pinned Spot** when there is none) · Move the map to place the pin. (only until the map is moved) |
| **Proposed:** map, search result chosen | **`<result name>`** `<Country>`, `<lat>`° N, `<lon>`° E |
| **Proposed:** map search, no match | No places match “`<text>`”. (Pick On Map is already open, so no button) |
| **Proposed:** My Location in the header | The town of the location read, or "My Location" when it has no name |
| **Proposed:** location permission prompt | Zorja reads your location once, when it checks the sky, and sends only a rough area to get your forecast. |
| **Proposed:** a saved pinned spot | Saved under the name the panel shows: "Near Tromsø", "Pinned Spot" or the search result's name |

## Tips and About (from Figma)

Tips and About have no separate copy review; their wording is the Figma frames', except where marked **Proposed**.

| Place | Copy |
| --- | --- |
| Tips title | **Out There.** |
| Eye timer, idle | 20:00 · **Let Your Eyes Adjust** That’s how long they take to adjust to the dark. · Start Timer |
| Eye timer, running | `MM:SS` left · **Eyes Adjusting** Keep Zorja open and stay away from bright light. · Stop |
| Eye timer, done | 00:00 · **Your Eyes Are Ready** Look up. Faint aurora can look grey at first. · Start Again |
| Tip cards | **Red Screen** Red light keeps your eyes used to the dark. Turn it on in iPhone Settings. · **Use Camera** Faint aurora looks grey to the eye. Use Night mode and hold still. |
| Checklist | **Before You Go** Away from streetlights and town glow · Warm layers, hat and gloves · Ready to stay 30 to 60 minutes |
| About intro | **About Zorja.** Whether it’s worth going out to see the northern lights, and when. Free, with no ads and no account. |
| How It Decides | **Dark Sky** From the sun’s position, including polar night. · **Clear Sky** From the weather forecast for your spot. · **Aurora** About 90 minutes ahead, then a general outlook. |
| Info card | **Guidance, Not A Promise** Experimental and not scientifically validated. It isn’t a measured chance of seeing aurora. |
| Data Sources | **NOAA Space Weather Prediction Center** Aurora activity and the 3-day outlook. · **MET Norway** Weather forecast, the same source as Yr. Licensed under CC BY 4.0. (CC BY 4.0 links to the licence) |
| Privacy | **Location** Read once when needed, never in the background. Only a rough position, within about 1 km, is sent to get your forecast. (**Proposed:** Figma says "about 100 m", from the three-decimal plan replaced on 2026-11-05) · **What’s Kept** Your saved places stay on your phone. Weather for an area is deleted from Zorja’s server within 6 hours. · **No Tracking** No account, no ads and no analytics. |
| **Proposed:** Licences (third accordion, not in Figma) | **Outfit** The typeface, by the Outfit Project Authors. Licensed under the SIL Open Font License 1.1, copied in full below. Then the full `OFL.txt`. |
