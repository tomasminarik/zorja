# Architecture

## Overview

```
iPhone app ──POST /v1/forecast (location in body)──▶ Forecast API (FastAPI)
                                                      │
                     ┌────────────────────────────────┼─────────────────────────┐
                     ▼                                ▼                         ▼
             NOAA aurora grid + Kp             MET Norway weather        Astronomy (local)
                     ▲
       QStash every 10 min ─▶ /internal/collect/ovation (hosted only)
```

The app sends a location and timezone. The backend gathers aurora activity, weather and darkness, runs the experimental assessment and returns the forecast described in [api.md](api.md). All science lives in the backend; the app only presents it.

## Backend parts

All paths are under `backend/src/aurora_backend/`.

| Folder | Role |
| --- | --- |
| `api/` | HTTP routes, request validation, response building (`forecast.py`), hosted composition (`hosted.py`). |
| `providers/` | NOAA and MET fetching and parsing, caching, refresh scheduling and backoff. `store.py` is the local SQLite cache; `redis_store.py` is the hosted Redis cache. |
| `astronomy/` | Sun position, darkness and twilight windows, local nights, including polar night and midnight sun. |
| `evaluation/` | The experimental viewing model and its versioned parameters. |
| `collection/` | The signed collector endpoint used by the hosted schedule. |
| `config/` | Local settings and the strict hosted settings. |

## How a forecast is made

1. **Validate.** FastAPI checks the coordinates and IANA timezone, and each instance limits how many requests it accepts.
2. **Collect.** `ForecastService` gathers the NOAA aurora grid, the global Kp forecast and MET weather through `ProviderClient`, within a response deadline (3 seconds by default). Provider failures become explicit "stale" or "unavailable" inputs; nothing is invented.
3. **Activity.** It is taken from two already-received aurora runs that bracket the current time, at most 20 minutes apart. The value is the lower of their two interpolated values at the location. Global Kp is planning context only.
4. **Respond.** Astronomy and the evaluator produce the current guidance, the next darkness window and three planning nights. The response always says how fresh each source is.

## Local and hosted modes

- **Local (default):** one process with a SQLite cache (`var/providers.sqlite`). Providers are contacted only with `AURORA_PROVIDER_NETWORK=true`. The `development` profile adds synthetic replay routes for UI work.
- **Hosted:** Vercel runs `create_hosted_app`. The cache is Upstash Redis shared by all instances, with per-instance memory caching and monthly allowances. A collector called every 10 minutes keeps aurora data current; outside darkness in the launch regions only every 30 minutes does real work. Hosted forecasts are POST-only. See [hosting.md](hosting.md).

## Privacy

Requests and responses contain the location, so:

- Location travels in a POST body, never in a URL.
- It is never written to application logs, error messages or Redis key names (weather keys are hashed).
- Weather entries in Redis expire within 6 hours, and raw provider data is never used after 48 hours.

Vercel's runtime logs keep request details for 1 hour but never request bodies (checked 2026-11-05, see [Privacy](privacy.md)). The MVP stores no user records.
