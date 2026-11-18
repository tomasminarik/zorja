import Synchronization
import Foundation

// Turns what the app knows (a forecast, a failed request, nothing yet) into the state and
// words of one Figma Now frame. Pure: the same input and clock always give the same screen.
// Words come from docs/copy.md; the API's own summary and message strings are never shown.

/// What the app knows when it draws the screen.
struct ScreenInput: Sendable, Equatable {
    /// The last forecast received, with its original timestamps. It may be past `refreshAfter`.
    var forecast: Forecast?
    /// Why the most recent request did not produce a forecast, if it didn't.
    var problem: ForecastLoader.Problem?
    /// The earliest time the next request may start (request floor or Retry-After).
    var nextCheck: Date?
    /// The selected place's name, for the loading lead.
    var place: String
    /// No place to check: no saved place chosen and location off, or the phone couldn't
    /// find itself. It comes before any forecast, since a forecast needs a place.
    var location: LocationProblem?
    /// A request is running now. Past `refreshAfter` with no problem, the old forecast is
    /// shown as history while fresh data is on its way, not as data Zorja can't get.
    var refreshing = false

    init(forecast: Forecast? = nil, problem: ForecastLoader.Problem? = nil, nextCheck: Date? = nil, place: String) {
        self.forecast = forecast
        self.problem = problem
        self.nextCheck = nextCheck
        self.place = place
    }
}

/// One Figma state (Screens → Now, Forecast states, App states).
enum ScreenKind: String, CaseIterable, Sendable {
    // Forecast states.
    case go, polarNight, wait, daytime, twilight, skip, midnightSun, tooBrightTonight
    case quiet, partlyCloudy, weatherUnknown, auroraUnknown, outOfDate
    /// Some data isn't available (`source_unavailable`), or a combination the app doesn't know.
    /// Copy exists, but there is no Figma frame for it.
    case cantCheck
    // App states.
    case loading, offlineNoForecast, error
    // First launch and location (Now · No place, Now · Can't find you).
    case noPlace, locationNotFound
}

/// Why there is no place to check the sky for.
enum LocationProblem: Sendable, Equatable {
    /// My Location is chosen but location is off for Zorja (or not asked yet).
    case off
    /// Location is on, but the last read couldn't work out where the phone is.
    case notFound
}

/// A button on Now in the location states. The first one in a state is the Primary.
enum NowAction: Sendable, Equatable {
    /// Opens Places.
    case choosePlace
    /// Opens iOS Settings, or asks for permission if it was never asked.
    case turnOnLocation
    /// Reads the location again.
    case findMeAgain

    var title: String {
        switch self {
        case .choosePlace: "Choose A Place"
        case .turnOnLocation: "Turn On Location"
        case .findMeAgain: "Try Again"
        }
    }

    var icon: ZorjaIcon {
        switch self {
        case .choosePlace: .search
        case .turnOnLocation, .findMeAgain: .location
        }
    }
}

/// A line of large text with the part Figma underlines.
struct Phrase: Sendable, Equatable {
    let text: String
    /// A substring of `text`, drawn underlined. Times and the words that carry the verdict.
    let emphasis: String?
    /// The night a bottom line is about ("Tonight", "Thursday", "Next 3 Nights"), at the start
    /// of `text`. Figma sets it alone on the first line.
    let subject: String?

    init(_ text: String, emphasis: String? = nil, subject: String? = nil) {
        self.text = text
        self.emphasis = emphasis
        self.subject = subject
    }
}

/// The small line above the headline.
enum StatusLine: Sendable, Equatable {
    /// "Updated HH:MM".
    case updated(String)
    /// The red Offline tag, then "Updated HH:MM".
    case offline(updated: String)
    /// "Last update HH:MM": stale data, or offline with an old forecast.
    case lastUpdate(String)

    var text: String {
        switch self {
        case .updated(let time): "Updated \(time)"
        case .offline(let time): "Updated \(time)"
        case .lastUpdate(let time): "Last update \(time)"
        }
    }
}

/// The Try Again button on the error screen.
struct RetryAction: Sendable, Equatable {
    /// Before this time the button is off (the API's retry delay or the request floor).
    let enabledAt: Date?

    func isEnabled(at date: Date) -> Bool { enabledAt.map { date >= $0 } ?? true }
}

struct ScreenState: Sendable, Equatable {
    let kind: ScreenKind
    let sky: SkyLevel
    let status: StatusLine?
    let headline: Phrase
    let lead: String
    /// The large line at the bottom of Now, if the state has one.
    let bottomLine: Phrase?
    let retry: RetryAction?
    /// The Tonight screen. Nil where Tonight shows the same message as Now (offline without a
    /// forecast, error).
    var tonight: TonightState?
    /// The 3 Nights screen, nil where it shows the same message as Now.
    var threeNights: ThreeNightsState?
    /// Location buttons at the bottom of Now, the Primary first.
    var actions: [NowAction] = []
    /// The forecast leads are set on balanced lines, as in the Now frames; Figma wraps the
    /// location states' leads and "No Connection." plainly.
    var balancesLead: Bool { actions.isEmpty && kind != .offlineNoForecast }
    /// Where Are You? has no place, so the header drops the location chip.
    var showsPlace: Bool { kind != .noPlace }
    /// The verdict is Go: the Now menu icon glows magenta while another item is open.
    var auroraActive: Bool { kind == .go || kind == .polarNight }

    /// Order from docs/copy.md: app state (loading, offline, error) → `now.action` → the
    /// first blocker → factors. A forecast past `refreshAfter` is never shown as current.
    static func make(_ input: ScreenInput, now: Date) -> ScreenState {
        switch input.location {
        case .off:
            return ScreenState(
                kind: .noPlace, sky: .off, status: nil,
                headline: Phrase("Where Are You?", emphasis: "You"),
                lead: "Location is off for Zorja, so it can’t check the sky where you are. Choose a place, or turn location on.",
                bottomLine: nil, retry: nil, actions: [.choosePlace, .turnOnLocation])
        case .notFound:
            return ScreenState(
                kind: .locationNotFound, sky: .off, status: nil,
                headline: Phrase("Can’t Find You."),
                lead: "Your phone couldn’t work out where you are. Try again in a moment, or choose a place.",
                bottomLine: nil, retry: nil, actions: [.findMeAgain, .choosePlace])
        case nil:
            break
        }
        if let forecast = input.forecast, forecast.isCurrent(at: now) {
            let words = ForecastWords(forecast: forecast, now: now, nextCheck: input.nextCheck)
            return words.state(offline: input.problem == .offline, place: input.place)
        }
        let clock = input.forecast.map { CopyClock(timeZone: $0.location.timeZone) } ?? CopyClock(timeZone: .current)
        switch input.problem {
        case .offline:
            return ScreenState(
                kind: .offlineNoForecast, sky: .off,
                status: input.forecast.map { .lastUpdate(clock.time($0.generatedAt)) },
                headline: Phrase("No Connection.", emphasis: "Connection"),
                lead: "Your phone is offline, so Zorja can’t check the sky. It tries again when you’re back online.",
                bottomLine: nil, retry: nil)
        case .rateLimited:
            let lead = input.nextCheck.map { "Zorja is busy. It tries again at \(clock.time($0))." }
                ?? "Zorja is busy. It tries again soon."
            return .error(lead: lead, retryAt: input.nextCheck)
        case .unavailable, .rejectedRequest, .unreadable:
            return .error(lead: "Something went wrong on Zorja’s side. It isn’t your connection.", retryAt: input.nextCheck)
        case nil:
            break
        }
        if let forecast = input.forecast {
            // Past refreshAfter and not yet replaced: history, never a recommendation.
            let since = clock.time(forecast.generatedAt)
            let next = [forecast.refreshAfter, input.nextCheck].compactMap { $0 }.max() ?? forecast.refreshAfter
            var words = ForecastWords(forecast: forecast, now: now, nextCheck: input.nextCheck)
            // No problem recorded: the next check is running or due, so say that rather
            // than that Zorja can't get fresh data.
            words.refreshing = true
            return ScreenState(
                kind: .outOfDate, sky: .off,
                status: .lastUpdate(since),
                headline: Phrase("Out Of Date Since \(since).", emphasis: since),
                lead: ForecastWords.refreshingLead,
                bottomLine: input.refreshing || next < now
                    ? nil : Phrase("Checking Again At \(clock.time(next)).", emphasis: clock.time(next)),
                retry: nil,
                tonight: TonightBuilder(words: words, kind: .outOfDate, place: input.place).state(),
                threeNights: ThreeNightsBuilder(words: words, kind: .outOfDate, place: input.place).state())
        }
        return ScreenState(
            kind: .loading, sky: .full, status: nil,
            headline: Phrase("Checking The Sky.", emphasis: "The Sky"),
            lead: "Looking at darkness, clouds and aurora over \(input.place).",
            bottomLine: nil, retry: nil,
            tonight: .loading(now: now, timeZone: .current, place: input.place),
            threeNights: .loading(now: now, timeZone: .current))
    }

    private static func error(lead: String, retryAt: Date?) -> ScreenState {
        ScreenState(
            kind: .error, sky: .off, status: nil,
            headline: Phrase("Can’t Check Right Now.", emphasis: "Right Now"),
            lead: lead, bottomLine: nil, retry: RetryAction(enabledAt: retryAt))
    }
}

extension ScreenKind {
    /// Opacity of the sky layer in the matching Figma frame (read 2026-11-06).
    var sky: SkyLevel {
        switch self {
        case .go, .polarNight, .loading: .full
        case .partlyCloudy: .partlyCloudy
        case .wait, .twilight, .weatherUnknown: .dim
        case .quiet, .auroraUnknown, .skip, .daytime, .midnightSun, .tooBrightTonight, .noPlace, .locationNotFound,
             .outOfDate, .cantCheck, .offlineNoForecast, .error: .off
        }
    }
}

/// The words of a current forecast.
struct ForecastWords {
    let forecast: Forecast
    let now: Date
    let nextCheck: Date?
    let clock: CopyClock

    static let outOfDateLead = "Zorja can’t get fresh data right now. Don’t rely on the last forecast."
    /// Past `refreshAfter` while the next check runs or is due: the last forecast has expired,
    /// nothing has failed.
    static let refreshingLead = "Zorja is getting fresh data. Don’t rely on the last forecast until it arrives."

    /// The forecast expired and the next check is running or due (not a stale source).
    var refreshing = false
    var outOfDateLead: String { refreshing ? Self.refreshingLead : Self.outOfDateLead }

    init(forecast: Forecast, now: Date, nextCheck: Date?) {
        self.forecast = forecast
        self.now = now
        self.nextCheck = nextCheck
        clock = CopyClock(timeZone: forecast.location.timeZone)
    }

    var assessment: Assessment { forecast.now }

    /// The place's aurora group from the API, nil without one.
    var reachGroup: AuroraReach.Group? { AuroraReach(forecast.auroraReach)?.group }

    /// "Dark, clear and aurora active overhead since 21:40." when the API says when the
    /// active stretch started ("since at least" when it may be longer).
    var goLead: String {
        guard let since = forecast.now.activeSince else { return "Dark, clear and aurora active overhead." }
        let atLeast = forecast.now.activeSinceIsBufferLimited == true ? "at least " : ""
        return "Dark, clear and aurora active overhead since \(atLeast)\(clock.time(since))."
    }
    var blockers: [ReasonCode] { assessment.reasons.filter { $0.effect == .blocker }.map(\.code) }
    var limitations: Set<ReasonCode> { Set(assessment.reasons.filter { $0.effect == .limitation }.map(\.code)) }
    /// "Tonight" is the first planning night.
    var tonight: PlanningNight? { forecast.planning.first }

    func state(offline: Bool, place: String) -> ScreenState {
        let kind = kind
        let (headline, lead, bottom) = words(for: kind)
        let status: StatusLine = switch kind {
        case .outOfDate: .lastUpdate(clock.time(lastFreshUpdate))
        default: offline ? .offline(updated: clock.time(forecast.generatedAt)) : .updated(clock.time(forecast.generatedAt))
        }
        return ScreenState(kind: kind, sky: kind.sky, status: status, headline: headline, lead: lead, bottomLine: bottom, retry: nil,
                           tonight: TonightBuilder(words: self, kind: kind, place: place).state(),
                           threeNights: ThreeNightsBuilder(words: self, kind: kind, place: place).state())
    }

    var kind: ScreenKind {
        switch assessment.action {
        case .tryNow:
            return isPolarNight ? .polarNight : .go
        case .wait:
            switch blockers.first {
            case .cloudObstruction: return .wait
            // The backend waits for any dark window within 72 hours. When that window is on
            // a later night, tonight has no dark hours: "Too Bright Tonight.", not a time days away.
            case .daylight: return darkensTonight ? .daytime : .tooBrightTonight
            case .twilightTooBright: return darkensTonight ? .twilight : .tooBrightTonight
            default: return .cantCheck
            }
        case .skip:
            // Midnight sun carries both `daylight` and `no_darkness_within_horizon`; the
            // three-day verdict wins over the first blocker so it reads "Too Bright All Night."
            if blockers.contains(.noDarknessWithinHorizon) || forecast.upcomingStatus == .noDarknessWithinHorizon {
                return .midnightSun
            }
            switch blockers.first {
            case .cloudObstruction: return .skip
            case .lowActivity: return .quiet
            // Too bright right now is listed first, but when tonight does get dark the skip
            // is for cloud over the dark hours: "Skip Tonight.", not "Too Bright Tonight."
            // (seen live in Tromsø at 16:15 in November).
            case .daylight, .twilightTooBright:
                return darkensTonight && blockers.contains(.cloudObstruction) ? .skip : .tooBrightTonight
            default: return .cantCheck
            }
        case .checkLater, .unrecognized:
            if limitations.contains(.sourceStale) || blockers.contains(.sourceStale) { return .outOfDate }
            if limitations.contains(.weatherMissing) || assessment.factors.weather == .missing { return .weatherUnknown }
            if limitations.contains(.activityNotCovered) || Self.unknownActivity.contains(assessment.factors.activity) {
                return .auroraUnknown
            }
            if limitations.contains(.sourceUnavailable) { return .cantCheck }
            if assessment.rating == .limited { return .partlyCloudy }
            return .cantCheck
        }
    }

    /// The next dark window starts before tonight's planning period ends.
    private var darkensTonight: Bool {
        guard let start = forecast.upcoming?.interval.start else { return false }
        guard let tonight else { return true }
        return start < tonight.period.end
    }

    static let unknownActivity: Set<ActivityFactor> = [.unknown, .unavailable, .notCovered, .missing]

    /// Now's headline, lead and bottom line for a state.
    func words(for kind: ScreenKind) -> (Phrase, String, Phrase?) {
        let tonightBest = bestWindow(in: tonight).map { window in
            Phrase("Tonight Best \(window.text).", emphasis: window.emphasis, subject: "Tonight")
        }
        switch kind {
        case .go:
            return (Phrase("Go Out Right Now.", emphasis: "Right Now"), goLead, tonightBest)
        case .polarNight:
            let until = clearRun(containing: now).map { clock.time($0.end) }
            let lead = until.map { "It’s polar night, dark all day. Clear until \($0), aurora active." }
                ?? "It’s polar night, dark all day. Aurora active."
            return (Phrase("Go Out Right Now.", emphasis: "Right Now"), lead,
                    until.map { Phrase("Today Best Until \($0).", emphasis: $0, subject: "Today") })
        case .wait:
            let best = bestRun(in: tonight)
            let clears = best.map { clock.time($0.start) }
            let headline = clears.map { Phrase("Wait Until \($0).", emphasis: $0) } ?? Phrase("Wait.", emphasis: "Wait")
            let dark = best.flatMap(darkness(around:))
            let stays = dark.map { window in
                isLastWindow(window) ? "and it stays dark all night." : "and it stays dark until \(clock.time(window.interval.end))."
            } ?? "and it stays dark all night."
            let lead = clears.map { "Cloud clears around \($0), \(stays)" } ?? "Cloud clears later tonight."
            return (headline, lead, tonightBest)
        case .daytime:
            let dark = forecast.upcoming.map { clock.time($0.interval.start) }
            let headline = dark.map { Phrase("Too Bright Until \($0).", emphasis: $0) } ?? Phrase("Too Bright Now.", emphasis: "Now")
            let lead = forecast.upcomingActivityInstant?.activity == .supported
                ? "Aurora is active, but daylight hides it. Tonight is checked on its own."
                : "Daylight hides any aurora. Tonight is checked on its own."
            return (headline, lead, tonightBest)
        case .twilight:
            let dark = forecast.upcoming.map { clock.time($0.interval.start) }
            let headline = dark.map { Phrase("Dark Enough At \($0).", emphasis: $0) } ?? Phrase("Too Bright Now.", emphasis: "Now")
            return (headline, "It’s twilight now, still too bright for faint aurora.", tonightBest)
        case .skip:
            let bottom: Phrase? = clearerNight().map { day in Phrase("\(day) Looks Clearer.", emphasis: day, subject: day) }
                ?? Phrase("Next 3 Nights Look Cloudy.", emphasis: "Look Cloudy", subject: "Next 3 Nights")
            return (Phrase("Skip Tonight.", emphasis: "Skip"), "Thick cloud all night, whatever the aurora does.", bottom)
        case .quiet:
            let bottom: Phrase? = if let window = bestWindow(in: tonight) {
                Phrase("Tonight Clear \(window.text).", emphasis: window.emphasis, subject: "Tonight")
            } else if let run = lastClearRunEnded() {
                Phrase("Tonight Cloudy After \(clock.time(run)).", emphasis: clock.time(run), subject: "Tonight")
            } else {
                nil
            }
            // Under the zone and at the edge a quiet hour doesn't decide the night.
            let lead = reachGroup == .underZone || reachGroup == .edge
                ? "Dark and clear, but there’s little aurora overhead. It often picks up here."
                : "Dark and clear, but there’s little aurora overhead. It can pick up quickly."
            return (Phrase("Quiet Right Now.", emphasis: "Right Now"), lead, bottom)
        case .midnightSun:
            return (Phrase("Too Bright All Night.", emphasis: "All Night"),
                    "The sun stays too high here for aurora to show.",
                    Phrase("Next 3 Nights No Darkness.", emphasis: "No Darkness", subject: "Next 3 Nights"))
        case .tooBrightTonight:
            let bottom = darkNight().map { day in Phrase("\(day) Gets Dark.", emphasis: day, subject: day) }
            return (Phrase("Too Bright Tonight.", emphasis: "Tonight"), "It doesn’t get dark enough here tonight.", bottom)
        case .partlyCloudy:
            let bottom = darkWindow(of: tonight).map { Phrase("Tonight Dark \($0.text).", emphasis: $0.emphasis, subject: "Tonight") }
            return (Phrase("Partly Cloudy.", emphasis: "Cloudy"),
                    "It’s dark and aurora is active, but cloud comes and goes. Watch for gaps.", bottom)
        case .weatherUnknown:
            return (Phrase("Clouds Not Known.", emphasis: "Not Known"),
                    "It’s dark and aurora is active, but there’s no cloud forecast right now.", lookUp)
        case .auroraUnknown:
            return (Phrase("Aurora Not Known.", emphasis: "Not Known"),
                    "It’s dark and clear, but there’s no live aurora data for here right now.", lookUp)
        case .outOfDate:
            let since = clock.time(lastFreshUpdate)
            return (Phrase("Out Of Date Since \(since).", emphasis: since), outOfDateLead, checkingAgain)
        case .cantCheck, .loading, .offlineNoForecast, .error, .noPlace, .locationNotFound:
            return (Phrase("Can’t Check Right Now.", emphasis: "Right Now"),
                    "Some of the data Zorja needs isn’t available. It tries again soon.", checkingAgain)
        }
    }

    private var lookUp: Phrase { Phrase("Look Up And Check.", emphasis: "Look Up") }

    /// `refreshAfter`, or the next allowed request if that is later.
    private var checkingAgain: Phrase {
        let next = [forecast.refreshAfter, nextCheck].compactMap { $0 }.max() ?? forecast.refreshAfter
        let time = clock.time(next)
        return Phrase("Checking Again At \(time).", emphasis: time)
    }

    /// When the stale data was last fresh: the newest issue time of the stale sources the
    /// reasons point to, falling back to `generatedAt`.
    var lastFreshUpdate: Date {
        let ids = Set(assessment.reasons.filter { $0.code == .sourceStale }.compactMap(\.sourceId))
        let issued = forecast.sources.filter { ids.contains($0.id) && $0.status == .stale }.compactMap(\.issuedAt)
        return issued.max() ?? forecast.generatedAt
    }

    // MARK: Windows

    /// "Polar night": the darkness window around now is cut only by the search limit and
    /// covers a whole day.
    var isPolarNight: Bool {
        guard let upcoming = forecast.upcoming, upcoming.interval.contains(now), upcoming.endIsSearchLimited else { return false }
        return upcoming.interval.duration >= 24 * 3600
    }

    func segments(_ night: PlanningNight?) -> [(segment: Assessment, window: ViewingWindow)] {
        (night?.windows ?? []).flatMap { window in window.segments.map { ($0, window) } }
    }

    /// Contiguous stretches of dark segments with clear (`favorable`) modeled weather.
    func clearRuns(in night: PlanningNight?) -> [(start: Date, end: Date, searchLimited: Bool)] {
        var runs: [(start: Date, end: Date, searchLimited: Bool)] = []
        for (segment, window) in segments(night) where segment.factors.weather == .favorable {
            let limited = window.endIsSearchLimited && segment.interval.end >= window.interval.end
            if let last = runs.last, last.end == segment.interval.start {
                runs[runs.count - 1] = (last.start, segment.interval.end, limited)
            } else {
                runs.append((segment.interval.start, segment.interval.end, limited))
            }
        }
        return runs
    }

    /// The first clear dark stretch tonight that hasn't ended.
    func bestRun(in night: PlanningNight?) -> (start: Date, end: Date, searchLimited: Bool)? {
        clearRuns(in: night).first { $0.end > now }
    }

    func bestWindow(in night: PlanningNight?) -> WindowText? {
        bestRun(in: night).map { window(start: $0.start, end: $0.end, searchLimited: $0.searchLimited) }
    }

    func clearRun(containing date: Date) -> (start: Date, end: Date, searchLimited: Bool)? {
        clearRuns(in: tonight).first { $0.start <= date && date < $0.end }
    }

    /// The end of tonight's last clear stretch that is already over.
    func lastClearRunEnded() -> Date? {
        clearRuns(in: tonight).last { $0.end <= now }?.end
    }

    private func darkness(around run: (start: Date, end: Date, searchLimited: Bool)) -> ViewingWindow? {
        tonight?.windows.first { $0.interval.start <= run.start && run.start < $0.interval.end }
    }

    private func isLastWindow(_ window: ViewingWindow) -> Bool {
        tonight?.windows.last == window
    }

    /// Tonight's whole dark time, from the first window's start to the last one's end.
    private func darkWindow(of night: PlanningNight?) -> WindowText? {
        guard let first = night?.windows.first, let last = night?.windows.last else { return nil }
        return window(start: first.interval.start, end: last.interval.end, searchLimited: last.endIsSearchLimited)
    }

    /// `Until HH:MM` once started, `From HH:MM` when a later window's end is search-limited,
    /// otherwise `HH:MM–HH:MM`.
    func window(start: Date, end: Date, searchLimited: Bool) -> WindowText {
        if start <= now {
            return WindowText(text: "Until \(clock.time(end))", emphasis: clock.time(end))
        }
        if searchLimited {
            return WindowText(text: "From \(clock.time(start))", emphasis: clock.time(start))
        }
        let range = "\(clock.time(start))–\(clock.time(end))"
        return WindowText(text: range, emphasis: range)
    }

    func clearTime(_ night: PlanningNight) -> TimeInterval {
        segments(night).filter { $0.segment.factors.weather == .favorable }.reduce(0) { $0 + $1.segment.interval.duration }
    }

    /// The nearest later planning night with more clear dark time than tonight.
    func clearerNight() -> String? {
        let tonightClear = tonight.map(clearTime) ?? 0
        return forecast.planning.dropFirst().first { clearTime($0) > tonightClear }.map { clock.weekday($0.period.start) }
    }

    /// The nearest later planning night that gets dark.
    private func darkNight() -> String? {
        forecast.planning.dropFirst().first { $0.darknessStatus == .windowsAvailable && !$0.windows.isEmpty }
            .map { clock.weekday($0.period.start) }
    }
}

struct WindowText {
    let text: String
    let emphasis: String
}

/// Local, 24-hour times and English weekdays in the forecast's own timezone.
struct CopyClock: Sendable {
    let timeZone: TimeZone

    func time(_ date: Date) -> String { format(date, "HH:mm") }
    /// The full weekday, as in headlines ("Thursday").
    func weekday(_ date: Date) -> String { format(date, "EEEE") }
    /// "Thu".
    /// "Thu 6", as on the 3 Nights rows.
    /// "10th November", as on the Night cards.
    func longDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.component(.day, from: date)
        let suffix = (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
        return "\(day)\(suffix) \(format(date, "MMMM"))"
    }

    /// One formatter per time zone and pattern: the Tonight strip formats hundreds of times
    /// while it is swiped.
    private static let formatters = Mutex<[String: DateFormatter]>([:])

    private func format(_ date: Date, _ pattern: String) -> String {
        let key = timeZone.identifier + "|" + pattern
        return Self.formatters.withLock { cache in
            let formatter = cache[key] ?? {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateFormat = pattern
                cache[key] = formatter
                return formatter
            }()
            return formatter.string(from: date)
        }
    }
}
