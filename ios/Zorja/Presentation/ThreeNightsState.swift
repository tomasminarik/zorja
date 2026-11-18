import Foundation

// The 3 Nights cards, from the same forecast and clock as Now (docs/copy.md → 3 Nights
// redesign, docs/decisions.md → 3 Nights cards). Pure: the same input always gives the same
// screen.

struct ThreeNightsState: Sendable, Equatable {
    /// What decides a night at this place. Nil until the API says which group the place is in
    /// (`auroraReach`, docs/forecast-model.md), so no place gets another group's line.
    let placeLine: String?
    /// The note under "Next Three Nights": the place group's note, or the state's
    /// (out of date, no darkness). Nil when neither is known.
    let note: String?
    let nights: [NightCardState]

    static let title = "Next Three Nights"
}

/// One Night card (Figma: Night card).
struct NightCardState: Sendable, Equatable, Identifiable {
    let id: String
    let tag: ZorjaTag.Kind?
    /// "Dark sky 16:42–06:14", "No dark hours", or "Checking".
    let darkSky: String
    /// The full weekday.
    let day: String
    /// "10th November".
    let date: String
    /// The night as a whole; nil without darkness and while checking.
    let sky: Sky.Kind?
    /// Southern places: a storm forecast could reach the place on this night.
    let storm: Bool
    /// 4 to 6 slots from sunset to sunrise; none without darkness and while checking.
    let slots: [ForecastSlot.Model]
    /// Add To Calendar in the Best night's card, for its clear window while some of it is
    /// still ahead. Never on a tie.
    var calendar: CalendarEventDraft? = nil

    var isBest: Bool { tag == .best }
}

/// What Add To Calendar puts into the system's event sheet (docs/copy.md → Night detail).
struct CalendarEventDraft: Sendable, Equatable {
    static let title = "Look for the aurora"
    static let notes = "Give your eyes 20 minutes to adjust. A Zorja outlook, not a promise."

    let start: Date
    let end: Date
    /// The place's name.
    let location: String
    let timeZone: TimeZone
}

/// How far aurora usually reaches a place (docs/forecast-model.md → Aurora reach), from the
/// API's `auroraReach`. Without it, or with a group the app doesn't know, the app shows no
/// group-specific words or marks.
struct AuroraReach: Sendable, Equatable {
    enum Group: Sendable, Equatable { case underZone, edge, south }

    let group: Group
    /// The forecast Kp at which aurora shows low in the northern sky here (NOAA's oval rule).
    /// Infinite where the rule never reaches the place (magnetic latitude undefined).
    let kpLowInNorth: Double

    init(group: Group, kpLowInNorth: Double) {
        self.group = group
        self.kpLowInNorth = kpLowInNorth
    }

    init?(_ info: AuroraReachInfo?) {
        guard let info else { return nil }
        switch info.group {
        case .underZone: group = .underZone
        case .edge: group = .edge
        case .south: group = .south
        case .unrecognized: return nil
        }
        kpLowInNorth = info.kpLowInNorth ?? .infinity
    }
}

extension ThreeNightsState {
    /// Loading: the next three nights by name, each "Checking".
    static func loading(now: Date, timeZone: TimeZone) -> ThreeNightsState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = CopyClock(timeZone: timeZone)
        // A night is named after the day it starts on; before noon that is yesterday.
        let start = calendar.date(byAdding: .hour, value: -12, to: now) ?? now
        let nights = (0..<3).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return NightCardState(id: "loading-\(index)", tag: nil, darkSky: "Checking", day: clock.weekday(date),
                                  date: clock.longDate(date), sky: nil, storm: false, slots: [])
        }
        return ThreeNightsState(placeLine: nil, note: nil, nights: nights)
    }
}

/// Builds 3 Nights from a forecast's words.
struct ThreeNightsBuilder {
    let words: ForecastWords
    let kind: ScreenKind
    let place: String
    /// The forecast's `auroraReach` unless a test sets it.
    var reach: AuroraReach?

    init(words: ForecastWords, kind: ScreenKind, place: String, reach: AuroraReach? = nil) {
        self.words = words
        self.kind = kind
        self.place = place
        self.reach = reach ?? AuroraReach(words.forecast.auroraReach)
    }

    private var forecast: Forecast { words.forecast }
    private var clock: CopyClock { words.clock }
    private var outOfDate: Bool { kind == .outOfDate }
    private var south: AuroraReach? { reach?.group == .south ? reach : nil }

    static let noDarknessNote = "Aurora needs a dark sky. It won’t get dark enough here in the next three days."

    static func outOfDateNote(_ time: String) -> String {
        "Updated \(time). Cloud is hidden until fresh data arrives."
    }

    func state() -> ThreeNightsState {
        let facts = forecast.planning.enumerated().map { NightFacts(night: $0.element, index: $0.offset, words: words) }
        let reaching = Set(facts.filter(couldReach).map(\.index))
        let pick = outOfDate ? BestPick.noClearNight : Self.pickBest(facts, among: south == nil ? nil : reaching)
        let best: NightFacts? = if case let .one(index) = pick { facts[index] } else { nil }
        let nights = facts.map { card($0, isBest: $0.index == best?.index) }
        let note: String? = if outOfDate {
            Self.outOfDateNote(clock.time(words.lastFreshUpdate))
        } else if !facts.isEmpty, facts.allSatisfy({ $0.night.darknessStatus == .noDarkness }) {
            Self.noDarknessNote
        } else {
            groupNote
        }
        return ThreeNightsState(placeLine: placeLine, note: note, nights: nights)
    }

    // MARK: Words

    private var placeLine: String? {
        switch reach?.group {
        case .underZone: "In \(place), aurora shows most clear nights, so the clearest night is the best one."
        case .edge: "In \(place), aurora often shows low in the northern sky, so the clearest night is the best one."
        case .south: "Aurora reaches here only in storms, so the best night is a clear one a storm could reach."
        case nil: nil
        }
    }

    private var groupNote: String? {
        switch reach?.group {
        case .underZone, .edge: "Clear, dark hours decide here. Aurora itself can only be known about 90 minutes ahead."
        case .south: "Most of the time aurora comes without warning. It needs darkness and a clear sky."
        case nil: nil
        }
    }

    private func card(_ fact: NightFacts, isBest: Bool) -> NightCardState {
        let night = fact.night
        let storm = !outOfDate && couldReach(fact)
        return NightCardState(
            id: night.id,
            tag: tag(fact, isBest: isBest, storm: storm),
            darkSky: darkSky(fact),
            day: clock.weekday(night.period.start),
            date: clock.longDate(night.period.start),
            sky: nightSky(fact),
            storm: storm && nightSky(fact) != nil,
            slots: slots(fact),
            calendar: isBest ? calendarDraft(fact) : nil)
    }

    /// Best by the Best tag rule; Skip for a night with no clear dark window; in the south,
    /// Clear sky for a clear night no storm is forecast to reach. Out of date: none. A tie has
    /// no Best night, so it shows no Best tag.
    private func tag(_ fact: NightFacts, isBest: Bool, storm: Bool) -> ZorjaTag.Kind? {
        if outOfDate { return nil }
        if isBest { return .best }
        switch fact.sky {
        case .unknown, .darknessUnknown: return nil
        case .noDarkness: return .skip
        case .clear, .mostlyCloudy, .partlyCloudy, .overcast:
            let hasWindow = words.clearRuns(in: fact.night).contains { $0.end.timeIntervalSince($0.start) >= Self.minimumWindow }
            guard hasWindow else { return .skip }
            return south != nil && fact.sky == .clear && !storm ? .clearSky : nil
        }
    }

    /// A clear sky window is at least an hour of clear, dark time (docs/forecast-model.md).
    static let minimumWindow: TimeInterval = 3600

    private func darkSky(_ fact: NightFacts) -> String {
        let windows = fact.night.windows
        guard let last = windows.last else {
            return fact.night.darknessStatus == .noDarkness ? "No dark hours" : "Dark sky not known"
        }
        let start = darkStart(fact)
        if start <= fact.night.period.start, last.interval.end >= fact.night.period.end {
            return "Dark sky all day"
        }
        if last.endIsSearchLimited { return "Dark sky from \(clock.time(start))" }
        return "Dark sky \(clock.time(start))–\(clock.time(last.interval.end))"
    }

    /// When the night's darkness began. Tonight's first window starts no earlier than the
    /// forecast was made, so where it starts at or after then, the sun says when it got dark.
    private func darkStart(_ fact: NightFacts) -> Date {
        guard let first = fact.night.windows.first?.interval.start else { return fact.night.period.start }
        guard fact.index == 0, first >= forecast.generatedAt.addingTimeInterval(-60), first > fact.night.period.start else {
            return first
        }
        let location = forecast.location
        return SolarPosition.darkStart(before: first, notBefore: fact.night.period.start,
                                       latitude: location.latitude, longitude: location.longitude) ?? fact.night.period.start
    }

    private func nightSky(_ fact: NightFacts) -> Sky.Kind? {
        if outOfDate { return fact.hasDarkness ? .unknown : nil }
        switch fact.sky {
        case .noDarkness: return nil
        case .clear: return .clear
        case .mostlyCloudy, .partlyCloudy: return .partlyCloudy
        case .overcast: return .cloudy
        case .unknown, .darknessUnknown: return .unknown
        }
    }

    // MARK: Slots

    private func slots(_ fact: NightFacts) -> [ForecastSlot.Model] {
        let night = fact.night
        let dark = night.windows.map(\.interval)
        guard !dark.isEmpty else { return [] }
        let location = forecast.location
        let span = SolarPosition.nightSpan(dark: dark, period: night.period,
                                           latitude: location.latitude, longitude: location.longitude)
        let midnight = SolarPosition.lowest(in: span, latitude: location.latitude, longitude: location.longitude)
        let segments = words.segments(night).map(\.segment)
        let times = Self.slotTimes(span: span, solarMidnight: midnight, timeZone: clock.timeZone)
        let half = (times.count > 1 ? times[1].timeIntervalSince(times[0]) : 3 * 3600) / 2
        return times.map { time in
            // A slot stands for the time around its hour: its dark part decides its Sky.
            let slot = Interval(start: time.addingTimeInterval(-half), end: time.addingTimeInterval(half))
            let darkParts = dark.compactMap { Self.overlap($0, slot) }
            var sky: Sky.Kind?
            if !darkParts.isEmpty {
                let weather = segments.filter { segment in darkParts.contains { Self.overlap($0, segment.interval) != nil } }
                    .map(\.factors.weather)
                sky = outOfDate ? .unknown : Self.sky(weather)
            }
            let storm = !outOfDate && sky != nil && sky != .unknown && darkParts.contains { reaches(night, during: $0) }
            return ForecastSlot.Model(hour: String(clock.time(time).prefix(2)), sky: sky, storm: storm,
                                      isClear: sky == .clear)
        }
    }

    private static func overlap(_ a: Interval, _ b: Interval) -> Interval? {
        let start = max(a.start, b.start), end = min(a.end, b.end)
        return start < end ? Interval(start: start, end: end) : nil
    }

    /// A slot's Sky from the weather of its dark hours: Clear when all of it is clear, Cloudy
    /// when all of it is cloud, Partly cloudy for anything between, Unknown when none of it is
    /// known. Unknown hours don't count as cloud.
    static func sky(_ weather: [WeatherFactor]) -> Sky.Kind {
        let known = weather.filter { !NightFacts.unknownWeather.contains($0) }
        if known.isEmpty { return .unknown }
        if known.allSatisfy({ $0 == .favorable }) { return .clear }
        if known.allSatisfy({ $0 == .obstructed }) { return .cloudy }
        return .partlyCloudy
    }

    /// Slot times: 3 hours apart, 4 for nights over 16 hours, 2 for nights under 9; as many as
    /// fit from sunset to sunrise (4 to 6), evenly spaced around solar midnight, the first one
    /// rounded to the place's nearest whole hour.
    static func slotTimes(span: Interval, solarMidnight: Date, timeZone: TimeZone) -> [Date] {
        let hours = span.duration / 3600
        let step: Double = hours > 16 ? 4 : hours < 9 ? 2 : 3
        let count = min(6, max(4, Int(hours / step) + 1))
        let first = solarMidnight.addingTimeInterval(-Double(count - 1) * step / 2 * 3600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hourStart = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let rounded = first.timeIntervalSince(hourStart) >= 1800 ? hourStart.addingTimeInterval(3600) : hourStart
        return (0..<count).map { rounded.addingTimeInterval(Double($0) * step * 3600) }
    }

    // MARK: Storms (southern places)

    /// The night's highest forecast Kp over its dark hours reaches the place. The API's night
    /// outlook decides when it is there; older responses fall back to the Kp bins.
    private func couldReach(_ fact: NightFacts) -> Bool {
        guard south != nil else { return false }
        if let outlook = fact.night.auroraOutlook, outlook.status != .notApplicable {
            return outlook.status == .couldReach
        }
        guard let south, let context = fact.night.globalKpContext,
              context.status == .available || context.status == .partial else { return false }
        let spans = fact.night.windows.isEmpty ? [fact.night.period] : fact.night.windows.map(\.interval)
        return context.bins.contains { bin in
            bin.kp >= south.kpLowInNorth && spans.contains { bin.interval.start < $0.end && bin.interval.end > $0.start }
        }
    }

    /// A 3-hour Kp forecast over this stretch reaches the place.
    private func reaches(_ night: PlanningNight, during interval: Interval) -> Bool {
        guard let south, let context = night.globalKpContext,
              context.status == .available || context.status == .partial else { return false }
        return context.bins.contains { $0.kp >= south.kpLowInNorth && Self.overlap($0.interval, interval) != nil }
    }

    // MARK: Calendar

    private func calendarDraft(_ fact: NightFacts) -> CalendarEventDraft? {
        guard let run = words.bestRun(in: fact.night) else { return nil }
        // Whole minutes, as the card and the calendar show them.
        func minute(_ date: Date) -> Date { Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60) }
        let start = minute(max(run.start, words.now))
        return CalendarEventDraft(start: start, end: minute(run.end), location: place, timeZone: clock.timeZone)
    }

    // MARK: Best night

    /// Which night 3 Nights recommends (docs/decisions.md, 2026-11-09).
    enum BestPick: Equatable {
        /// One night, marked Best. Index into the planning nights.
        case one(Int)
        /// Two later nights whose clear dark time is within `tieMargin`: no Best tag, no calendar.
        case tie([Int])
        /// No night has clear dark time.
        case noClearNight
    }

    /// Clear dark time closer than this doesn't make one night better than another: the
    /// forecast isn't that precise.
    static let tieMargin: TimeInterval = 30 * 60

    /// Tonight wins whenever it is clear: it can be used now, and it is the nearest, most
    /// reliable forecast. Otherwise the clear later night with the most clear dark time wins,
    /// unless another clear night is within `tieMargin`. With no clear night, the night with
    /// the most clear dark time wins, earlier on a tie. In the south (`among`: the nights a
    /// storm could reach) the rule runs within those nights when there are any. Planning
    /// ratings can't be `promising` yet, so the pick doesn't look at them.
    static func pickBest(_ facts: [NightFacts], among reaching: Set<Int>? = nil) -> BestPick {
        if let reaching, !reaching.isEmpty {
            let pick = pickBest(facts.filter { reaching.contains($0.index) })
            if pick != .noClearNight { return pick }
        }
        if let tonight = facts.first, tonight.index == 0, tonight.sky == .clear, tonight.clearTime > 0 {
            return .one(0)
        }
        let clear = facts.filter { $0.index > 0 && $0.sky == .clear && $0.clearTime > 0 }
        if let top = clear.map(\.clearTime).max() {
            let tied = clear.filter { $0.clearTime >= top - tieMargin }.map(\.index)
            return tied.count == 1 ? .one(tied[0]) : .tie(tied)
        }
        let best = facts.filter { $0.clearTime > 0 }.max { a, b in
            a.clearTime < b.clearTime || (a.clearTime == b.clearTime && a.index > b.index)
        }
        return best.map { .one($0.index) } ?? .noClearNight
    }
}

/// What a night's darkness and weather add up to.
struct NightFacts {
    enum Sky: Equatable {
        case noDarkness, darknessUnknown
        /// Clear for at least half of the dark time whose weather is known.
        case clear
        /// Some clear time, but under half.
        case mostlyCloudy
        /// No clear time; cloud comes and goes.
        case partlyCloudy
        /// The known dark time is all cloud.
        case overcast
        /// No weather is known for any of the dark time.
        case unknown
    }

    static let unknownWeather: Set<WeatherFactor> = [.missing, .stale, .unavailable, .notCovered, .partial, .unknown]

    let night: PlanningNight
    let index: Int
    let darkTime: TimeInterval
    let knownDarkTime: TimeInterval
    let clearTime: TimeInterval
    let sky: Sky

    var hasDarkness: Bool { !night.windows.isEmpty }

    init(night: PlanningNight, index: Int, words: ForecastWords) {
        self.night = night
        self.index = index
        let segments = words.segments(night).map(\.segment)
        darkTime = night.windows.reduce(0) { $0 + $1.interval.duration }
        let known = segments.filter { !Self.unknownWeather.contains($0.factors.weather) }
        knownDarkTime = known.reduce(0) { $0 + $1.interval.duration }
        clearTime = words.clearTime(night)

        if night.windows.isEmpty {
            sky = night.darknessStatus == .noDarkness ? .noDarkness : .darknessUnknown
        } else if known.isEmpty {
            sky = .unknown
        } else if clearTime > 0 {
            sky = clearTime * 2 >= knownDarkTime ? .clear : .mostlyCloudy
        } else if known.contains(where: { $0.factors.weather == .mixed }) {
            sky = .partlyCloudy
        } else {
            sky = .overcast
        }
    }
}
