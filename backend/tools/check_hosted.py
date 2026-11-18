"""Scheduled check of the hosted service: is it answering, is the aurora collector
keeping data fresh, and how much of the monthly Redis allowance is used.

Run by .github/workflows/hosted-check.yml. Exits 1 when something needs attention,
so GitHub emails the repository owner. Prints only status lines and percentages:
no tokens, no response bodies.

Environment:
  ZORJA_API_URL                  default https://api.zorja.app
  UPSTASH_READONLY_URL           Upstash REST root of the `zorja` database
  UPSTASH_READONLY_TOKEN         its read-only REST token
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from typing import Any

from aurora_backend.providers.budgets import SharedLimits

NAMESPACE = "aurora-mvp-v2"
# Synthetic, public point (Tromsø city centre), already rounded like the app does.
PROBE = {"latitude": 69.65, "longitude": 18.96, "timezone": "Europe/Oslo"}
WARN_SHARE = 0.7
# The newest aurora run forecasts about an hour ahead. If even its target time is
# this far in the past, nothing new has arrived for well over an hour.
COLLECTOR_STALE_AFTER = timedelta(minutes=30)


def redis_reads(now: datetime) -> list[list[str]]:
    root = "{" + NAMESPACE + "}:"
    return [
        ["HGETALL", root + "usage:" + now.strftime("%Y%m")],
        ["HKEYS", root + "ovation-history"],
    ]


def as_hash(result: Any) -> dict[str, str]:
    if isinstance(result, dict):
        return {str(k): str(v) for k, v in result.items()}
    if isinstance(result, list):  # Upstash REST returns HGETALL as a flat list
        return {str(result[i]): str(result[i + 1]) for i in range(0, len(result) - 1, 2)}
    return {}


def usage_problems(usage: dict[str, str], limits: SharedLimits) -> tuple[list[str], list[str]]:
    lines, problems = [], []
    for lane in ("forecast", "collector"):
        for unit in ("commands", "bytes"):
            name = f"{lane}_{unit}"
            used = int(usage.get(name, "0") or 0)
            cap = getattr(limits, name)
            share = used / cap
            lines.append(f"{name}: {share:.1%} of this month's allowance")
            if share >= WARN_SHARE:
                problems.append(f"{name} is at {share:.0%} of its monthly allowance")
    return lines, problems


def collector_problems(history_fields: Any, now: datetime) -> tuple[list[str], list[str]]:
    targets = []
    for field in history_fields if isinstance(history_fields, list) else []:
        try:
            targets.append(datetime.fromtimestamp(float(field), UTC))
        except (TypeError, ValueError, OverflowError):
            continue
    if not targets:
        return ["aurora data: none stored"], ["no aurora data is stored in Redis"]
    newest = max(targets)
    age = now - newest
    line = f"aurora data: newest run targets {newest:%Y-%m-%d %H:%M} UTC"
    if age > COLLECTOR_STALE_AFTER:
        minutes = int(age.total_seconds() // 60)
        return [line], [f"aurora data is stale: newest target time passed {minutes} min ago"]
    return [line], []


def forecast_problems(status: int, body: Any) -> tuple[list[str], list[str]]:
    if status != 200:
        return [f"forecast: HTTP {status}"], [f"the forecast request answered HTTP {status}"]
    sources = body.get("sources", []) if isinstance(body, dict) else []
    states = [f"{s.get('provider')}={s.get('status')}" for s in sources if isinstance(s, dict)]
    line = "forecast: HTTP 200, sources " + ", ".join(states)
    down = [s for s in states if s.endswith("=unavailable")]
    if not sources:
        return [line], ["the forecast has no sources"]
    if down:
        return [line], ["unavailable sources: " + ", ".join(down)]
    return [line], []


def post_json(url: str, payload: Any, token: str | None = None) -> tuple[int, Any]:
    headers = {"Content-Type": "application/json", "User-Agent": "zorja-hosted-check"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, json.dumps(payload).encode(), headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return 0, None


def main() -> int:
    api = os.environ.get("ZORJA_API_URL", "https://api.zorja.app").rstrip("/")
    redis_url = os.environ.get("UPSTASH_READONLY_URL", "").rstrip("/")
    redis_token = os.environ.get("UPSTASH_READONLY_TOKEN", "")
    now = datetime.now(UTC)
    lines: list[str] = []
    problems: list[str] = []

    # Redis first, so this run's own forecast cannot refresh the aurora data it checks.
    if redis_url and redis_token:
        status, results = post_json(redis_url + "/pipeline", redis_reads(now), redis_token)
        if status != 200 or not isinstance(results, list) or len(results) != 2:
            problems.append(f"could not read Redis (HTTP {status})")
        else:
            usage, history = (r.get("result") if isinstance(r, dict) else None for r in results)
            for found in (
                usage_problems(as_hash(usage), SharedLimits()),
                collector_problems(history, now),
            ):
                lines += found[0]
                problems += found[1]
    else:
        problems.append("Upstash read-only URL or token is not configured")

    status, body = post_json(api + "/v1/forecast", PROBE)
    found = forecast_problems(status, body)
    lines += found[0]
    problems += found[1]

    for line in lines:
        print(line)
    for problem in problems:
        print("PROBLEM: " + problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
