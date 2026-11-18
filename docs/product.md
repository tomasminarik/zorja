# Product brief

## Confirmed decisions

App name: Zorja (decided 2026-11-04), used for the repository, Xcode project, bundle ID (`com.tomasminarik.Zorja`), API title, provider User-Agent, Vercel project and Redis database. Native iOS using Swift and SwiftUI, targeting iOS 26 minimum. Android is outside MVP scope. Geography is the launch regions below: Northern Europe, Poland and Canada. NOAA SWPC supplies auroral data; Yr.no is preferred for weather subject to assessment. The private shared repository is [tomasminarik/zorja](https://github.com/tomasminarik/zorja). An Apple Developer Account is available. No domain is required initially. No monetization is planned; the app is a non-commercial personal project. The goal is an App Store release. €0 in infrastructure and all additional project costs is mandatory. No usage/adoption target is defined.

Ownership and coordination rules are in [AGENTS.md](../AGENTS.md).

## Release geography

Launch regions (decided 2026-11-04): Sweden, Norway, Finland, Denmark, Iceland, Faroe Islands, Scotland, Poland and Canada. Sweden, Norway and Finland remain the must-have regions. Ireland, Estonia, Latvia, Lithuania and Germany are not in the launch set and can be added later. Canada is the first region outside Europe; MET Norway's global forecast covers it, but the guidance there still needs the same sanity check as the other regions.

MET Norway request contact: `hello@tomasminarik.com`.

## Purpose

Help users decide whether to go outside, wait for a better viewing window, or skip the current opportunity. Scientific processing belongs in the backend. The app receives structured, understandable guidance.

Combine auroral activity, weather, darkness, geography, and available viewing constraints. High activity alone must never produce favorable viewing guidance. Notifications require an actionable viewing opportunity. Always distinguish measurements, short-term model forecasts, and longer-range planning predictions.

## MVP experience

1. Current conditions and the current or next relevant darkness window: whether viewing is potentially worthwhile, when to try, the main blockers, and the quality of the supporting data.
2. Next three local viewing nights: a planning outlook with activity potential, weather, darkness, and explicit uncertainty. Source coverage may end before the third night; show unavailable portions rather than inventing data.
3. Alerts are deferred from the MVP (see [decisions](decisions.md), 2026-10-13). If they return: opt-in, one selected location per device, no accounts, roughly 15–30 minutes of normal detection delay accepted.

## Design direction (for the Figma work)

Decided 2026-11-04 after the [competitor review](#competitors). Read this before designing a screen.

- **Words, not numbers.** Guidance is a short, honest sentence in plain English, never a percentage, score or "chance" figure. This includes the API's 0–100 overhead signal and global Kp: Kp may appear only as labelled planning context, never as a local rating. English only for the MVP.
- **Say when, why and what would change.** A verdict names the time to try (for example "best from 22:40 to 01:30"), what is holding it back ("clouds clear around 23:00", "too bright until 21:15") and, where useful, what would change it. Write the copy from the API's stable state and reason codes; its English summaries are only a starting point.
- **Make "wait" and "skip" as useful as "go".** "Wait until 23:40" and "skip tonight, Thursday looks better" are first-class answers. The three-night outlook supports the "skip" answer, and it is free.
- **Location.** Asking for the current location is the default because it is simplest. People can skip it and choose a place by search or map pin, and can easily override the location when GPS misbehaves. The map pin screen has its own place and address search and, without GPS, opens on the selected place, else the country from the phone's Region setting (decided 2026-11-05). Location is read once when needed and never tracked.
- **Manage expectations, without honesty theatre.** Help people succeed outside: give it 30–60 minutes, let your eyes adjust to the dark for about 20 minutes, faint aurora often looks grey-green to the eye and shows more colour on a camera, and a "go" is not a promise. No predicted-versus-measured scorecards or accuracy claims.
- **Free and private.** No ads, no account, no subscription and no tracking (see the privacy decision on the [decisions page](decisions.md)).
- **Name.** The app is Zorja.
- **Colour.** Dark only for the MVP, with a very dark blue or black base; light mode is out of the MVP (decided 2026-11-05). White and grey for text and controls, green for the one standout action on a screen, yellow for good conditions, cobalt for darkness and magenta for aurora (decided 2026-11-05; the Foundations page in Figma has the tokens).
- **Type.** Outfit: headings in SemiBold, body in Regular, labels in Medium (decided 2026-11-05).
- **Navigation.** A floating bottom menu with Now, Tonight and 3 Nights; About is an icon in the header and the location chip, on the left of the header, opens a screen for managing places. There is no logo in the app (decided 2026-11-05).
- **Viewing tips.** A screen of cards you can use: an in-app 20-minute timer for letting your eyes adjust, a tip to turn on the iPhone's own red colour filter, a camera tip and a short checklist (decided 2026-11-05). Lock Screen and Dynamic Island timers are post-MVP.

### Competitors

The App Store review of 2026-11-04 found that most aurora apps show a percentage or a 0–100 score, and charge for alerts and multi-night outlooks. Several new 2025–2026 apps already combine darkness, clouds and aurora activity into a verdict for tonight. Zorja stands out by being free with no ads or account, using words instead of numbers, and offering a free three-night outlook. Its main gap is that it has no alerts in the MVP. The most common review complaints were alerts sent in daylight, under cloud or too late; a 0% figure while the aurora was visible; ads; and features moving behind paywalls.

## Scope limits

Location-based ranking of nearby places, route planning, maps, accounts, and a light-pollution database are not committed MVP features. They require separate scope decisions. Location-specific assessments still support a user-selected coordinate without continuous location tracking.

## Acceptance criteria

- Strong auroral activity at noon yields a daylight blocker now and a separately evaluated upcoming window, with no carryover of the current OVATION signal.
- Overcast skies prevent favorable guidance despite strong activity. Missing cloud data yields an unknown weather assessment.
- Continuous darkness yields a bounded current viewing window, not a failed sunset lookup. No qualifying darkness within the search horizon yields an explicit no-window state.
- Twilight is distinguishable from darkness; absence of astronomical darkness does not automatically mean daylight.
- Outages and stale feeds are visible and cannot trigger optimistic notifications. Slower alert checks never extend source freshness or supported forecast coverage.
- Post-MVP only: alert timing is measured separately from APNs acceptance and device delivery. The accepted delay concerns normal detection, not an outage or delivery guarantee.
- Current and future evaluations carry source validity and forecast basis. There is no consumer-facing percentage chance of seeing aurora.
- The app can mock all contract states before the backend is available.

## Decisions still open

Empirical model thresholds. Ireland, Estonia, Latvia, Lithuania and Germany may join the launch regions later.

All decisions in force, including those made in reviews, are listed on the [decisions page](decisions.md).
