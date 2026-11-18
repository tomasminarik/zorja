import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import check_hosted as check  # noqa: E402

from aurora_backend.providers.budgets import SharedLimits  # noqa: E402

NOW = datetime(2026, 11, 11, 15, 0, tzinfo=UTC)


def test_reads_month_usage_and_history_without_coordinates() -> None:
    reads = check.redis_reads(NOW)
    assert reads == [
        ["HGETALL", "{aurora-mvp-v2}:usage:202611"],
        ["HKEYS", "{aurora-mvp-v2}:ovation-history"],
    ]


def test_flat_hash_from_upstash_rest() -> None:
    assert check.as_hash(["forecast_commands", "12", "collector_bytes", "5"]) == {
        "forecast_commands": "12",
        "collector_bytes": "5",
    }
    assert check.as_hash(None) == {}


def test_usage_warns_from_seventy_percent() -> None:
    limits = SharedLimits()
    _, problems = check.usage_problems({"forecast_commands": "251999"}, limits)
    assert problems == []
    _, problems = check.usage_problems({"forecast_commands": "252000"}, limits)
    assert problems == ["forecast_commands is at 70% of its monthly allowance"]
    lines, problems = check.usage_problems({}, limits)
    assert problems == [] and len(lines) == 4


def test_collector_fresh_stale_and_missing() -> None:
    fresh = [str((NOW + timedelta(minutes=40)).timestamp()), "garbage"]
    assert check.collector_problems(fresh, NOW)[1] == []
    edge = [str((NOW - timedelta(minutes=30)).timestamp())]
    assert check.collector_problems(edge, NOW)[1] == []
    stale = [str((NOW - timedelta(minutes=95)).timestamp())]
    assert check.collector_problems(stale, NOW)[1] == [
        "aurora data is stale: newest target time passed 95 min ago"
    ]
    assert check.collector_problems([], NOW)[1] == ["no aurora data is stored in Redis"]
    assert check.collector_problems(None, NOW)[1] == ["no aurora data is stored in Redis"]


def test_forecast_outcomes() -> None:
    ok = {
        "sources": [
            {"provider": "noaa_swpc", "status": "fresh"},
            {"provider": "met_norway", "status": "stale"},
        ]
    }
    assert check.forecast_problems(200, ok)[1] == []
    down = {"sources": [{"provider": "met_norway", "status": "unavailable"}]}
    assert check.forecast_problems(200, down)[1] == ["unavailable sources: met_norway=unavailable"]
    assert check.forecast_problems(503, None)[1] == ["the forecast request answered HTTP 503"]
    assert check.forecast_problems(0, None)[1] == ["the forecast request answered HTTP 0"]
    assert check.forecast_problems(200, {"sources": []})[1] == ["the forecast has no sources"]
