# Hosting

Status: **live at `https://api.zorja.app`** since 2026-11-11, with the aurora collector on. Before promotion, the first build answered the smoke checks (health 200, GET 405, empty POST 400) and two synthetic forecasts for a Tromsø city-centre point: both 200 with fresh NOAA and MET Norway sources, 2.8 s on a cold instance and 0.8 s warm. The runtime log had no errors and showed paths only. Upstash's console counted 32 commands and 12 KB that day, which is the measured profile of a first-ever forecast (26) plus a warm one (6); cost $0.00. `api.zorja.app` is a Cloudflare CNAME (DNS only). `zorja-api.vercel.app` also answers publicly, because Vercel treats the production domain as public. Unsigned and wrongly signed collector calls answer 401. One QStash schedule (EU region, `*/10 * * * *`, 1 retry, body `{"task":"ovation"}`) calls `https://api.zorja.app/internal/collect/ovation`.

## What runs where

- **Forecast API:** the FastAPI app (`aurora_backend.api.hosted.create_hosted_app`) runs as a Vercel Hobby function in Frankfurt (`fra1`). It only accepts `POST /v1/forecast`; GET gets a fixed 405.
- **Shared cache:** an Upstash Free Redis database holds provider data so instances share it and providers are not asked too often.
- **Aurora collector:** a signed QStash call to `POST /internal/collect/ovation` every 10 minutes refreshes the NOAA aurora grid (on since 2026-11-11). A call only does real work when it is dark, or will be within 90 minutes, somewhere in the launch regions; otherwise only the calls at :00 and :30 do (see [Collector cadence](#collector-cadence)).
- **Website:** `zorja.app` is the static `site/` folder, served by Cloudflare Workers static assets (free, `wrangler.jsonc`, no Worker script, no workers.dev address). Workers Builds deploys every push to `main` with `npx wrangler deploy --config wrangler.jsonc`; live since 2026-11-12. Builds for other branches are turned off in the dashboard (Settings, Builds, Previews Base), so pull requests get no preview build or preview URL. Email Routing forwards `touch@zorja.app`. `www.zorja.app` is a second custom domain on the same Worker, and a Single Redirect rule on the zone (`https://www.*` → `https://${1}`, 301) sends it to `zorja.app` with the path and query. Its pages call `POST /v1/forecast` from the browser; the API answers CORS for `https://zorja.app` only, and a preflight costs one function call but no Redis command.
- **Providers:** NOAA SWPC (aurora grid, Kp forecast) and MET Norway (weather), called with the project's contact User-Agent.

## How the shared cache works

Code: `backend/src/aurora_backend/providers/redis_store.py`.

- **Memory first.** Each server instance remembers what it last read or wrote. It asks Redis only when an entry is due for refresh or past its reuse window: aurora data 15 minutes, Kp 60 minutes, weather until MET's `Expires`.
- **Aurora grid stored once, compactly.** NOAA's grid file is about 925 KB of text: 65,160 points in a fixed order. It is stored as its short header and tail plus one byte per value, about 5 KB after compression instead of about 220 KB, and rebuilt byte for byte when read (`providers/compact_grid.py`). Readers still check the rebuilt bytes against the hash of NOAA's original file, so source IDs and validation are unchanged. A file that cannot be rebuilt exactly (a different layout or decimal values) is stored the old way. The grid is stored once under its content hash; metadata and the 3-hour run history only point to it, so it is sent only when NOAA publishes a new one. NOAA rewrites the file about every 1.5 minutes but publishes new data every 5; identical rewrites are recognised by their hash and cost no upload.
- **Simple commands.** There are no Lua scripts. Each round trip is one batched request of plain Redis commands, and a short lease stops two instances fetching the same thing at once.
- **Expiry.** Weather entries expire within 6 hours. Raw provider data is never kept or used beyond 48 hours. Redis key names never contain coordinates.
- **Provider refusals.** When a provider refuses (403/429), a shared cooldown stops every instance from calling it until the cooldown ends.

Measured locally against Valkey 8.1.11 with recorded provider data (tests `test_forecast_command_and_byte_profile` and `test_steady_collection_every_ten_minutes_profile`, 2026-11-04):

| Case | Redis commands | Data |
| --- | ---: | ---: |
| Warm forecast (same instance, data cached) | 6 | ~1 KB |
| Forecast on a fresh instance, data already in Redis | 11 | ~11 KB (was ~225 KB) |
| First forecast ever (everything fetched) | 26 | ~35 KB |
| One collector run with a new grid | 17 | ~12 KB (was ~220–450 KB) |

A collector run with a new grid used about 160 ms of CPU on a 2026 Mac (parsing NOAA's file once and compacting it); Vercel's CPUs may be slower. A call that is not due uses no Redis and almost no CPU.

The previous Lua design needed about 86 commands for a warm forecast.

## Monthly allowances

Every command and byte sent to Redis is added to one monthly usage record per lane. An instance whose lane is over its allowance stops using Redis until the next UTC month (or for 24 hours, whichever is sooner) and answers 503.

| Lane | Commands | Bandwidth |
| --- | ---: | ---: |
| Forecasts | 360,000 | 8 GB |
| Collector | 90,000 | 0.5 GB |
| Upstash Free limit | 500,000 | 10 GB |

The gap to the Upstash limit covers commands that are sent but not yet charged, for example by an instance that stops before its next charge. Forecasts are also limited to 60 per minute across all instances, and 60 per minute and 4 at a time per instance. A refused forecast costs no Redis command once its instance has seen that minute's shared limit reached, so a flood of requests cannot spend the allowance on refusals.

**Per-IP firewall rule (set by hand in Vercel).** Admitted forecasts still cost about 6–11 commands each, so one address must not be able to take the whole shared limit for days. The project has one WAF rate-limit rule (Hobby allows one, with 1,000,000 allowed requests included and no billing): Firewall → Configure → New Rule; if Request Path equals `/v1/forecast` and Method equals `POST`, then Rate Limit, Fixed Window, 10 minutes, 60 requests, key IP, action Too Many Requests (429). 60 in 10 minutes leaves room for many phones behind one mobile-network address and for flipping through places, and holds one address to about 36 commands a minute: about a week to use up the forecast allowance alone, while `Hosted check` emails at 70%. Vercel answers the 429 itself, without the API's JSON body or `Retry-After`; the app and the site show it as "busy", like the API's own 429. The rule is not in this repository; check it in the Vercel dashboard.

The collector needs at most 4,464 runs in a 31-day month × 17 commands ≈ 76,000 commands and about 51 MB. Forecast capacity depends on how often requests land on a warm instance. With the compact grid, commands run out before bandwidth: expect about **33,000–60,000 forecasts a month** (360,000 ÷ 11 when every request hits a fresh instance, ÷ 6 when all are warm), up from 25,000–45,000 before the compact grid. These are estimates from local measurements, not hosted billing.

## Collector cadence

Code: `backend/src/aurora_backend/collection/cadence.py`.

- **One schedule, every 10 minutes.** That is 144 QStash messages a day, well under the Free plan's 1,000 (retries count as messages).
- **Due or not.** A call does real work when the Sun is at or below −12° (the model's viewing darkness) now or within the next 90 minutes at any of 24 reference points across the launch regions, sampled every 10 minutes. Otherwise only every third call (:00 and :30 UTC) works. A call that is not due answers `200 not_due` without touching Redis or NOAA.
- **Why 90 minutes.** Each NOAA file forecasts about 60 minutes ahead, and current activity needs two received runs at most 20 minutes apart that bracket "now". The files that describe the start of darkness are therefore fetched about an hour before it.
- **What it means in practice.** The launch regions span from western Canada to eastern Finland, so it is dark somewhere almost all the time: a 2026 simulation gives 100% of calls due from November to January, 93–98% in March and October and 77–90% from April to September. The 30-minute mode mainly saves summer daytime calls.
- **Delay.** With a call every 10 minutes and new NOAA data every 5, new aurora data reaches the shared cache within about 10–15 minutes during darkness. Forecasts also refresh the grid themselves when it is older than 15 minutes.

## Existing accounts and resources

- **Upstash Redis:** database `zorja` (endpoint unchanged), Free, Frankfurt, TLS, eviction off. Namespace `aurora-mvp-v2`.
- **Vercel:** Hobby project `zorja-api` (domains `api.zorja.app` and `zorja-api.vercel.app`). FastAPI, `fra1`, 15-second timeout, Vercel Authentication on, previews disabled. The Redis URL and token are stored as Production-only secrets. The Git link to `tomasminarik/zorja` exists, but automatic builds are skipped (Ignored Build Step `exit 0`).
- **Domain:** `zorja.app` at Cloudflare Registrar, a personal yearly cost (decisions, 2026-11-11). DNS stays at Cloudflare; `api` is a CNAME to Vercel with the proxy off.
- **QStash:** Free, EU region, one schedule every 10 minutes with 1 retry.

Rules:

- **Upstash:** never add a card. It converts every database on the account to pay-as-you-go.
- **Namespace:** never change the namespace or delete usage records to regain allowance.
- **Previews:** never give previews production secrets.
- **Collection:** keep the single schedule; pause it first when rolling back.

Keys written by the old Lua design, if the staged build wrote any, are not read by the new code. They can be left alone.

## Configuration

The hosted entrypoint accepts only these variables. Anything else starting with `AURORA_` stops startup.

| Variable | Meaning |
| --- | --- |
| `AURORA_HOSTED_REDIS_URL` | Required. Upstash REST root, `https://….upstash.io`. |
| `AURORA_HOSTED_REDIS_TOKEN` | Required. Upstash REST token (secret). |
| `AURORA_HOSTED_NAMESPACE` | Required. `aurora-mvp-v2`. |
| `AURORA_HOSTED_CONTRACT_PATH` | Set by the bundle to its copy of `api/openapi.json`. |
| `AURORA_HOSTED_RESPONSE_DEADLINE` | Optional, default 3 seconds. |
| `AURORA_HOSTED_COLLECTION_ENABLED` | Optional, default false. |
| `AURORA_HOSTED_COLLECTOR_DESTINATION` | Only with collection: the exact HTTPS callback URL. |
| `AURORA_HOSTED_SIGNING_CURRENT` / `_NEXT` | Only with collection: QStash signing keys. |

Prepare a deployable bundle without touching any account (the output folder must not exist yet):

```sh
uv run --offline --directory backend --frozen python tools/prepare_vercel_bundle.py --output .runtime/vercel-candidate-YYYY-MM-DD
```

## Deploying a new build

Vercel skips Git builds, so a merged backend change goes live by hand, from the repository root:

```sh
uv run --offline --directory backend --frozen python tools/prepare_vercel_bundle.py --output ../.runtime/vercel-candidate-YYYY-MM-DD
cd .runtime/vercel-candidate-YYYY-MM-DD
vercel link --yes --project zorja-api && rm -f .env.local
vercel deploy --prod --skip-domain --yes
```

`vercel link` copies the project's environment into `.env.local`; delete it before deploying so no secret is uploaded or left on disk. Check the staged URL (health 200, GET `/v1/forecast` 405, empty POST 400, one synthetic forecast), then `vercel promote <staged URL>` and repeat the synthetic forecast on `api.zorja.app`.

## Release checks

1. **Validate each build.** Stage it, run a few synthetic forecasts, and check that Upstash's own usage counter matches the app's usage record (first done 2026-11-11).
2. **Privacy.** Done 2026-11-05: Vercel's runtime logs keep no request or response bodies, and no log drains are set up (see [Privacy](privacy.md)). Re-check if logging or tracing settings change.
3. **Vercel allowances.** Checked 2026-11-11 against Vercel's Hobby page: per month 1,000,000 function invocations, 4 hours of active CPU, 360 GB-hours of provisioned memory, 100 GB fast data transfer and 1,000,000 CDN requests. Hobby has no billing: a resource that runs out pauses until 30 days have passed. Active CPU is the tightest: the collector needs roughly 15–30 minutes a month, and forecast CPU still has to be read from the usage page after real requests.
4. **Collector.** On since 2026-11-11: collection is enabled in the bundle, and one QStash schedule runs every 10 minutes (`*/10 * * * *`) with at most one retry. QStash Free (checked 2026-11-11) allows 1,000 messages a day and 10 schedules and lists no overage charge; going over its soft limit leads to 429s, not a bill. The callback uses the public custom domain.
5. **Monitoring.** Added 2026-11-11: the GitHub workflow `Hosted check` (`backend/tools/check_hosted.py`) runs every 6 hours. It reads this month's usage record and the newest aurora run with Upstash's read-only token (2 commands, outside the app's own allowance), then asks for one synthetic forecast. It fails, and GitHub emails the repository owner, when the forecast does not answer 200 or a source is unavailable, when the newest aurora run's target time passed more than 30 minutes ago, or when a lane reaches 70% of its monthly allowance. It prints only status lines and percentages, since the repository is public. Vercel's own emails cover its Hobby limits, including active CPU; Upstash has no free usage alerts, which is why the check reads Redis. On a public repository GitHub turns scheduled workflows off after 60 days without commits, so re-enable it if that happens.

Rollback: pause the QStash schedule first, then remove the deployment. Revoke the Redis token if it may have leaked.
