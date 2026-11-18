"""Public serialization of the conservative evaluator, without invented coverage."""

from dataclasses import replace
from datetime import datetime, timedelta
from typing import Any

from aurora_backend.astronomy.reach import AuroraReach, aurora_reach
from aurora_backend.astronomy.solar import classify_altitude
from aurora_backend.astronomy.windows import calculate_windows
from aurora_backend.domain.types import Interval, Location
from aurora_backend.evaluation.engine import (
    Assessment,
    Reason,
    Segment,
    active_since,
    assess,
    evaluate,
)
from aurora_backend.evaluation.model import DEFAULT_PARAMETERS
from aurora_backend.evaluation.spatial import local_signal
from aurora_backend.providers.activity import stream_deadline
from aurora_backend.providers.client import AGE_LIMITS
from aurora_backend.providers.models import Product, ProviderResult, SourceState


def stamp(at: datetime) -> str:
    return at.isoformat().replace("+00:00", "Z")


def interval(value: Interval) -> dict[str, str]:
    return {"start": stamp(value.start), "end": stamp(value.end)}


def assessment(value: Assessment, span: Interval, *, summary: bool = False) -> dict[str, Any]:
    weather: str = value.weather.state
    if weather == "available":
        cloud = value.weather.value
        weather = "favorable" if cloud is not None and cloud < 30 else "mixed"
        if cloud is not None and cloud > 70:
            weather = "obstructed"
    return {
        "interval": interval(span),
        "rating": value.rating,
        "action": value.action,
        "basis": value.basis,
        "confidence": value.confidence,
        "summary": {
            "unfavorable": "Viewing conditions are obstructed.",
            "limited": "Viewing conditions are limited.",
            "promising": "Experimental evidence suggests a viewing opportunity.",
            "unknown": "Available evidence cannot establish a viewing opportunity.",
        }[value.rating],
        "reasons": [
            {
                "code": r.code,
                "effect": r.effect,
                "message": r.message,
                **({"sourceId": r.source_id} if r.source_id else {}),
            }
            for r in value.reasons
        ],
        "solarAltitudeDegrees": None if summary else value.darkness.value,
        "cloudCoverPercent": None if summary else value.weather.value,
        "sourceIds": list(
            dict.fromkeys(
                [
                    *[
                        f.source_id
                        for f in (value.weather, value.activity, value.kp_context)
                        if f.source_id and (f is not value.kp_context or value.basis == "planning")
                    ],
                    *value.activity.source_ids,
                    "astronomy",
                ]
            )
        ),
        "activityEvidence": {
            "temporalPolicy": value.activity.temporal_policy,
            "spatialPolicy": "bilinear-overhead-grid-v1",
            "forecastInstants": [stamp(t) for t in value.activity.sample_times],
            "sourceIds": list(value.activity.source_ids)
            or ([value.activity.source_id] if value.activity.source_id else []),
            "supportedInterval": interval(value.activity.supported_interval)
            if value.activity.supported_interval
            else None,
        },
        "factors": {
            "darkness": "mixed"
            if summary
            else (
                classify_altitude(value.darkness.value)
                if value.darkness.value is not None
                else "unknown"
            ),
            "weather": weather,
            "activity": "supported"
            if value.activity.state == "available"
            else value.activity.state,
        },
    }


def source(product: Product, result: ProviderResult | None, at: datetime) -> dict[str, Any]:
    snapshot = result.snapshot if result else None
    status = result.health.state.value if result else "unavailable"
    origin = (snapshot.observed_at or snapshot.issued_at) if snapshot else None
    if snapshot and (
        origin is None
        or origin > at
        or snapshot.fetched_at > at
        or snapshot.product != product
        or snapshot.validation_status != "validated"
    ):
        status = "unavailable"
    elif snapshot and product == Product.OVATION:
        runs = (
            tuple(
                s
                for s in (snapshot, *result.retained)
                if s.forecast_at is not None and s.fetched_at <= at
            )
            if result
            else (snapshot,)
        )
        if (
            status == "fresh"
            and result
            and (result.health.refresh_error or at >= stream_deadline(runs))
        ):
            status = "stale"
    elif snapshot and origin and at >= origin + AGE_LIMITS[product]:
        status = "stale"
    elif snapshot and result and result.health.cache_expires_at:
        if at >= result.health.cache_expires_at and status == "fresh":
            status = "stale"
    if snapshot is None:
        status = "unavailable"
    weather = product == Product.WEATHER
    return {
        "id": snapshot.id if snapshot else product.value + ":unavailable",
        "provider": "met_norway" if weather else "noaa_swpc",
        "product": product.value,
        "role": {
            Product.OVATION: "aurora_short_term",
            Product.KP: "aurora_planning",
            Product.WEATHER: "weather",
        }[product],
        "kind": "model_forecast",
        "status": status,
        "issuedAt": stamp(origin) if origin else None,
        "fetchedAt": stamp(snapshot.fetched_at) if snapshot else None,
        "validFrom": stamp(snapshot.valid_from) if snapshot else None,
        "validUntil": stamp(snapshot.valid_until) if snapshot else None,
        "attribution": "MET Norway (CC BY 4.0)"
        if weather
        else "NOAA Space Weather Prediction Center",
        "url": "https://api.met.no/" if weather else "https://www.swpc.noaa.gov/",
    }


def global_kp_context(
    result: ProviderResult | None, period: Interval, at: datetime
) -> dict[str, Any]:
    """Global provider bins, preserving original UTC intervals and coverage gaps."""
    snapshot = result.snapshot if result else None
    ref = snapshot.id if snapshot else Product.KP.value + ":unavailable"
    relevant_start = max(period.start, at)
    bins = (
        [b for b in snapshot.kp if b.start < period.end and b.end > relevant_start]
        if snapshot
        else []
    )
    status = source(Product.KP, result, at)["status"]
    if status == "fresh":
        cursor = relevant_start
        for b in sorted(bins, key=lambda b: b.start):
            if b.start > cursor:
                break
            cursor = max(cursor, b.end)
        status = "available" if cursor >= period.end else "partial" if bins else "not_covered"
    return {
        "status": status,
        "sourceId": ref,
        "bins": [{"interval": interval(Interval(b.start, b.end)), "kp": b.kp} for b in bins],
    }


def aurora_outlook(
    reach: AuroraReach | None,
    result: ProviderResult | None,
    spans: list[Interval],
    at: datetime,
) -> dict[str, Any]:
    """Night planning outlook for southern places from the night's highest forecast Kp.

    Uses the remaining dark hours (or the whole night period when it has none).
    A planning outlook from NOAA's average oval rule, never a visibility rating.
    """
    snapshot = result.snapshot if result else None
    ref = snapshot.id if snapshot else Product.KP.value + ":unavailable"

    def outlook(status: str, highest: float | None = None) -> dict[str, Any]:
        return {"status": status, "highestKp": highest, "sourceId": ref}

    if reach is None or reach.group != "south":
        return outlook("not_applicable")
    never = reach.kp_low_in_north is None or reach.kp_low_in_north > 9
    status = source(Product.KP, result, at)["status"]
    if status != "fresh" or snapshot is None:
        return outlook("not_expected") if never else outlook(status)
    remaining = [Interval(max(s.start, at), s.end) for s in spans if s.end > at]
    highest = None
    for span in remaining or spans:
        bins = sorted(
            (b for b in snapshot.kp if b.start < span.end and b.end > span.start),
            key=lambda b: b.start,
        )
        cursor = span.start
        for b in bins:
            if b.start > cursor:
                break
            cursor = max(cursor, b.end)
        if cursor < span.end:
            return outlook("not_expected") if never else outlook("not_known_yet")
        highest = max([b.kp for b in bins] + ([highest] if highest is not None else []))
    if highest is None:
        return outlook("not_expected") if never else outlook("not_known_yet")
    could = not never and highest >= reach.kp_low_in_north  # type: ignore[operator]
    return outlook("could_reach" if could else "not_expected", highest)


def build_forecast(
    location: Location, at: datetime, results: dict[Product, ProviderResult]
) -> dict[str, Any]:
    # Enforce HTTP cache expiry in addition to scientific age, including injected replay inputs.
    checked = {}
    for product, result in results.items():
        if source(product, result, at)["status"] == "unavailable":
            result = replace(
                result, snapshot=None, health=replace(result.health, state=SourceState.UNAVAILABLE)
            )
            result = replace(result, retained=())
        if source(product, result, at)["status"] == "stale":
            result = replace(result, health=replace(result.health, state=SourceState.STALE))
        checked[product] = result
    results = checked
    solar = calculate_windows(location, at)
    reach = aurora_reach(location.latitude, location.longitude)
    kwargs: dict[str, Any] = {
        "ovation": (results[Product.OVATION],) if Product.OVATION in results else (),
        "weather": results.get(Product.WEATHER),
        "kp": results.get(Product.KP),
    }
    output = evaluate(location, solar, **kwargs)
    refresh = output.now.refresh_after
    for result in results.values():
        expiry = result.health.cache_expires_at
        if (
            result.snapshot
            and result.snapshot.product != Product.OVATION
            and expiry
            and expiry > at
        ):
            refresh = min(refresh, expiry)
    # now's interval is a response validity envelope, not continuous activity coverage.
    # Exact-instant support forces immediate revalidation; interval remains nonempty.
    now_span = Interval(at, max(refresh, at + timedelta(microseconds=1)))
    # Only when the current bracket itself is active, so it never contradicts now.
    since, limited = (
        active_since(kwargs["ovation"], location, at)
        if output.now.activity.state == "available"
        and output.now.activity.value is not None
        and output.now.activity.value >= DEFAULT_PARAMETERS.positive_grid_at_least
        else (None, False)
    )

    def window(w: Any, segments: tuple[Segment, ...]) -> dict[str, Any]:
        return {
            "interval": interval(w.interval),
            "endIsSearchLimited": w.end_is_search_limited,
            "segments": [assessment(s.assessment, s.interval) for s in segments],
        }

    planning = []
    for night, segments in zip(solar.planning, output.planning, strict=True):
        span = night.period.interval
        # Period-wide assessment does not project one midpoint's weather onto a night.
        value = assess(
            location,
            span.start + (span.end - span.start) / 2,
            at,
            planning=True,
            altitude=None,
            interval=span,
            **kwargs,
        )
        value = replace(
            value,
            rating="unknown",
            action="check_later",
            weather=replace(
                value.weather,
                state=(
                    "partial"
                    if any(s.assessment.weather.state == "available" for s in segments)
                    else value.weather.state
                ),
                value=None,
            ),
            reasons=(
                *value.reasons,
                Reason(
                    "experimental_model",
                    "limitation",
                    "Night summary is unknown; inspect individual darkness segments.",
                ),
            ),
        )
        if not night.windows:
            value = replace(
                value,
                rating="unfavorable",
                action="skip",
                reasons=(
                    *value.reasons,
                    Reason(
                        "no_darkness_within_horizon",
                        "blocker",
                        "No qualifying darkness in this local-night period.",
                    ),
                ),
            )
        summary = assessment(value, span, summary=True)
        planning.append(
            {
                "localDate": night.period.local_date.isoformat(),
                "period": interval(span),
                "assessment": summary,
                "globalKpContext": global_kp_context(results.get(Product.KP), span, at),
                "auroraOutlook": aurora_outlook(
                    reach,
                    results.get(Product.KP),
                    [w.interval for w in night.windows] or [span],
                    at,
                ),
                "darknessStatus": night.darkness_status,
                "windows": [
                    window(w, tuple(s for s in segments if w.interval.contains(s.interval.start)))
                    for w in night.windows
                ],
            }
        )
    sources = [source(p, results.get(p), at) for p in Product]
    aurora = results.get(Product.OVATION)
    runs = tuple(
        {
            s.id: s
            for s in (
                (*aurora.retained, *([aurora.snapshot] if aurora.snapshot else []))
                if aurora
                else ()
            )
            if s.fetched_at <= at and s.observed_at is not None and s.observed_at <= at
        }.values()
    )
    source_ids = {s["id"] for s in sources}
    if aurora:
        for snapshot in runs:
            if snapshot.id not in source_ids:
                sources.append(
                    source(Product.OVATION, replace(aurora, snapshot=snapshot, retained=runs), at)
                )
                source_ids.add(snapshot.id)
    instant = None
    newest = max(runs, key=lambda s: (s.observed_at, s.fetched_at, s.id)) if runs else None
    if newest and newest.forecast_at and newest.forecast_at > at and aurora:
        signal = local_signal(newest, location)
        state = source(Product.OVATION, replace(aurora, snapshot=newest, retained=runs), at)[
            "status"
        ]
        activity = (
            "stale"
            if state == "stale"
            else "unavailable"
            if state != "fresh"
            else (
                "not_covered"
                if signal is None
                else "supported"
                if signal >= DEFAULT_PARAMETERS.positive_grid_at_least
                else "unknown"
            )
        )
        instant = {
            "forecastAt": stamp(newest.forecast_at),
            "sourceId": newest.id,
            "overheadSignal": signal if state == "fresh" else None,
            "activity": activity,
            "temporalPolicy": "exact-forecast-instant-v1",
            "spatialPolicy": "bilinear-overhead-grid-v1",
        }
    sources.append(
        {
            "id": "astronomy",
            "provider": "backend_astronomy",
            "role": "darkness",
            "product": solar.model_version,
            "kind": "calculation",
            "status": "fresh",
            "issuedAt": stamp(at),
            "fetchedAt": None,
            "validFrom": stamp(solar.coverage.start),
            "validUntil": stamp(solar.coverage.end),
            "attribution": "Astral 3.2 solar geometry",
            "url": "https://astral.readthedocs.io/",
        }
    )
    return {
        "apiVersion": "1.0.0",
        "modelVersion": output.model_version,
        "generatedAt": stamp(at),
        "refreshAfter": stamp(refresh),
        "minimumRevalidationIntervalSeconds": 60,
        "location": location.model_dump(),
        "now": {
            **assessment(output.now, now_span),
            "activeSince": stamp(since) if since else None,
            "activeSinceIsBufferLimited": limited,
        },
        "upcomingStatus": solar.upcoming_status,
        "upcoming": window(solar.upcoming_detail, output.upcoming)
        if solar.upcoming_detail
        else None,
        "upcomingActivityInstant": instant,
        "auroraReach": reach.as_json(),
        "planning": planning,
        "sources": sources,
        "limitations": [
            "Experimental assessment, not a scientifically validated visibility probability.",
            "Current OVATION activity uses the minimum of retained forecasts at most 20 minutes "
            "apart; this experimental bracket is not observed continuous activity.",
            "The newest upcoming OVATION forecast describes an exact instant, "
            "not a duration or a viewing guarantee.",
            "Global Kp has no validated local planning mapping; horizon conditions are unmodeled.",
            "Weather is modeled; between samples a conservative cloud envelope is used.",
        ],
    }
