import Foundation

// The Tonight screen's words and strip of hours, from the same forecast and clock as Now
// (docs/copy.md → Tonight redesign, docs/decisions.md 2026-11-13). Pure: the same input always
// gives the same screen.

struct TonightState: Sendable, Equatable {
    /// What decides the night at this place. Nil until the API says which group the place is
    /// in (`auroraReach`, docs/forecast-model.md), so no place gets another group's line.
    var placeLine: String?
    let headline: Phrase
    let lead: String
    let strip: TonightStrip
    /// The tips card over the strip; nil when there's nothing to plan for.
    let card: TonightCard?
    /// Midnight sun: Tonight shows only "Aurora Needs Darkness", no strip and no card. Daytime,
    /// twilight and a night that doesn't get dark keep the strip (decisions, 2026-11-13).
    var tooBright = false
}

enum TonightCard: Sendable, Equatable {
    /// Tonight has a dark window left.
    case giveYourEyes
    /// Tonight is skip and a later night has more clear dark time.
    case clearer(day: String)

    /// A no-break space keeps "20 Minutes" together, as in Figma.
    var message: String {
        switch self {
        case .giveYourEyes: "Give Your Eyes 20\u{00A0}Minutes."
        case .clearer(let day): "\(day) Looks Clearer."
        }
    }

    var buttonTitle: String {
        switch self {
        case .giveYourEyes: "More Tips"
        case .clearer: "See 3 Nights"
        }
    }
}

/// Tonight's strip of hours: one circle per real hour from sunset to sunrise (noon to noon where
/// the sun doesn't rise or set), the readout's time and the legend for the hour under it. After
/// a clock change the strip keeps real hours, so a repeated hour shows twice and a skipped one
/// not at all.
struct TonightStrip: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case forecast
        /// No cloud forecast: darkness and aurora only.
        case weatherMissing
        case midnightSun
        /// Cloud and aurora hidden; the time is the last update.
        case outOfDate(updated: String)
        case loading
    }

    enum Activity: Sendable, Equatable {
        case on, quiet, unknown

        init(_ factor: ActivityFactor) {
            switch factor {
            case .supported: self = .on
            case .low: self = .quiet
            case .missing, .stale, .unavailable, .notCovered, .partial, .unknown: self = .unknown
            }
        }
    }

    /// The sky over part of the dark time.
    struct Weather: Sendable, Equatable {
        let interval: Interval
        let sky: Sky.Kind
    }

    /// One circle on the strip, for the real hour from `start`.
    struct Hour: Sendable, Equatable, Identifiable {
        let start: Date
        /// The hour in the place's own time, "00" to "23".
        let label: String
        let sky: HourMark.Sky
        /// Live aurora during part of this hour.
        var aurora = false
        var id: Date { start }
        var end: Date { start.addingTimeInterval(3600) }
        func contains(_ time: Date) -> Bool { start <= time && time < end }
    }

    /// Live aurora data reaches about 90 minutes ahead at most.
    static let liveReach: TimeInterval = 90 * 60
    /// The readout moves in 5-minute steps.
    static let step: TimeInterval = 5 * 60

    let mode: Mode
    let now: Date
    let timeZone: TimeZone
    /// Sunset to sunrise, or noon to noon when the sun doesn't rise or set. Nil while loading.
    let span: Interval?
    /// Tonight's darkness windows (sun at −12° or lower).
    let dark: [Interval]
    /// Clear and dark stretches.
    let clear: [Interval]
    /// Live aurora, from now to as far as live data reaches, within the night.
    let aurora: Interval?
    let weather: [Weather]
    let hours: [Hour]
    let nowActivity: Activity
    /// The end of the live aurora data; `now` when there is none ahead.
    let liveEnd: Date
    let liveActivity: Activity
    /// The latest time the readout can reach: the end of tonight's dark time.
    let latest: Date

    var canSwipe: Bool { latest > now }

    // MARK: Readout

    /// Every note the legend can show, from now to `latest`, so the legend's space can be set by
    /// the longest one and the strip doesn't move when a note wraps to another line.
    var allNotes: [String] {
        var notes = [note(at: now)]
        var time = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / Self.step).rounded(.up) * Self.step)
        while time <= latest {
            let text = note(at: time)
            if !notes.contains(text) { notes.append(text) }
            time = time.addingTimeInterval(Self.step)
        }
        if !notes.contains(note(at: latest)) { notes.append(note(at: latest)) }
        return notes
    }

    /// The readout's time for a swipe of `hours` from now: 5-minute steps on the clock, never
    /// before now or after `latest`.
    func readout(hoursFromNow hours: Double) -> Date {
        guard canSwipe, hours > 0 else { return now }
        let raw = now.addingTimeInterval(hours * 3600)
        let snapped = Date(timeIntervalSince1970: (raw.timeIntervalSince1970 / Self.step).rounded() * Self.step)
        if snapped <= now { return now }
        return min(snapped, latest)
    }

    // MARK: Words

    private var clock: CopyClock { CopyClock(timeZone: timeZone) }

    /// "Now 20:14" at now, "21:00" anywhere else.
    func timeStamp(_ time: Date) -> String {
        time <= now ? "Now \(clock.time(now))" : clock.time(time)
    }

    /// The readout's time for VoiceOver: "Now, 20:14" or "At 21:00".
    func spokenTime(_ time: Date) -> String {
        time <= now ? "Now, \(clock.time(now))" : "At \(clock.time(time))"
    }

    /// The circle under the readout: the hour holding `time`, or the nearest one.
    func focus(at time: Date) -> Int? {
        guard !hours.isEmpty else { return nil }
        if let index = hours.firstIndex(where: { $0.contains(time) }) { return index }
        return time < hours[0].start ? 0 : hours.count - 1
    }

    /// Closed at the end, so the readout at the last dark minute still reads as dark.
    func isDark(_ time: Date) -> Bool { dark.contains { $0.start <= time && time <= $0.end } }

    func sky(at time: Date) -> Sky.Kind? {
        weather.first { $0.interval.contains(time) }?.sky ?? weather.last { $0.interval.end == time }?.sky
    }

    /// The legend's note for the readout's time, in its tense: "is" now, "should" within the
    /// live aurora data, and nothing about aurora beyond it.
    func note(at needle: Date) -> String {
        switch mode {
        case .loading: return "Checking the sky."
        case .outOfDate(let updated): return "Updated \(updated). Cloud and aurora are hidden until fresh data arrives."
        case .midnightSun: return "Too bright all night."
        case .forecast, .weatherMissing: break
        }
        let isNow = needle <= now
        let activity: Activity? = isNow ? nowActivity : (needle <= liveEnd ? liveActivity : nil)
        // "Should stay" when aurora keeps what it does now, "should be" when it changes.
        let should = activity == nowActivity ? "should stay" : "should be"

        guard isDark(needle) else {
            if activity == .on {
                return isNow ? "Aurora is on, but it’s too bright to see it."
                    : "Aurora \(should) on, but it’ll be too bright to see it."
            }
            return tooBright(at: needle)
        }
        if mode == .weatherMissing {
            if activity == .on {
                return isNow ? "Aurora is on. No cloud forecast here right now."
                    : "Aurora \(should) on. No cloud forecast here right now."
            }
            return "No cloud forecast here right now."
        }
        let beyond = "Aurora can only be known about 90 minutes ahead."
        switch sky(at: needle) ?? .unknown {
        case .unknown:
            return "Weather not known yet."
        case .clear:
            switch activity {
            case .on: return isNow ? "Aurora is on, and the sky is clear." : "Aurora \(should) on, and the sky will be clear."
            case .quiet: return isNow ? "Clear and dark, but aurora is quiet." : "Clear and dark, but aurora \(should) quiet."
            case .unknown: return "Clear and dark. No live aurora data here."
            case nil: return "Clear and dark. \(beyond)"
            }
        case .partlyCloudy:
            switch activity {
            case .on: return isNow ? "Aurora is on, with gaps in the clouds." : "Aurora \(should) on, with gaps in the clouds."
            case .quiet: return isNow ? "Some gaps in the clouds. Aurora is quiet." : "Some gaps in the clouds. Aurora \(should) quiet."
            case .unknown: return "Some gaps in the clouds. No live aurora data here."
            case nil: return "Some gaps in the clouds. \(beyond)"
            }
        case .cloudy:
            switch activity {
            case .on: return isNow ? "Aurora is on, but clouds cover it." : "Aurora \(should) on, but clouds will cover it."
            case .quiet: return isNow ? "Cloudy, and aurora is quiet." : "Cloudy, and aurora \(should) quiet."
            case .unknown: return "Cloudy. No live aurora data here."
            case nil: return "Cloudy."
            }
        }
    }

    private func tooBright(at time: Date) -> String {
        guard let dark = dark.first(where: { $0.start > time }) else { return "Too bright all night." }
        return "Too bright until \(clock.time(dark.start))."
    }
}

extension TonightStrip {
    /// While loading, the strip shows the hours from 5 before now to 10 after (Figma: 15 to 06
    /// at 20:14).
    static let loadingBefore: TimeInterval = 5 * 3600
    static let loadingAfter: TimeInterval = 10 * 3600

    /// The legend for the circle under the readout: that circle again, a title for it and the
    /// note for the readout's time. Nil while loading, when the activity indicator takes its place.
    func legend(at time: Date) -> Legend? {
        guard mode != .loading, let index = focus(at: time) else { return nil }
        let hour = hours[index]
        return Legend(sky: hour.sky, aurora: hour.aurora, title: Self.legendTitle(hour, mode: mode), note: note(at: time))
    }

    struct Legend: Sendable, Equatable {
        let sky: HourMark.Sky
        let aurora: Bool
        let title: String
        let note: String
    }

    /// Titles approved in Figma (2026-11-13): Aurora Behind Cloud, Clear And Dark, Aurora, Clear
    /// Sky, Aurora, Gaps In Cloud, Clouds Not Known, Out Of Date. Gaps In Cloud, Cloudy and Too
    /// Bright follow them for the marks Figma doesn't show in the legend.
    static func legendTitle(_ hour: Hour, mode: Mode) -> String {
        if case .outOfDate = mode { return "Out Of Date" }
        let aurora = hour.aurora && hour.sky.canShowAurora
        switch hour.sky {
        case .clear: return aurora ? "Aurora, Clear Sky" : "Clear And Dark"
        case .partlyCloudy: return aurora ? "Aurora, Gaps In Cloud" : "Gaps In Cloud"
        case .cloudy: return aurora ? "Aurora Behind Cloud" : "Cloudy"
        case .unknown: return "Clouds Not Known"
        case .twilight, .daylight: return "Too Bright"
        case .loading: return "Checking"
        }
    }

    /// One hour for every real hour from the hour holding `start` to the one holding `end`,
    /// labelled with the place's own hour.
    static func hours(from start: Date, to end: Date, timeZone: TimeZone,
                      sky: (Interval) -> HourMark.Sky, aurora: (Interval) -> Bool = { _ in false }) -> [Hour] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = CopyClock(timeZone: timeZone)
        var time = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        var hours: [Hour] = []
        while time < end || hours.isEmpty {
            let hour = Interval(start: time, end: time.addingTimeInterval(3600))
            hours.append(Hour(start: time, label: String(clock.time(time).prefix(2)), sky: sky(hour), aurora: aurora(hour)))
            time = hour.end
        }
        return hours
    }
}

extension TonightState {
    /// Loading: the hours around now as empty circles, the readout at now.
    static func loading(now: Date, timeZone: TimeZone, place: String) -> TonightState {
        let strip = TonightStrip(
            mode: .loading, now: now, timeZone: timeZone, span: nil, dark: [], clear: [], aurora: nil, weather: [],
            hours: TonightStrip.hours(from: now.addingTimeInterval(-TonightStrip.loadingBefore),
                                      to: now.addingTimeInterval(TonightStrip.loadingAfter), timeZone: timeZone) { _ in .loading },
            nowActivity: .unknown, liveEnd: now, liveActivity: .unknown, latest: now)
        return TonightState(headline: Phrase("Checking The Sky."),
                            lead: "Looking at darkness, clouds and aurora over \(place).", strip: strip, card: nil)
    }
}

/// Builds Tonight from a forecast's words.
struct TonightBuilder {
    let words: ForecastWords
    let kind: ScreenKind
    /// The place's name, for the place line.
    var place = ""

    private var forecast: Forecast { words.forecast }
    private var now: Date { words.now }
    private var clock: CopyClock { words.clock }
    private var night: PlanningNight? { words.tonight }
    private var windows: [ViewingWindow] { night?.windows ?? [] }

    func state() -> TonightState {
        let (headline, lead) = top
        return TonightState(placeLine: placeLine, headline: Self.timesOnly(headline), lead: lead, strip: strip, card: card,
                            tooBright: Self.tooBrightKinds.contains(kind))
    }

    /// Only midnight sun hides the strip behind "Aurora Needs Darkness".
    static let tooBrightKinds: Set<ScreenKind> = [.midnightSun]

    /// Tonight's headlines underline only a time ("Go Out At 22:40."), not the verdict words
    /// Now underlines (Figma: the Tonight state frames).
    static func timesOnly(_ phrase: Phrase) -> Phrase {
        guard let emphasis = phrase.emphasis, emphasis.wholeMatch(of: /\d\d:\d\d/) != nil else { return Phrase(phrase.text) }
        return phrase
    }

    // MARK: Grey top

    /// What decides tonight at this place (docs/copy.md → What Zorja forecasts, approved
    /// 2026-11-12). In the south it follows tonight's storm outlook.
    private var placeLine: String? {
        switch words.reachGroup {
        case .underZone: return "In \(place), aurora shows overhead on most clear, dark nights."
        case .edge: return "In \(place), aurora often shows low in the northern sky, and overhead on active nights."
        case .south:
            switch night?.auroraOutlook?.status {
            case .couldReach: return "A storm forecast tonight could bring aurora this far south."
            case .notExpected: return "No storm is forecast to reach here tonight. Aurora can still come without warning."
            case .notKnownYet, .stale, .unavailable: return "Tonight’s storm forecast isn’t known yet."
            case .notApplicable, .unrecognized, nil: return nil
            }
        case nil: return nil
        }
    }

    private var top: (Phrase, String) {
        let goOutAt = words.bestRun(in: night).map { run -> Phrase in
            let time = clock.time(run.start)
            return run.start <= now ? Phrase("Go Out Right Now.", emphasis: "Right Now") : Phrase("Go Out At \(time).", emphasis: time)
        }
        let (nowHeadline, nowLead, _) = words.words(for: kind)
        switch kind {
        case .go:
            return (nowHeadline, nowLead)
        case .polarNight:
            let lead = words.clearRun(containing: now).map { "It’s polar night, dark all day. Clear until \(clock.time($0.end))." }
                ?? "It’s polar night, dark all day."
            return (Phrase("Go Out Right Now.", emphasis: "Right Now"), lead)
        case .wait:
            return (goOutAt ?? nowHeadline, "It’s too cloudy to see anything now.")
        case .daytime:
            return (goOutAt ?? nowHeadline, "It’s too bright to see anything now.")
        case .twilight:
            return (goOutAt ?? nowHeadline, "It’s twilight now, still too bright for faint aurora.")
        case .quiet:
            return (nowHeadline, "Clear and dark, but there’s little aurora overhead.")
        case .partlyCloudy:
            return (nowHeadline, "Cloud comes and goes. Watch for gaps.")
        case .auroraUnknown:
            return (nowHeadline, "It’s dark and clear, but there’s no live aurora data for here.")
        case .weatherUnknown:
            return (nowHeadline, "There’s no cloud forecast for this place right now.")
        case .outOfDate:
            let since = clock.time(words.lastFreshUpdate)
            return (Phrase("Out Of Date Since \(since).", emphasis: since), words.outOfDateLead)
        case .skip, .midnightSun, .tooBrightTonight, .cantCheck, .loading, .offlineNoForecast, .error, .noPlace, .locationNotFound:
            return (nowHeadline, nowLead)
        }
    }

    private var card: TonightCard? {
        switch kind {
        case .skip:
            return words.clearerNight().map { .clearer(day: $0) }
        case .go, .polarNight, .wait, .daytime, .twilight, .quiet, .partlyCloudy, .auroraUnknown, .cantCheck:
            return windows.contains { $0.interval.end > now } ? .giveYourEyes : nil
        case .midnightSun, .tooBrightTonight, .weatherUnknown, .outOfDate, .loading, .offlineNoForecast,
             .error, .noPlace, .locationNotFound:
            return nil
        }
    }

    // MARK: Strip

    private var mode: TonightStrip.Mode {
        switch kind {
        case .midnightSun: .midnightSun
        case .weatherUnknown: .weatherMissing
        case .outOfDate: .outOfDate(updated: clock.time(words.lastFreshUpdate))
        default: .forecast
        }
    }

    private var strip: TonightStrip {
        let mode = mode
        let dark = windows.map(\.interval)
        let span = self.span(dark)
        var hidesData = false
        if case .outOfDate = mode { hidesData = true }

        let weather: [TonightStrip.Weather] = hidesData ? [] : words.segments(night).map {
            TonightStrip.Weather(interval: $0.segment.interval, sky: Self.sky($0.segment.factors.weather))
        }
        let clear = hidesData ? [] : words.clearRuns(in: night).map { Interval(start: $0.start, end: $0.end) }

        let nowActivity = TonightStrip.Activity(forecast.now.factors.activity)
        var liveEnd = now
        var liveActivity = nowActivity
        if let instant = forecast.upcomingActivityInstant, instant.forecastAt > now {
            liveEnd = min(instant.forecastAt, now.addingTimeInterval(TonightStrip.liveReach))
            liveActivity = TonightStrip.Activity(instant.activity)
        }
        // Live aurora over the night, cloud or not; never before the night starts, nor on a
        // night with no dark time.
        var aurora: Interval?
        if !hidesData, nowActivity == .on, !dark.isEmpty, let span {
            let start = max(now, span.start), end = min(max(liveEnd, now), span.end)
            if span.contains(now), start <= end { aurora = Interval(start: start, end: end) }
        }

        let latest: Date = switch mode {
        case .forecast, .weatherMissing: max(now, dark.last?.end ?? now)
        case .midnightSun, .outOfDate, .loading: now
        }
        let segments = words.segments(night).map(\.segment)
        let place = forecast.location
        let hourSky: (Interval) -> HourMark.Sky = { hour in
            // An hour counts as dark when at least half of it is in tonight's dark windows.
            // Otherwise the sun halfway through it decides: up is daylight, down to −12° is
            // twilight, and lower is dark with nothing forecast for it (the API's windows start
            // when the forecast was made, so earlier dark hours have no weather).
            let darkParts = dark.compactMap { Self.overlap($0, hour) }
            let darkTime = darkParts.reduce(0) { $0 + $1.duration }
            guard darkTime >= hour.duration / 2 else {
                let middle = hour.start.addingTimeInterval(hour.duration / 2)
                let altitude = SolarPosition.altitude(at: middle, latitude: place.latitude, longitude: place.longitude)
                if altitude > 0 { return .daylight }
                return altitude > -12 || mode == .midnightSun ? .twilight : .unknown
            }
            switch mode {
            case .loading: return .loading
            case .outOfDate, .weatherMissing, .midnightSun: return .unknown
            case .forecast:
                let known = segments.filter { segment in darkParts.contains { Self.overlap($0, segment.interval) != nil } }
                return HourMark.Sky(ThreeNightsBuilder.sky(known.map(\.factors.weather)))
            }
        }
        // The night, widened to now when now is outside it, so the readout always has a circle.
        let start = min(span?.start ?? now, now), end = max(span?.end ?? now, now)
        let hours = TonightStrip.hours(from: start, to: end, timeZone: place.timeZone, sky: hourSky) { hour in
            aurora.map { $0.start < hour.end && hour.start < $0.end || ($0.start == $0.end && hour.contains($0.start)) } ?? false
        }
        return TonightStrip(mode: mode, now: now, timeZone: place.timeZone, span: span, dark: dark,
                            clear: clear, aurora: aurora, weather: weather, hours: hours,
                            nowActivity: hidesData ? .unknown : nowActivity, liveEnd: liveEnd, liveActivity: liveActivity,
                            latest: latest)
    }

    /// Sunset to sunrise around tonight's dark time, or the night's noon-to-noon period where
    /// the sun stays down (polar night) or there is no dark time (midnight sun).
    private func span(_ dark: [Interval]) -> Interval? {
        guard let night else { return nil }
        guard !dark.isEmpty else { return night.period }
        let place = forecast.location
        return SolarPosition.nightSpan(dark: dark, period: night.period, latitude: place.latitude, longitude: place.longitude)
    }

    private static func overlap(_ a: Interval, _ b: Interval) -> Interval? {
        let start = max(a.start, b.start), end = min(a.end, b.end)
        return start < end ? Interval(start: start, end: end) : nil
    }

    private static func sky(_ weather: WeatherFactor) -> Sky.Kind {
        switch weather {
        case .favorable: .clear
        case .mixed: .partlyCloudy
        case .obstructed: .cloudy
        case .missing, .stale, .unavailable, .notCovered, .partial, .unknown: .unknown
        }
    }
}

extension HourMark.Sky {
    init(_ kind: Sky.Kind) {
        switch kind {
        case .clear: self = .clear
        case .partlyCloudy: self = .partlyCloudy
        case .cloudy: self = .cloudy
        case .unknown: self = .unknown
        }
    }
}
