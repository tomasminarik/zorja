"""Scientific safety boundaries, not empirical calibration."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta
from functools import partial

import pytest

from aurora_backend.astronomy.windows import calculate_windows
from aurora_backend.domain.types import Interval, Location
from aurora_backend.evaluation.engine import assess, evaluate
from aurora_backend.evaluation.model import LEGACY_PARAMETERS, Parameters
from aurora_backend.evaluation.spatial import horizon_candidate, local_signal
from aurora_backend.providers.models import (
    GridPoint,
    KpBin,
    Product,
    ProviderResult,
    Snapshot,
    SourceHealth,
    SourceState,
    WeatherSample,
)

AT = datetime(2026, 10, 12, 21, tzinfo=UTC)
# Preserve the original prototype scenario matrix alongside new default-model tests.
assess = partial(assess, parameters=LEGACY_PARAMETERS)
evaluate = partial(evaluate, parameters=LEGACY_PARAMETERS)
LOCATION = Location(latitude=60.0, longitude=20.0, timezone="Europe/Stockholm")


def result(snapshot: Snapshot, state: SourceState = SourceState.FRESH) -> ProviderResult:
    return ProviderResult(snapshot, SourceHealth(state, None, False, AT, AT, AT))


def aurora(value: float = 40) -> ProviderResult:
    return result(
        Snapshot(
            "aurora",
            Product.OVATION,
            "NOAA SWPC",
            None,
            AT - timedelta(minutes=10),
            AT,
            AT,
            AT,
            AT,
            (),
            None,
            grid=(GridPoint(20, 60, value),),
        )
    )


def weather(cloud: float | None = 10) -> ProviderResult:
    return result(
        Snapshot(
            "weather",
            Product.WEATHER,
            "MET Norway",
            AT,
            None,
            None,
            AT,
            AT - timedelta(hours=1),
            AT + timedelta(hours=1),
            (),
            (20, 60),
            weather=tuple(
                WeatherSample(
                    AT + timedelta(hours=i),
                    cloud,
                    None,
                    None,
                    None,
                    None,
                    timedelta(hours=1) if i < 1 else None,
                )
                for i in (-1, 0, 1)
            ),
        )
    )


def run(cloud: float | None = 10, **kwargs: object):  # type: ignore[no-untyped-def]
    return assess(
        LOCATION, AT, AT, altitude=-15, ovation=(aurora(),), weather=weather(cloud), **kwargs
    )  # type: ignore[arg-type]


@pytest.mark.parametrize(
    "cloud,rating",
    [
        (0, "promising"),
        (29.99, "promising"),
        (30, "limited"),
        (70, "limited"),
        (70.01, "unfavorable"),
    ],
)
def test_cloud_edges(cloud: float, rating: str) -> None:
    assessment = run(cloud)
    assert assessment.rating == rating
    assert assessment.confidence == "low"
    assert assessment.refresh_after == AT
    assert assessment.weather.value == cloud


@pytest.mark.parametrize(
    "altitude,code", [(0, "daylight"), (20, "daylight"), (-11.99, "twilight_too_bright")]
)
def test_daylight_and_twilight_precedence(altitude: float, code: str) -> None:
    assessment = assess(
        LOCATION,
        AT,
        AT,
        altitude=altitude,
        ovation=(aurora(),),
        weather=weather(),
        later_candidate=AT + timedelta(hours=2),
    )
    assert (assessment.rating, assessment.action) == ("unfavorable", "wait")
    assert any(r.code == code and r.effect == "blocker" for r in assessment.reasons)


def test_threshold_and_missing_cloud() -> None:
    assert (
        assess(LOCATION, AT, AT, altitude=-12, ovation=(aurora(),), weather=weather()).rating
        == "promising"
    )
    assessment = run(None)
    assert assessment.rating == "unknown"
    assert assessment.weather.state == "missing"


def test_known_cloud_blocker_with_missing_activity() -> None:
    assessment = assess(LOCATION, AT, AT, altitude=None, weather=weather(100))
    assert assessment.rating == "unfavorable"
    assert assessment.action == "skip"
    assert assessment.darkness.state == "unavailable"
    assert assessment.activity.state == "unavailable"


def test_stale_history_never_blocks_or_encourages() -> None:
    old = weather(100)
    old = replace(old, health=replace(old.health, state=SourceState.STALE))
    assessment = assess(LOCATION, AT, AT, altitude=-15, ovation=(aurora(),), weather=old)
    assert assessment.rating == "unknown"
    assert assessment.weather.state == "stale"
    assert not any(r.code == "cloud_obstruction" for r in assessment.reasons)


@pytest.mark.parametrize("offset", [-1, 1, 3600])
def test_exact_temporal_matching(offset: int) -> None:
    a = aurora()
    assert a.snapshot is not None
    a = replace(a, snapshot=replace(a.snapshot, forecast_at=AT + timedelta(seconds=offset)))
    assessment = assess(LOCATION, AT, AT, altitude=-15, ovation=(a,), weather=weather())
    assert assessment.action == "check_later"
    assert assessment.activity.state == "not_covered"


def test_retained_snapshot_and_stale_cutoff() -> None:
    a = aurora()
    assert a.snapshot is not None
    future = replace(
        a, snapshot=replace(a.snapshot, id="future", forecast_at=AT + timedelta(minutes=10))
    )
    assessment = assess(LOCATION, AT, AT, altitude=-15, ovation=(future, a), weather=weather())
    assert assessment.action == "try_now"
    assert assessment.activity.source_id == "aurora"
    stale = replace(a, snapshot=replace(a.snapshot, observed_at=AT - timedelta(minutes=20)))
    assert (
        assess(LOCATION, AT, AT, altitude=-15, ovation=(stale,), weather=weather()).activity.state
        == "stale"
    )


def test_weak_overhead_is_unknown_not_horizon_exclusion() -> None:
    assessment = assess(LOCATION, AT, AT, altitude=-15, ovation=(aurora(0),), weather=weather())
    assert assessment.rating == "unknown"
    assert assessment.activity.value == 0


def test_weather_bracket_envelope_and_final_sample() -> None:
    w = weather()
    assert w.snapshot is not None
    samples = list(w.snapshot.weather)
    samples[-1] = replace(samples[-1], total_cloud=90)
    w = replace(w, snapshot=replace(w.snapshot, weather=tuple(samples)))
    assessment = assess(LOCATION, AT + timedelta(minutes=30), AT, altitude=-15, weather=w)
    assert assessment.weather.value == 90
    assert len(assessment.weather.sample_times) == 2
    assert (
        assess(
            LOCATION, AT + timedelta(hours=1, seconds=1), AT, altitude=-15, weather=w
        ).weather.state
        == "not_covered"
    )
    wrong = replace(w, snapshot=replace(w.snapshot, coordinates=(21, 60)))
    assert assess(LOCATION, AT, AT, weather=wrong).weather.state == "not_covered"


def test_weather_missing_bracket_and_gap() -> None:
    w = weather()
    assert w.snapshot is not None
    samples = (replace(w.snapshot.weather[0], total_cloud=None), w.snapshot.weather[1])
    w = replace(w, snapshot=replace(w.snapshot, weather=samples))
    assert assess(LOCATION, AT - timedelta(minutes=30), AT, weather=w).weather.state == "missing"
    samples = (
        replace(samples[0], total_cloud=0),
        replace(samples[1], time=AT + timedelta(hours=6)),
    )
    w = replace(w, snapshot=replace(w.snapshot, weather=samples))
    assert assess(LOCATION, AT, AT, weather=w).weather.state == "not_covered"


def test_planning_context_never_local_signal() -> None:
    kp = result(
        Snapshot(
            "kp",
            Product.KP,
            "NOAA SWPC",
            AT,
            None,
            None,
            AT,
            AT,
            AT + timedelta(hours=3),
            (),
            None,
            kp=(KpBin(AT, AT + timedelta(hours=3), 9),),
        )
    )
    assessment = run(planning=True, kp=kp)
    assert assessment.kp_context.value == 9
    assert assessment.basis == "planning"
    assert assessment.activity.state == "unknown"
    assert assessment.rating == "unknown"
    assert assessment.action == "check_later"


def test_interval_cannot_inherit_exact_instant() -> None:
    assessment = run(interval=Interval(AT - timedelta(seconds=1), AT + timedelta(seconds=1)))
    assert assessment.rating == "unknown"
    assert assessment.activity.state == "not_covered"


@pytest.mark.parametrize(
    "location,at",
    [
        (LOCATION, AT),
        (
            Location(latitude=69.65, longitude=18.96, timezone="Europe/Oslo"),
            datetime(2026, 6, 21, tzinfo=UTC),
        ),
        (
            Location(latitude=90.0, longitude=0.0, timezone="UTC"),
            datetime(2026, 12, 21, tzinfo=UTC),
        ),
        (LOCATION, datetime(2026, 10, 25, 0, tzinfo=UTC)),
    ],
)
def test_composition_preserves_windows_and_never_invents_activity(
    location: Location, at: datetime
) -> None:
    solar = calculate_windows(location, at)
    output = evaluate(location, solar)
    assert len(output.planning) == 3
    for night, segments in zip(solar.planning, output.planning, strict=True):
        assert bool(segments) == bool(night.windows)
        for segment in segments:
            assert any(
                w.interval.start <= segment.interval.start < segment.interval.end <= w.interval.end
                for w in night.windows
            )
            assert segment.assessment.rating == "unknown"
            assert segment.assessment.action != "try_now"
    if solar.upcoming_detail:
        assert output.upcoming[0].interval.start == solar.upcoming_detail.interval.start
        assert output.upcoming[-1].interval.end == solar.upcoming_detail.interval.end


def test_spatial_interpolation_wrap_poles_and_missing_cells() -> None:
    a = aurora()
    assert a.snapshot is not None
    grid = (
        GridPoint(179, 60, 0),
        GridPoint(-180, 60, 100),
        GridPoint(179, 61, 100),
        GridPoint(-180, 61, 0),
    )
    s = replace(a.snapshot, grid=grid)
    location = Location(latitude=60.5, longitude=179.5, timezone="UTC")
    assert local_signal(s, location) == 50
    assert local_signal(s, location, nearest=True) == 0
    assert local_signal(replace(s, grid=grid[:1]), location) is None
    pole = Location(latitude=90.0, longitude=20.0, timezone="UTC")
    assert local_signal(replace(s, grid=(GridPoint(20, 90, 5),)), pole) == 5
    assert horizon_candidate(replace(s, grid=(GridPoint(20, 60, 5),)), LOCATION).value == 5  # type: ignore[union-attr]


@pytest.mark.parametrize(
    "kwargs",
    [
        {"positive_grid_at_least": 0},
        {"darkness_degrees": float("nan")},
        {"recheck_after": timedelta(0)},
    ],
)
def test_parameter_validation(kwargs: dict[str, object]) -> None:
    with pytest.raises(ValueError):
        Parameters(**kwargs)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    "product,age,state",
    [
        (Product.WEATHER, timedelta(hours=6), "stale"),
        (Product.WEATHER, timedelta(seconds=-1), "unavailable"),
    ],
)
def test_issue_age_not_reset_by_fetch(product: Product, age: timedelta, state: str) -> None:
    w = weather()
    assert w.snapshot is not None
    w = replace(w, snapshot=replace(w.snapshot, product=product, issued_at=AT - age))
    assessment = assess(LOCATION, AT, AT, altitude=-15, ovation=(aurora(),), weather=w)
    assert assessment.weather.state == state
    assert assessment.action != "try_now"


def test_refresh_failure_retains_fresh_evidence_and_reports_error() -> None:
    w = weather()
    w = replace(w, health=replace(w.health, refresh_error="transport_error"))
    assessment = assess(LOCATION, AT, AT, altitude=-15, weather=w)
    assert assessment.weather.state == "available"
    assert any("refresh failed" in r.message for r in assessment.reasons)


def test_malformed_validation_future_fetch_and_naive_time() -> None:
    a = aurora()
    assert a.snapshot is not None
    for snapshot in (
        replace(a.snapshot, validation_status="invalid"),
        replace(a.snapshot, fetched_at=AT + timedelta(seconds=1)),
    ):
        assert (
            assess(LOCATION, AT, AT, ovation=(replace(a, snapshot=snapshot),)).activity.state
            == "unavailable"
        )
    with pytest.raises(ValueError, match="aware"):
        assess(LOCATION, AT.replace(tzinfo=None), AT)


def test_revalidation_does_not_follow_alert_tick() -> None:
    at = AT + timedelta(minutes=59)
    assessment = assess(LOCATION, at, at, altitude=-15, weather=weather())
    assert assessment.refresh_after == AT + timedelta(hours=1)


def test_no_darkness_is_explicit() -> None:
    location = Location(latitude=69.65, longitude=18.96, timezone="Europe/Oslo")
    solar = calculate_windows(location, datetime(2026, 6, 21, tzinfo=UTC))
    output = evaluate(location, solar)
    assert output.astronomy.upcoming_status == "no_darkness_within_horizon"
    assert any(r.code == "no_darkness_within_horizon" for r in output.now.reasons)


def test_replay_report_reproducible() -> None:
    import importlib.util
    import json
    from pathlib import Path

    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        "evaluator_replay", root / "backend/tools/check_evaluator_replay.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert json.loads(json.dumps(module.replay())) == json.loads(
        (root / "backend/tests/fixtures/replays/evaluator-replay.json").read_text()
    )
