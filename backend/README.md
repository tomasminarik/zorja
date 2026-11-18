# Backend local development

The forecast backend: provider fetching and caching, astronomy, the experimental evaluator and the HTTP API. Use Python 3.13.16 and uv 0.13.0. The hosted service runs at `https://api.zorja.app` (see [hosting](../docs/hosting.md)); regional scientific evaluation has not been done.

`make check` runs formatting, lint, strict typing, the test suite and the contract checker. The Redis tests need a local Valkey or Redis server: they use `backend/.runtime/cache-test/valkey-8.1.11/src/valkey-server` if present, or `REDIS_TEST_SERVER`, and skip otherwise. GitHub Actions runs the same checks on Linux with a Redis server for every pull request that touches the backend, contract or tools ([workflow](../.github/workflows/backend.yml)).

From the repository root:

```sh
cd backend
uv sync --locked
make check
make serve
```

Install the pinned free tool if needed with `python3 -m pip install 'uv==0.13.0'` in an isolated tools environment. uv downloads the pinned Python if missing; it does not require changing system Python. Setup needs public package/interpreter downloads. After setup, provider access is never needed; run `uv run --offline --frozen aurora-backend serve` for dependency-cache-only startup.

Open [liveness](http://127.0.0.1:8000/health/live). [Scenarios](http://127.0.0.1:8000/dev/scenarios) and [daylight replay](http://127.0.0.1:8000/dev/replay/daylight-next-window) require the explicit development profile below; they return 404 in the default MVP. The service binds to host loopback by default. Stop it with Ctrl-C.

- Development profile only: `GET /dev/replay/{scenario}` returns the exact repository example: original timestamp, synthetic coordinate, and limitations. Headers `X-Aurora-Synthetic: true`, `X-Aurora-Mode: offline`, and private no-store make the mode explicit. It never accepts arbitrary forecast coordinates or rewrites times. `error-503` returns HTTP 503 with Retry-After.
- `GET /v1/forecast?latitude=59.3293&longitude=18.0686&timezone=Europe%2FStockholm` computes useful degraded guidance by default. Opt-in provider network mode uses the real cache/client. It never substitutes UI mock data. Errors are structured 400/429/503 with request IDs.
- `POST /v1/forecast` accepts the same three values as a JSON body, with no query string; the body is limited to 1024 bytes and three seconds to read. It shares GET's evaluator, admission pool, schemas and error/retry behavior. POST alone does not prove hosted log privacy; the hosted log check is in [privacy](../docs/privacy.md).
- `/health/live`, `/health/ready`, and `/health/providers` separate process liveness, configured pipeline readiness, and last-request source status. `/metrics` exposes aggregate counters without personal labels.
- `/docs` and `/openapi.json` serve the published frozen 1.0.0 forecast contract. The v1 interface is frozen at 1.0.0; current activity uses the experimental retained-bracket model (`visibility-v0.2-bracket-prototype`), which is not scientifically calibrated. See [the API guide](../docs/api.md) for exact null, freshness, deadline and error semantics.

Print a synthetic fixture without starting the server:

```sh
uv run --offline --frozen aurora-backend replay morning-finished-night
```

## Forecast-only MVP runtime

`AURORA_PROFILE=mvp` is the default, including the offline container. It omits the HTTP `/dev/*` replays. The forecast endpoint, health checks and aggregate metrics remain available. `/openapi.json` projects the unchanged full contract onto `/v1/forecast`; forecast schemas are preserved. MVP does not require the fixture directory to exist.

For local synthetic HTTP replay only:

```sh
AURORA_PROFILE=development uv run --offline --frozen aurora-backend serve
```

The standalone CLI `replay` remains an explicit offline tool. Live provider access still requires `AURORA_PROVIDER_NETWORK=true`. The default MVP profile does not enable hosted storage or scheduling. The hosted factory is separate; see [hosting](../docs/hosting.md).

## Configuration

See `.env.example`. Values are read from the shell environment; a `.env` file is not implicitly loaded. Supported keys:

| Key | Default and behavior |
| --- | --- |
| AURORA_PROFILE | `mvp`; explicit `development` enables HTTP synthetic replay |
| AURORA_MODE | `offline`; legacy local-development setting, production modes rejected |
| AURORA_PROVIDER_NETWORK | `false`; explicit `true` enables real provider requests |
| AURORA_CACHE_PATH | `var/providers.sqlite`; ignored local single-owner cache |
| AURORA_RESPONSE_DEADLINE | `3`; 0.01–10 seconds after admission, including CPU evaluation |
| AURORA_CONTRACT_PATH | checkout `api/openapi.json`; set explicitly for an installed wheel |
| AURORA_HOST | `127.0.0.1`; also `::1`, or `0.0.0.0` with explicit network opt-in |
| AURORA_ALLOW_NETWORK | `false`; `true` required for `0.0.0.0` |
| AURORA_PORT | `8000`; integer 1024–65535 |
| AURORA_FIXTURE_DIR | checkout's `api/examples`; required for development HTTP replay, optional in MVP |

Unknown `AURORA_` keys fail startup, as do invalid paths, unsupported mode, and unsafe binding. No external service credentials are needed to start. Query access logging is disabled by the CLI. Network opt-in is only for deliberate local device/container testing; it does not make this prototype production-ready. The service has global local limits of 60 valid forecast requests/minute and four active evaluations; production distributed abuse control/authentication remains future work.

## Reproducibility and checks

Direct dependencies are exactly pinned in `pyproject.toml`; `uv.lock` locks transitive versions and hashes. Timezone conversion reads the locked `tzdata` package directly, avoiding host-specific timezone rules. The clock is injectable. Tests cover calendar boundaries/DST, explicit missing darkness coverage, validation, original replay semantics, mock invariants, and full OpenAPI/JSON Schema validation. They do not establish scientific accuracy.

`requirements.lock` is a hash-enforced runtime export for the container. After an intentional dependency change, regenerate it with:

```sh
uv lock
uv export --frozen --no-dev --no-emit-project --output-file requirements.lock
```

Astral is used for offline solar geometry; `tools/check_solar_reference.py` (below) compares it with independent JPL reference values. HTTPX implements provider and Redis transport. Each dependency keeps its own licence.

## Opt-in provider diagnostics

The server and tests remain offline. To inspect actual NOAA and MET data explicitly:

```sh
uv run --frozen aurora-backend providers --allow-provider-network
```

Default weather coordinates are the public Stockholm city centre. Optional `--latitude`, `--longitude`, and `--cache-path` arguments select the weather point and local cache. Do not add private locations to committed fixtures. The default cache is ignored `var/providers.sqlite`. Only one process may own a cache file at a time. The command makes at most one refresh per requested product, respecting persisted Expires and backoff; it starts no polling worker. Diagnostics omit coordinates, raw bodies, and viewing guidance. Degraded sources are represented in JSON, so inspect `state`/`refreshError` rather than relying on process exit alone.

The command requires the explicit network flag, uses the confirmed identifying MET User-Agent, and creates no external account or paid resource. Do not repeatedly delete the cache to force refreshes. Provider rules and limitations are in [data sources](../docs/data-sources.md); recorded provider fixtures are in `tests/fixtures/providers`. The opt-in local HTTP pipeline uses this same client; no polling worker is added.

## Portable container

From repository root with an existing compatible Docker installation:

```sh
docker build -f backend/Dockerfile -t aurora-offline .
docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /app/var:rw,noexec,nosuid,size=16m,uid=10001,gid=10001,mode=0700 \
  -p 127.0.0.1:8000:8000 aurora-offline
```

The base image is pinned by exact Python version and multi-platform manifest digest; dependencies install with hashes. It runs as UID 10001 with no secret files in the allowlisted build context. Container binding is internal `0.0.0.0`; publish only to host loopback as shown. The tmpfs is an ephemeral smoke-test database and loses registrations on container removal; durable operation requires a private persistent volume owned by UID 10001. No container runtime was available when the container was added: base-image registry availability was verified and equivalent fresh runtime installation was tested, but the Docker image was **not built or executed**. Do not claim container validation until these commands run successfully.

Docker execution remains unverified. The hosted service does not use this container; it runs on Vercel (see [hosting](../docs/hosting.md)).

## Offline astronomy

`astronomy.solar.solar_altitude(location, aware_time)` returns airless Sun-centre altitude. `astronomy.windows.calculate_windows(location, aware_time)` returns the current altitude/category, bounded 72-hour upcoming window, its first 24-hour detail, and three local-night periods with disjoint darkness windows. It uses the existing provisional -12° threshold. Errors propagate; they are not no-darkness results. These internal dataclasses are not forecast API responses or aurora recommendations.

Run `uv run --offline --frozen python tools/check_solar_reference.py` to print comparison measurements from preserved JPL reference captures. Re-fetching is optional via `uv run --frozen python tools/capture_solar_reference.py --allow-reference-network`; it makes 21 fixed public-location requests and replaces the reference captures, so review resulting changes. Tests and normal astronomy operation need no network or ephemeris download.

## Offline experimental evaluator

`evaluation.engine.assess` evaluates a point with explicit normalized provider inputs and altitude. `evaluate` composes supplied astronomy windows with segmented upcoming/planning results; `Evaluation.astronomy` retains date labels and no-window metadata. The forecast service serializes these internal results into the published forecast contract.

Run `.venv/bin/python tools/check_evaluator_replay.py` from `backend` for the preserved public-city provider replay and candidate spatial comparison. This uses no network, personal locations, credentials or additional dependency. This command intentionally reports the original exact-instant model (`visibility-v0.1-prototype`) as a baseline; current parameters are in `src/aurora_backend/evaluation/model.py` and [forecast-model.md](../docs/forecast-model.md). The current runtime uses retained brackets (two received aurora runs at most 20 minutes apart); Kp context still does not imply local planning potential.


## Forecast service and recorded HTTP replay

```sh
# Real providers are an explicit local opt-in; defaults remain network-free.
AURORA_PROVIDER_NETWORK=true uv run --offline --frozen aurora-backend serve
# Existing public-city captures through normalization and the real HTTP endpoint:
uv run --offline --frozen aurora-backend forecast-replay stockholm
```

Run `forecast-replay` from `backend`, or supply `--capture-dir` explicitly. The recorded response preserves historical timestamps; it does not refresh providers. The committed [replay artifact](tests/fixtures/replays/four-cities-replay.json) covers four public cities. Additional positive exact-instant cases are deliberately synthetic tests, not empirical validation. The local server starts no worker, APNs integration, external account or paid resource.


## Regenerate frontend examples

From `backend`, run `uv run --offline --frozen python tools/generate_api_examples.py`. All 19 active UI examples are reproducible: 18 use synthetic normalized inputs through the real evaluator/serializer, and one is a synthetic failure through the real HTTP error path. Generation is network-free with fixed inputs; it is not a provider capture or scientific calibration. Fixture tests compare values exactly except float `solarAltitudeDegrees`, which may differ by at most 1e-10 degrees to accommodate Linux/Mac rounding. Do not regenerate fixtures to hide differences. Full schema/temporal validation remains required. The prior unimplemented darkness-unavailable 200 example is archived outside the active fixture directory; astronomy failure currently yields structured 503. See [api.md](../docs/api.md) for the source and Kp fields.


## Frozen interface and explicit activity coverage

The final v1 interface and baseline are `api/openapi.json` and `api/frozen/v1-openapi.json`. Activity metadata exposes opaque matching/spatial policy and nullable supportedInterval; the current retained-bracket model ("Option A") returns nonzero intervals for qualifying retained brackets. A single grid cannot support current guidance. That model, versioned as `visibility-v0.2-bracket-prototype`, replaced observation-age rejection with publication/target freshness and a 20-minute maximum bracket gap. It is experimental and not scientifically validated. Compatibility tests guard the reviewed shape while allowing optional extensions. Optional upcomingActivityInstant represents the newest future point without rewriting the existing darkness window.

Run `.venv/bin/python tools/check_activity_coverage.py` for the checksum-verified offline timing audit and regional replay at capture/target times. Its counterfactual age budgets are arithmetic only, never accepted scientific parameters. The audit preserves the legacy model for comparison; the current retained-bracket rule is enabled experimentally and is not scientifically validated.


## Project-local toolchain

The pinned Python 3.13.16 and uv 0.13.0 can live under ignored `backend/.runtime/`, with the virtual environment pointing to that project-local runtime. Make uses the local uv binary when present, otherwise the uv on PATH.

From `backend/`, these commands set it up with a working bootstrap `uv` and `python3` available (downloads require network access, no paid services):

```sh
uv pip install --python python3 --target .runtime/tooling uv==0.13.0
UV_PYTHON_INSTALL_DIR="$PWD/.runtime/python" .runtime/tooling/bin/uv python install 3.13.16
.runtime/tooling/bin/uv venv --allow-existing --python .runtime/python/cpython-3.13.16-macos-aarch64-none/bin/python3.13 .venv
.runtime/tooling/bin/uv sync --frozen
make check
```

The explicit interpreter path above is for Apple Silicon macOS; use the installed platform-specific path on another host. `--allow-existing` preserves installed packages while fixing interpreter links; frozen sync reconciles them with the lockfile. Keep interpreter/tooling directories out of temporary cleanup locations.

## Hosted mode

`aurora_backend.api.hosted.create_hosted_app` builds the forecast-only hosted app: Upstash Redis as the shared cache (`providers/redis_store.py`), monthly allowances, POST-only forecasts and an optional signed collector. It never falls back to SQLite. Configuration, limits, the bundle preparer and the deploy steps are in [hosting](../docs/hosting.md).
