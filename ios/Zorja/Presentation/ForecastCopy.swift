import Foundation

// Client copy keyed by stable contract codes. Server prose is not displayed.

enum Tone: Sendable, Equatable {
    case good, blocked, unknown, stale

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .blocked: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .stale: "clock.badge.exclamationmark"
        }
    }
}

struct Headline: Equatable {
    let title: String
    let detail: String
}

struct FactorLine: Equatable {
    let label: String
    let value: String
    let tone: Tone
}

extension Assessment {
    /// `isCurrent` is false once the forecast's `refreshAfter` has passed; an expired
    /// `try_now` is shown as history, never as a live recommendation.
    func headline(upcoming: ViewingWindow?, clock: LocalClock, isCurrent: Bool) -> Headline {
        switch action {
        case .tryNow:
            guard isCurrent else {
                return Headline(
                    title: "Looked promising at \(clock.time(interval.start))",
                    detail: "That reading has expired. It needs a fresh check before it means anything now.")
            }
            return Headline(
                title: "Worth a look now",
                detail: "It's dark, the sky is clear enough, and there's a short-term aurora signal overhead.")
        case .wait:
            if let upcoming, upcoming.interval.start > interval.start {
                return Headline(
                    title: "Too bright right now",
                    detail: "It gets dark enough at \(clock.time(upcoming.interval.start)).")
            }
            return Headline(title: "Too bright right now", detail: "A darker window comes later.")
        case .skip:
            switch reasons.first(where: { $0.effect == .blocker })?.code {
            case .cloudObstruction:
                return Headline(
                    title: "Clouded over",
                    detail: "Heavy cloud blocks the sky, whatever the aurora is doing.")
            case .daylight, .twilightTooBright, .noDarknessWithinHorizon:
                return Headline(
                    title: "No darkness",
                    detail: "The sky doesn't get dark enough here in the next three days.")
            case .lowActivity:
                return Headline(
                    title: "Quiet right now",
                    detail: "Current data shows little aurora activity here.")
            default:
                return Headline(title: "Not worth it right now", detail: "Something is blocking the view.")
            }
        case .checkLater, .unrecognized:
            if rating == .limited {
                return Headline(
                    title: "Mixed skies",
                    detail: "There's an aurora signal, but cloud may get in the way.")
            }
            return Headline(title: "Can't tell yet", detail: unknownDetail)
        }
    }

    private var unknownDetail: String {
        if factors.darkness == .unknown { return "Darkness couldn't be calculated." }
        switch factors.weather {
        case .stale: return "The cloud forecast is out of date."
        case .missing, .unavailable, .notCovered, .unknown: return "There's no usable cloud forecast for this moment."
        case .favorable, .mixed, .obstructed, .partial: break
        }
        switch factors.activity {
        case .stale: return "The aurora data is out of date."
        default: return "There's no usable aurora data for this moment."
        }
    }

    /// Bar height for the night timeline, from the supplied cloud cover; nil when
    /// there is no usable cloud forecast for the segment.
    var clearness: Double? {
        switch factors.weather {
        case .favorable, .mixed, .obstructed:
            if let cloudCoverPercent { return 1 - cloudCoverPercent / 100 }
            return factors.weather == .favorable ? 1 : factors.weather == .mixed ? 0.5 : 0
        default:
            return nil
        }
    }

    var factorLines: [FactorLine] {
        [factors.darkness.line, factors.weather.line(cloud: cloudCoverPercent), factors.activity.line]
    }
}

extension DarknessFactor {
    var line: FactorLine {
        let (value, tone): (String, Tone) = switch self {
        case .daylight: ("Daylight", .blocked)
        case .civilTwilight: ("Civil twilight, too bright", .blocked)
        case .nauticalTwilight: ("Nautical twilight, too bright", .blocked)
        case .astronomicalTwilight: ("Dark enough", .good)
        case .astronomicalNight: ("Fully dark", .good)
        case .mixed: ("Varies", .unknown)
        case .unknown: ("Not calculated", .unknown)
        }
        return FactorLine(label: "Darkness", value: value, tone: tone)
    }
}

extension WeatherFactor {
    func line(cloud: Double?) -> FactorLine {
        let percent = cloud.map { " · \(Int($0.rounded()))% cloud" } ?? ""
        let (value, tone): (String, Tone) = switch self {
        case .favorable: ("Clear" + percent, .good)
        case .mixed: ("Partly cloudy" + percent, .unknown)
        case .obstructed: ("Overcast" + percent, .blocked)
        case .missing: ("Cloud data missing", .unknown)
        case .stale: ("Forecast out of date", .stale)
        case .unavailable: ("Forecast unavailable", .unknown)
        case .notCovered: ("Beyond the forecast", .unknown)
        case .partial: ("Partly forecast", .unknown)
        case .unknown: ("Unknown", .unknown)
        }
        return FactorLine(label: "Sky", value: value, tone: tone)
    }
}

extension ActivityFactor {
    var line: FactorLine {
        let (value, tone): (String, Tone) = switch self {
        case .supported: ("Signal overhead", .good)
        case .low: ("Quiet", .blocked)
        case .missing: ("Data missing", .unknown)
        case .stale: ("Data out of date", .stale)
        case .unavailable: ("Data unavailable", .unknown)
        case .notCovered: ("No data for this time", .unknown)
        case .partial: ("Partly covered", .unknown)
        case .unknown: ("Unknown", .unknown)
        }
        return FactorLine(label: "Aurora", value: value, tone: tone)
    }
}

extension PlanningNight {
    func title(evaluatedAt: Date, clock: LocalClock) -> String {
        if period.contains(evaluatedAt) { return "Tonight" }
        guard let start = windows.first?.interval.start else { return clock.weekday(period.start) }
        return "\(clock.weekday(start)) night"
    }

    var segments: [Assessment] { windows.flatMap(\.segments) }

    func darkRange(clock: LocalClock) -> String? {
        guard let first = windows.first, let last = windows.last else { return nil }
        if last.endIsSearchLimited { return "from \(clock.time(first.interval.start))" }
        return clock.range(Interval(start: first.interval.start, end: last.interval.end))
    }

    /// Display-only roll-up of the segment weather states the backend supplied.
    var skySummary: String {
        let total = segments.reduce(0) { $0 + $1.interval.duration }
        func hours(_ states: Set<WeatherFactor>) -> TimeInterval {
            segments.filter { states.contains($0.factors.weather) }.reduce(0) { $0 + $1.interval.duration }
        }
        let clear = hours([.favorable])
        let cloudy = hours([.obstructed])
        let known = clear + cloudy + hours([.mixed])
        guard total > 0, known > 0 else { return "No cloud forecast" }
        let incomplete = known < total ? ", forecast incomplete" : ""
        if clear == known { return "Clear" + incomplete }
        if cloudy == known { return "Overcast" + incomplete }
        if clear > 0 {
            let h = max(1, Int((clear / 3600).rounded()))
            return "Clear for about \(h) h of \(Int((total / 3600).rounded()))" + incomplete
        }
        return "Partly to mostly cloudy" + incomplete
    }

    /// Global Kp during this night's darkness, as labelled context only.
    var globalKpSummary: String {
        guard let context = globalKpContext else { return "No global Kp forecast" }
        let dark = context.bins.filter { bin in
            windows.contains { $0.interval.start < bin.interval.end && bin.interval.start < $0.interval.end }
        }
        let peak = (dark.isEmpty ? context.bins : dark).map(\.kp).max()
        let value = peak.map { $0.formatted(.number.precision(.fractionLength(0...1))) }
        switch (context.status, value) {
        case (.available, let value?): return "Global Kp up to \(value)"
        case (.partial, let value?): return "Global Kp up to \(value), partly covered"
        case (.stale, let value?): return "Global Kp was up to \(value), out of date"
        case (.stale, nil): return "Global Kp forecast out of date"
        case (.unavailable, _): return "Global Kp forecast unavailable"
        default: return "No global Kp forecast for this night yet"
        }
    }
}

struct LocalClock: Sendable {
    let timeZone: TimeZone

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    func weekday(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    func range(_ interval: Interval) -> String {
        "\(time(interval.start)) – \(time(interval.end))"
    }
}
