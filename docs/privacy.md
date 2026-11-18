# Privacy

What Zorja stores, where and for how long, as of 2026-11-05. This is the basis for the [privacy policy](privacy-policy.md) and the App Store privacy answers. The rule behind it: collect the minimum, keep nothing unneeded, delete what is no longer relevant.

## Location precision

The app rounds coordinates to **two decimals** before they leave the phone: at most about 0.6 km from the real point (half of 0.01° of latitude, less in longitude at these latitudes). This doesn't lower forecast quality:

- **Cloud:** MET Norway's Nordic model has a 2.5 km grid, and the global model used elsewhere (Canada) about 9 km. A 0.6 km shift stays within the same grid cell or its neighbour.
- **Darkness:** the sun's position changes by a few seconds per kilometre. It doesn't change any time shown in the app.
- **Aurora:** NOAA's grid is 1° (about 110 km), and Kp is worldwide.

Two decimals is also what Apple counts as **coarse** location: Apple defines precise location as three or more decimals. The earlier three-decimal plan (about 100 m) would have counted as precise.

Searching for a place or picking it on the map gives full coordinates on the phone. They are rounded the same way before a forecast request. The hosted server also rounds whatever it receives to two decimals before it asks a provider or writes the shared cache, so a client sending more precise coordinates leaves no more precise trace (2026-11-13).

## What is stored, where and for how long

| What | Where | How long |
| --- | --- | --- |
| Device location | Read once on the phone when the forecast needs it | Not stored. The rounded coordinates live in memory for the request, and next to the last forecast while My Location is selected. |
| Saved places (name and rounded coordinates) and which place is selected | On the phone only | Until you remove the place or delete the app |
| Last forecast | On the phone only | Replaced by the next forecast; deleted with its place, and never shown after it expires (out-of-date screens only show the time of the last update) |
| Eye-adjustment timer | In memory | Nothing stored |
| Calendar event | The iOS calendar, through Apple's own sheet | Zorja keeps nothing; the event is yours to keep or delete |
| Forecast request (rounded coordinates, time zone) | Zorja's server (Vercel, Frankfurt), in memory | Only while the request runs. Never written to logs, error messages, URLs or storage keys. |
| Request details: time, path, status, duration, user agent, IP address (no request or response contents) | Vercel's runtime logs | 1 hour (Vercel's Hobby plan). No log forwarding is set up. |
| IP address and network data | Vercel, for security and abuse prevention | As long as Vercel needs it, under its [privacy notice](https://vercel.com/legal/privacy-notice) |
| Weather for a rounded coordinate, under a hashed key | Upstash Redis (Frankfurt) | At most 6 hours |
| Aurora grids and Kp forecasts | Upstash Redis | Contain no user data; raw provider data is never used after 48 hours |
| Usage counters | Upstash Redis | Contain no user data; reset monthly |
| Rounded coordinates sent to MET Norway | MET Norway (from Zorja's server, not from the phone, so MET never sees the person's IP address) | Under MET Norway's terms |
| Place search text, map views, and the rounded coordinate of a spot to name it (reverse lookup) | Apple (MapKit) | Under Apple's privacy policy |
| Local development cache (SQLite) | Developer machines only | Development and tests only, with synthetic coordinates. It never runs in the released service and is deleted by deleting its file. |

The app contains no analytics, advertising, tracking or crash-reporting SDKs, and no account. Apple's own opt-in crash reports are the only diagnostics. The app links only Apple frameworks (checked 2026-11-12), and its privacy manifest (`ios/Zorja/PrivacyInfo.xcprivacy`) declares the same answers as the table below, plus UserDefaults for the app's own settings (reason CA92.1).

## Vercel check (2026-11-05)

- Runtime logs hold request details and anything the code prints. They don't hold request or response bodies ([Vercel docs](https://vercel.com/docs/logs/runtime)). Requests are POST, so the URL has no coordinates.
- The hosted code never prints or logs requests. The only `print` calls are in the local command-line tool.
- No log drains are configured on the project. The service doesn't use Vercel Web Analytics or Speed Insights: both need code in the app, and there is none.
- Vercel acts as a processor for this data and collects IP addresses and request logs for security ([privacy notice](https://vercel.com/legal/privacy-notice)). The privacy policy says so.

## App Store privacy answers

| Question | Answer |
| --- | --- |
| Data used to track you | None |
| Data linked to you | None |
| Data not linked to you | **Location → Coarse Location**, used for **App Functionality**. The rounded location goes to Zorja's server to get the forecast, and its weather is cached for up to 6 hours. |
| Everything else (contact info, identifiers, usage data, diagnostics, and so on) | Not collected |
| Privacy policy URL | `https://zorja.app/privacy/` (source: [privacy policy](privacy-policy.md)). |

Declaring Coarse Location is the cautious answer. Because of the 6-hour weather cache, "Data Not Collected" would be arguable at best.
