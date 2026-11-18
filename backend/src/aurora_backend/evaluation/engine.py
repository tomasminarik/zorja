"""Pure offline evaluator. Internal results are not the public forecast contract."""

from dataclasses import dataclass, replace
from datetime import datetime, timedelta
from typing import Literal

from aurora_backend.astronomy.solar import classify_altitude, solar_altitude
from aurora_backend.astronomy.windows import SolarWindows, darkness_windows
from aurora_backend.domain.types import Interval, Location, utc
from aurora_backend.evaluation.model import DEFAULT_PARAMETERS, Parameters
from aurora_backend.evaluation.spatial import local_signal
from aurora_backend.providers.activity import RETENTION, stream_deadline
from aurora_backend.providers.models import Product, ProviderResult, Snapshot, SourceState

State = Literal["available", "missing", "stale", "unavailable", "not_covered", "unknown", "partial"]


@dataclass(frozen=True)
class Factor:
    state: State
    value: float | None = None
    source_id: str | None = None
    sample_times: tuple[datetime, ...] = ()
    source_ids: tuple[str, ...] = ()
    supported_interval: Interval | None = None
    temporal_policy: str = "exact-forecast-instant-v1"


@dataclass(frozen=True)
class Reason:
    code: str
    effect: Literal["blocker", "limitation", "information"]
    message: str
    source_id: str | None = None


@dataclass(frozen=True)
class Assessment:
    evaluated_for: datetime
    rating: Literal["unfavorable", "limited", "promising", "unknown"]
    action: Literal["try_now", "wait", "skip", "check_later"]
    basis: Literal["short_term", "planning", "unavailable"]
    confidence: Literal["low", "unknown"]
    darkness: Factor
    weather: Factor
    activity: Factor
    kp_context: Factor
    reasons: tuple[Reason, ...]
    source_ids: tuple[str, ...]
    model_version: str
    refresh_after: datetime


@dataclass(frozen=True)
class Segment:
    interval: Interval
    assessment: Assessment


@dataclass(frozen=True)
class Evaluation:
    now: Assessment
    upcoming: tuple[Segment, ...]
    planning: tuple[tuple[Segment, ...], ...]
    model_version: str
    astronomy: SolarWindows


def _snapshot(
    result: ProviderResult | None, product: Product, generated: datetime, max_age: timedelta
) -> tuple[Snapshot | None, State]:
    if result is None or result.snapshot is None:
        return None, "unavailable"
    snapshot = result.snapshot
    if snapshot.product != product or snapshot.validation_status != "validated":
        return snapshot, "unavailable"
    origin = snapshot.observed_at if product == Product.OVATION else snapshot.issued_at
    if origin is None:
        return snapshot, "unknown"
    if origin > generated or snapshot.fetched_at > generated:
        return snapshot, "unavailable"
    if result.health.state == SourceState.UNAVAILABLE:
        return snapshot, "unavailable"
    if result.health.state == SourceState.STALE or generated >= origin + max_age:
        return snapshot, "stale"
    return snapshot, "available"


def _weather(
    snapshot: Snapshot | None, state: State, location: Location, at: datetime, p: Parameters
) -> Factor:
    if snapshot is None:
        return Factor(state)
    if state != "available":
        return Factor(state, source_id=snapshot.id)
    if snapshot.coordinates is None or (
        abs(snapshot.coordinates[0] - location.longitude) > 0.0001
        or abs(snapshot.coordinates[1] - location.latitude) > 0.0001
    ):
        return Factor("not_covered", source_id=snapshot.id)
    samples = snapshot.weather
    for sample in samples:
        if sample.time == at:
            return Factor(
                "missing" if sample.total_cloud is None else "available",
                sample.total_cloud,
                snapshot.id,
                (sample.time,),
            )
    for left, right in zip(samples, samples[1:], strict=False):
        if left.time < at < right.time:
            times = (left.time, right.time)
            if right.time - left.time > p.max_weather_spacing:
                return Factor("not_covered", source_id=snapshot.id, sample_times=times)
            if left.total_cloud is None or right.total_cloud is None:
                return Factor("missing", source_id=snapshot.id, sample_times=times)
            # Conservative obstruction envelope, not a predicted minute of clearing.
            return Factor("available", max(left.total_cloud, right.total_cloud), snapshot.id, times)
    return Factor("not_covered", source_id=snapshot.id)


def _ovation_runs(
    inputs: tuple[ProviderResult, ...], generated: datetime
) -> tuple[list[Snapshot], State]:
    """Usable received OVATION runs by forecast time, newest receipt per instant."""
    runs: dict[datetime, Snapshot] = {}
    rejected: State = "unavailable"
    for result in inputs:
        for snapshot in (*result.retained, *([result.snapshot] if result.snapshot else [])):
            if (
                snapshot.product != Product.OVATION
                or snapshot.validation_status != "validated"
                or snapshot.forecast_at is None
                or snapshot.observed_at is None
                or snapshot.observed_at > generated
                or snapshot.fetched_at > generated
                or not timedelta(0)
                <= snapshot.forecast_at - snapshot.observed_at
                <= timedelta(hours=2)
                or result.health.state == SourceState.UNAVAILABLE
            ):
                continue
            if result.health.state == SourceState.STALE or result.health.refresh_error:
                rejected = "stale"
                continue
            previous = runs.get(snapshot.forecast_at)
            if previous is None or (snapshot.observed_at, snapshot.fetched_at, snapshot.id) > (
                previous.observed_at,
                previous.fetched_at,
                previous.id,
            ):
                runs[snapshot.forecast_at] = snapshot
    ordered = sorted(runs.values(), key=lambda s: s.forecast_at)  # type: ignore[arg-type,return-value]
    return ordered, rejected


def _bracket_activity(
    inputs: tuple[ProviderResult, ...],
    location: Location,
    at: datetime,
    generated: datetime,
    span: Interval | None,
    p: Parameters,
) -> tuple[Factor, datetime | None]:
    ordered, rejected = _ovation_runs(inputs, generated)
    if not ordered:
        failed_snapshot = next((r.snapshot for r in inputs if r.snapshot), None)
        return Factor(
            rejected,
            source_id=failed_snapshot.id if failed_snapshot else None,
            sample_times=(failed_snapshot.forecast_at,)
            if failed_snapshot and failed_snapshot.forecast_at
            else (),
            temporal_policy=p.temporal_policy,
        ), None
    deadline = stream_deadline(tuple(ordered), p.ovation_publication_max_age, p.ovation_max_age)
    newest = ordered[-1]
    assert newest.forecast_at
    fallback = Factor(
        "not_covered",
        source_id=newest.id,
        sample_times=(newest.forecast_at,),
        temporal_policy=p.temporal_policy,
    )
    if generated >= deadline:
        return replace(fallback, state="stale"), deadline
    for left, right in zip(ordered, ordered[1:], strict=False):
        assert left.forecast_at and right.forecast_at
        if left.forecast_at <= at < right.forecast_at:
            bracket = Interval(left.forecast_at, right.forecast_at)
            if right.forecast_at - left.forecast_at > p.ovation_max_gap:
                break
            if span and not (bracket.start <= span.start and span.end <= bracket.end):
                return fallback, deadline
            values = (local_signal(left, location), local_signal(right, location))
            if any(v is None for v in values):
                break
            return Factor(
                "available",
                min(v for v in values if v is not None),
                left.id,
                (left.forecast_at, right.forecast_at),
                (left.id, right.id),
                bracket,
                p.temporal_policy,
            ), deadline
    return fallback, deadline


def active_since(
    inputs: tuple[ProviderResult, ...],
    location: Location,
    generated_at: datetime,
    parameters: Parameters = DEFAULT_PARAMETERS,
) -> tuple[datetime | None, bool]:
    """Start of the unbroken active stretch that includes now, from retained runs.

    A past measurement of received model runs, never a forecast. Active means the
    same overhead threshold as the current bracket; a gap longer than the bracket
    limit, a missing cell or a quiet run breaks the stretch. The second value is
    true when the stretch reaches the oldest retained run within the retention
    window, so it may have started earlier. (None, False) when not active now.
    """
    generated, p = utc(generated_at), parameters
    if p.temporal_policy != "retained-bracket-min-v1":
        return None, False
    ordered, _ = _ovation_runs(inputs, generated)
    if not ordered or generated >= stream_deadline(
        tuple(ordered), p.ovation_publication_max_age, p.ovation_max_age
    ):
        return None, False
    ordered = [s for s in ordered if s.forecast_at and s.forecast_at >= generated - RETENTION]

    def active(snapshot: Snapshot) -> bool:
        value = local_signal(snapshot, location)
        return value is not None and value >= p.positive_grid_at_least

    for index, (left, right) in enumerate(zip(ordered, ordered[1:], strict=False)):
        assert left.forecast_at and right.forecast_at
        if left.forecast_at <= generated < right.forecast_at:
            if right.forecast_at - left.forecast_at > p.ovation_max_gap or not (
                active(left) and active(right)
            ):
                return None, False
            first = index
            while first > 0:
                earlier, later = ordered[first - 1], ordered[first]
                assert earlier.forecast_at and later.forecast_at
                if later.forecast_at - earlier.forecast_at > p.ovation_max_gap or not active(
                    earlier
                ):
                    break
                first -= 1
            return ordered[first].forecast_at, first == 0
    return None, False


def assess(
    location: Location,
    at: datetime,
    generated_at: datetime,
    *,
    ovation: tuple[ProviderResult, ...] = (),
    weather: ProviderResult | None = None,
    kp: ProviderResult | None = None,
    planning: bool = False,
    later_candidate: datetime | None = None,
    altitude: float | None = None,
    parameters: Parameters = DEFAULT_PARAMETERS,
    interval: Interval | None = None,
) -> Assessment:
    """Point or representative midpoint. None altitude means unavailable.

    Freshness uses response generation time. Retained earlier grids are explicit;
    future-only grids never cover now. Positive-duration intervals cannot be
    covered by an exact forecast instant.
    """
    at, generated = utc(at), utc(generated_at)
    p = parameters
    if interval is not None and not interval.contains(at):
        raise ValueError("Representative time must be inside interval")
    darkness = Factor("unavailable" if altitude is None else "available", altitude)
    if altitude is not None:
        classify_altitude(altitude)
    ws, wstate = _snapshot(weather, Product.WEATHER, generated, p.weather_max_age)
    wf = _weather(ws, wstate, location, at, p)
    ks, kstate = _snapshot(kp, Product.KP, generated, p.kp_max_age)
    kf = Factor(kstate, source_id=ks.id if ks else None)
    if ks and kstate == "available":
        item = next((b for b in ks.kp if b.start <= at < b.end), None)
        kf = Factor("available" if item else "not_covered", item.kp if item else None, ks.id)
    af = Factor("unknown" if planning else "unavailable")
    selected: Snapshot | None = None
    activity_deadline = None
    if not planning and p.temporal_policy == "retained-bracket-min-v1":
        af, activity_deadline = _bracket_activity(ovation, location, at, generated, interval, p)
    elif not planning:
        candidates = [_snapshot(r, Product.OVATION, generated, p.ovation_max_age) for r in ovation]
        matching = [(s, state) for s, state in candidates if s and s.forecast_at == at]
        if matching:
            selected, state = max(
                matching, key=lambda pair: pair[0].observed_at or pair[0].fetched_at
            )
            value = local_signal(selected, location) if state == "available" else None
            activity_state: State = state
            if state == "available":
                activity_state = "available" if value is not None else "not_covered"
            af = Factor(
                "not_covered" if interval and state == "available" else activity_state,
                None if interval else value,
                selected.id,
                (at,),
            )
        elif candidates:
            states = [state for _, state in candidates]
            candidate = next((s for s, _ in candidates if s is not None), None)
            af = Factor(
                "not_covered" if "available" in states else states[0],
                source_id=candidate.id if candidate else None,
                sample_times=(candidate.forecast_at,)
                if candidate and candidate.forecast_at
                else (),
            )
    reasons = [
        Reason(
            "experimental_model", "limitation", "Experimental rules; no visibility probability."
        ),
        Reason(
            "unmodeled_local_conditions",
            "limitation",
            "Horizon, terrain, light pollution and optical cloud properties are not modeled.",
        ),
    ]
    for name, factor in (("darkness", darkness), ("weather", wf), ("activity", af)):
        if factor.state != "available":
            code = "source_unavailable"
            if factor.state == "stale":
                code = "source_stale"
            elif name == "weather" and factor.state == "missing":
                code = "weather_missing"
            elif name == "activity" and factor.state in ("unknown", "not_covered"):
                code = "activity_not_covered"
            reasons.append(
                Reason(
                    code,
                    "limitation",
                    f"{name.title()} evidence is {factor.state.replace('_', ' ')}.",
                    factor.source_id
                    or (
                        "astronomy"
                        if name == "darkness"
                        else Product.WEATHER.value + ":unavailable"
                        if name == "weather"
                        else None
                        if planning
                        else Product.OVATION.value + ":unavailable"
                    ),
                )
            )
    for product, result in (
        *[(Product.OVATION, r) for r in ovation],
        *([(Product.WEATHER, weather)] if weather else []),
        *([(Product.KP, kp)] if kp else []),
    ):
        if result.health.refresh_error:
            reasons.append(
                Reason(
                    "source_unavailable",
                    "limitation",
                    "Provider refresh failed; retained evidence is checked independently.",
                    result.snapshot.id if result.snapshot else product.value + ":unavailable",
                )
            )
    if planning:
        reasons.append(
            Reason(
                "activity_not_covered",
                "limitation",
                "Global Kp context has no validated local geographic mapping.",
            )
        )
    blockers = []
    if altitude is not None and altitude > p.darkness_degrees:
        blockers.append(
            Reason(
                "daylight" if altitude >= 0 else "twilight_too_bright",
                "blocker",
                "Sun is above the experimental viewing threshold.",
            )
        )
    if wf.state == "available" and wf.value is not None and wf.value > p.obstructed_cloud_above:
        blockers.append(
            Reason(
                "cloud_obstruction",
                "blocker",
                "Modeled total cloud exceeds the obstruction threshold.",
            )
        )
    # Weak overhead intensity cannot exclude horizon-visible activity.
    if af.state == "available" and af.value is not None and af.value < p.positive_grid_at_least:
        af = replace(af, state="unknown")
        reasons.append(
            Reason(
                "activity_not_covered",
                "limitation",
                "Weak overhead signal does not rule out horizon-visible activity.",
            )
        )
    rating: Literal["unfavorable", "limited", "promising", "unknown"] = "unknown"
    action: Literal["try_now", "wait", "skip", "check_later"] = "check_later"
    if blockers:
        rating, action = "unfavorable", "skip"
        if (
            not planning
            and interval is None
            and later_candidate is not None
            and utc(later_candidate) > at
            and all(b.code in ("daylight", "twilight_too_bright") for b in blockers)
        ):
            action = "wait"
    elif all(f.state == "available" for f in (darkness, wf, af)):
        assert wf.value is not None
        if wf.value >= p.clear_cloud_below:
            rating = "limited"
        else:
            rating = "promising"
            if not planning and interval is None and at == generated:
                action = "try_now"
    basis: Literal["short_term", "planning", "unavailable"] = "unavailable"
    if af.state == "available":
        basis = "short_term"
    elif (planning or at > generated) and kf.state == "available":
        basis = "planning"
    ids = tuple(
        dict.fromkeys(
            [
                *af.source_ids,
                *[s.id for s in (*[r.snapshot for r in ovation], ws, ks) if s is not None],
            ]
        )
    )
    refresh = generated + p.recheck_after
    if activity_deadline and activity_deadline > generated:
        refresh = min(refresh, activity_deadline)
    for snapshot, ceiling in (
        (selected, p.ovation_max_age),
        (ws, p.weather_max_age),
        (ks, p.kp_max_age),
    ):
        if snapshot:
            origin = (
                snapshot.observed_at if snapshot.product == Product.OVATION else snapshot.issued_at
            )
            if origin is not None and origin + ceiling > generated:
                refresh = min(refresh, origin + ceiling)
    if wf.sample_times:
        refresh = min([refresh, *[t for t in wf.sample_times if t > generated]])
    if af.state == "available" and at == generated:
        refresh = min(refresh, af.supported_interval.end) if af.supported_interval else generated
    if later_candidate is not None and utc(later_candidate) > generated:
        refresh = min(refresh, utc(later_candidate))
    confidence: Literal["low", "unknown"] = (
        "low" if any(f.state == "available" for f in (darkness, wf, af)) else "unknown"
    )
    return Assessment(
        at,
        rating,
        action,
        basis,
        confidence,
        darkness,
        wf,
        af,
        kf,
        tuple([*blockers, *reasons]),
        ids,
        p.version,
        refresh,
    )


def evaluate(
    location: Location,
    solar: SolarWindows,
    *,
    ovation: tuple[ProviderResult, ...] = (),
    weather: ProviderResult | None = None,
    kp: ProviderResult | None = None,
    parameters: Parameters = DEFAULT_PARAMETERS,
) -> Evaluation:
    """Compose now/upcoming/three nights, preserving gaps and period labels."""
    generated = utc(solar.evaluated_at)
    p = parameters
    if p.darkness_degrees != -12:
        raise ValueError("Supplied astronomy windows use the -12 degree threshold")
    boundaries = {generated, solar.coverage.end}
    for threshold in (0.0, -6.0, -12.0, -18.0):
        for window in darkness_windows(location, solar.coverage, threshold=threshold):
            boundaries.update((window.interval.start, window.interval.end))
    for result in (*ovation, *([weather] if weather else []), *([kp] if kp else [])):
        for snapshot in (*result.retained, *([result.snapshot] if result.snapshot else [])):
            if snapshot.forecast_at:
                boundaries.add(snapshot.forecast_at)
            boundaries.update(s.time for s in snapshot.weather)
            for item in snapshot.kp:
                boundaries.update((item.start, item.end))
    future = sorted(t for t in boundaries if t > generated)
    now = assess(
        location,
        generated,
        generated,
        ovation=ovation,
        weather=weather,
        kp=kp,
        altitude=solar.altitude_degrees,
        parameters=p,
        later_candidate=solar.upcoming.interval.start if solar.upcoming else None,
    )
    if future:
        now = replace(now, refresh_after=min(now.refresh_after, future[0]))
    if solar.upcoming is None:
        now = replace(
            now,
            reasons=(
                *now.reasons,
                Reason(
                    "no_darkness_within_horizon",
                    "blocker",
                    "No qualifying darkness in the bounded 72-hour search.",
                ),
            ),
        )

    def segments(window: Interval, planning: bool) -> tuple[Segment, ...]:
        points = sorted({window.start, window.end, *[t for t in boundaries if window.contains(t)]})
        result = []
        for start, end in zip(points, points[1:], strict=False):
            at = start + (end - start) / 2
            interval = Interval(start, end)
            assessment = assess(
                location,
                at,
                generated,
                ovation=ovation,
                weather=weather,
                kp=kp,
                planning=planning,
                altitude=solar_altitude(location, at),
                parameters=p,
                interval=interval,
            )
            result.append(Segment(interval, assessment))
        return tuple(result)

    upcoming = segments(solar.upcoming_detail.interval, False) if solar.upcoming_detail else ()
    planning = tuple(
        tuple(segment for w in night.windows for segment in segments(w.interval, True))
        for night in solar.planning
    )
    return Evaluation(now, upcoming, planning, p.version, solar)
