import EventKit
import Foundation
import Testing
@testable import Zorja

/// 3 Nights for every sample: tags, dark sky, the night's Sky, slot spacing, southern storms,
/// the place group's words, and the Add To Calendar button and event.
@Suite("3 Nights")
struct ThreeNightsTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let sample: String
        let tags: [ZorjaTag.Kind?]
        let darkSky: [String]
        let sky: [Sky.Kind?]
        /// The card with Add To Calendar and the event's local start: "2 23:43".
        var calendar: String?
        var note: String?
        /// The sample's place group, from its `auroraReach`.
        var group: AuroraReach.Group = .edge
        /// Southern samples: which nights a storm could reach.
        var storm: [Bool] = [false, false, false]
        var testDescription: String { sample }
    }

    static func placeLine(_ group: AuroraReach.Group) -> String {
        switch group {
        case .underZone: "In Stockholm, aurora shows most clear nights, so the clearest night is the best one."
        case .edge: "In Stockholm, aurora often shows low in the northern sky, so the clearest night is the best one."
        case .south: "Aurora reaches here only in storms, so the best night is a clear one a storm could reach."
        }
    }

    static func groupNote(_ group: AuroraReach.Group) -> String {
        group == .south
            ? "Most of the time aurora comes without warning. It needs darkness and a clear sky."
            : "Clear, dark hours decide here. Aurora itself can only be known about 90 minutes ahead."
    }

    static let october = ["Dark sky 19:17–05:52", "Dark sky 19:14–05:54", "Dark sky 19:11–05:56"]
    static let stale = "Updated %@. Cloud is hidden until fresh data arrives."

    // Times are Europe/Stockholm, read at each sample's own generatedAt.
    static let samples: [Expected] = [
        // Tonight is clear, so it is the Best night even where a later night has a few more
        // clear minutes. Tonight's darkness began before the forecast was made: the sun says when.
        .init(sample: "promising-now", tags: [.best, nil, nil], darkSky: october, sky: [.clear, .clear, .clear],
              calendar: "0 23:00"),
        .init(sample: "low-activity", tags: [.best, nil, nil], darkSky: october, sky: [.clear, .clear, .clear],
              calendar: "0 23:00"),
        .init(sample: "after-midnight-current-night", tags: [.best, nil, nil], darkSky: october, sky: [.clear, .clear, .clear],
              calendar: "0 03:00"),
        .init(sample: "partial-third-night", tags: [.best, nil, nil], darkSky: october, sky: [.clear, .clear, .clear],
              calendar: "0 23:00"),
        .init(sample: "daylight-next-window", tags: [.best, nil, nil], darkSky: october, sky: [.clear, .clear, .clear],
              calendar: "0 19:17"),
        .init(sample: "morning-finished-night", tags: [.best, nil, nil],
              darkSky: ["Dark sky 19:14–05:54", "Dark sky 19:11–05:56", "Dark sky 19:08–05:58"], sky: [.clear, .clear, .clear],
              calendar: "0 19:14"),
        // No darkness tonight; Wednesday has 37 minutes more clear dark time than Tuesday.
        .init(sample: "too-bright-tonight", tags: [.skip, nil, .best],
              darkSky: ["No dark hours", "Dark sky 00:02–01:27", "Dark sky 23:43–01:45"], sky: [nil, .clear, .clear],
              calendar: "2 23:43", group: .underZone),
        .init(sample: "cloud-blocked", tags: [.skip, .skip, .skip], darkSky: october, sky: [.cloudy, .cloudy, .cloudy]),
        .init(sample: "limited-clouds", tags: [.skip, .skip, .skip], darkSky: october,
              sky: [.partlyCloudy, .partlyCloudy, .partlyCloudy]),
        .init(sample: "midnight-sun", tags: [.skip, .skip, .skip], darkSky: Array(repeating: "No dark hours", count: 3),
              sky: [nil, nil, nil], note: ThreeNightsBuilder.noDarknessNote, group: .underZone),
        .init(sample: "weather-missing", tags: [nil, nil, nil], darkSky: october, sky: [.unknown, .unknown, .unknown]),
        .init(sample: "weather-unavailable", tags: [nil, nil, nil], darkSky: october, sky: [.unknown, .unknown, .unknown]),
        .init(sample: "stale-weather", tags: [nil, nil, nil], darkSky: october, sky: [.unknown, .unknown, .unknown],
              note: String(format: stale, "16:00")),
        .init(sample: "stale-aurora", tags: [nil, nil, nil], darkSky: october, sky: [.unknown, .unknown, .unknown],
              note: String(format: stale, "22:10")),
        .init(sample: "polar-night", tags: [.best, nil, nil], darkSky: Array(repeating: "Dark sky all day", count: 3),
              sky: [.clear, .clear, .clear], calendar: "0 01:00", group: .underZone),
        .init(sample: "disjoint-darkness", tags: [.best, nil, nil], darkSky: Array(repeating: "Dark sky all day", count: 3),
              sky: [.clear, .clear, .clear], calendar: "0 13:00", group: .underZone),
        // Edinburgh (Europe/London). Kp 5 every night reaches it: every night has a storm mark,
        // tonight is clear so it is Best, and no night reads Clear sky.
        .init(sample: "south-could-reach", tags: [.best, nil, nil], darkSky: edinburgh, sky: [.clear, .clear, .clear],
              calendar: "0 22:00", group: .south, storm: [true, true, true]),
        // Kp 3 never reaches it: Best as under the zone, the other clear nights read Clear sky.
        .init(sample: "south-not-expected", tags: [.best, .clearSky, .clearSky], darkSky: edinburgh,
              sky: [.clear, .clear, .clear], calendar: "0 22:00", group: .south),
    ]

    static let edinburgh = ["Dark sky 19:39–06:19", "Dark sky 19:37–06:21", "Dark sky 19:35–06:23"]

    @Test(arguments: samples)
    func sampleCards(_ expected: Expected) throws {
        let state = try Self.threeNights(expected.sample)
        #expect(state.nights.map(\.tag) == expected.tags)
        #expect(state.nights.map(\.darkSky) == expected.darkSky)
        #expect(state.nights.map(\.sky) == expected.sky)
        #expect(Self.calendar(state) == expected.calendar)
        // Only the Best night's card has the button.
        #expect(state.nights.allSatisfy { $0.calendar == nil || $0.isBest })
        #expect(state.note == (expected.note ?? Self.groupNote(expected.group)))
        #expect(state.placeLine == Self.placeLine(expected.group))
        #expect(state.nights.map(\.storm) == expected.storm)
        // Slot storm marks only where the night has one.
        #expect(zip(state.nights, expected.storm).allSatisfy { night, storm in storm || night.slots.allSatisfy { !$0.storm } })
        // Full weekdays and long dates; slots only for nights with darkness, 4 to 6 of them.
        #expect(state.nights.allSatisfy { !$0.day.contains(" ") && $0.date.split(separator: " ").count == 2 })
        for night in state.nights {
            #expect(night.sky == nil ? night.slots.isEmpty : (4...6).contains(night.slots.count))
            // Yellow hours only under a clear Sky.
            #expect(night.slots.allSatisfy { $0.isClear == ($0.sky == .clear) })
        }
    }

    @Test func everySampleIsCovered() {
        let covered = Set(Self.samples.map(\.sample) + ["error-503"])
        #expect(Set(FixtureLibrary.names) == covered)
    }

    // MARK: Slots

    @Test("Slot spacing: 2 hours under 9, 3 up to 16, 4 above; 4 to 6 slots around solar midnight",
          arguments: [
              (5.0, 2.0, 4), (8.0, 2.0, 5), (9.0, 3.0, 4), (12.0, 3.0, 5), (15.0, 3.0, 6), (16.0, 3.0, 6),
              (17.0, 4.0, 5), (20.0, 4.0, 6), (24.0, 4.0, 6),
          ])
    func slotSpacing(_ hours: Double, _ step: Double, _ count: Int) {
        let midnight = TonightTests.date("2026-11-10T23:20:00Z")
        let span = Interval(start: midnight.addingTimeInterval(-hours * 1800), end: midnight.addingTimeInterval(hours * 1800))
        let times = ThreeNightsBuilder.slotTimes(span: span, solarMidnight: midnight, timeZone: .gmt)
        #expect(times.count == count)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == step * 3600 })
        // Whole hours, centred on solar midnight within half an hour.
        #expect(times.allSatisfy { Int($0.timeIntervalSince1970) % 3600 == 0 })
        let centre = times[0].addingTimeInterval(times.last!.timeIntervalSince(times[0]) / 2)
        #expect(abs(centre.timeIntervalSince(midnight)) <= 1800)
    }

    @Test("Tromsø in November: 6 slots 4 hours apart, 13 to 09 (Figma: 3 Nights)")
    func tromsoSlots() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Oslo"))
        let midnight = TonightTests.date("2026-11-10T22:20:00Z") // 23:20 local
        let span = Interval(start: TonightTests.date("2026-11-10T12:40:00Z"), end: TonightTests.date("2026-11-11T08:50:00Z"))
        let clock = CopyClock(timeZone: zone)
        let hours = ThreeNightsBuilder.slotTimes(span: span, solarMidnight: midnight, timeZone: zone).map { String(clock.time($0).prefix(2)) }
        #expect(hours == ["13", "17", "21", "01", "05", "09"])
    }

    @Test("Slots stay on whole local hours in a half-hour time zone and across a clock change")
    func slotsOnLocalHours() throws {
        let india = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let midnight = TonightTests.date("2026-11-10T18:40:00Z")
        let span = Interval(start: midnight.addingTimeInterval(-6 * 3600), end: midnight.addingTimeInterval(6 * 3600))
        let clock = CopyClock(timeZone: india)
        let times = ThreeNightsBuilder.slotTimes(span: span, solarMidnight: midnight, timeZone: india)
        #expect(times.allSatisfy { clock.time($0).hasSuffix(":00") })

        // Oslo, the night clocks go back (25 October 2026): every slot still on the hour.
        let oslo = try #require(TimeZone(identifier: "Europe/Oslo"))
        let night = TonightTests.date("2026-10-24T23:10:00Z")
        let times2 = ThreeNightsBuilder.slotTimes(span: Interval(start: night.addingTimeInterval(-7 * 3600),
                                                                  end: night.addingTimeInterval(7 * 3600)),
                                                  solarMidnight: night, timeZone: oslo)
        #expect(times2.count == 5)
        #expect(times2.allSatisfy { CopyClock(timeZone: oslo).time($0).hasSuffix(":00") })
    }

    @Test("A slot's Sky comes from its dark hours; unknown hours are never cloud",
          arguments: [
              ([WeatherFactor.favorable, .favorable], Sky.Kind.clear),
              ([.favorable, .notCovered], .clear),
              ([.obstructed, .obstructed], .cloudy),
              ([.obstructed, .favorable], .partlyCloudy),
              ([.mixed], .partlyCloudy),
              ([.notCovered, .stale], .unknown),
          ])
    func slotSky(_ weather: [WeatherFactor], _ sky: Sky.Kind) {
        #expect(ThreeNightsBuilder.sky(weather) == sky)
    }

    @Test("A short night still shows its clear hours in the slots around it")
    func shortNightSlots() throws {
        // Tuesday is dark only 00:02–01:27.
        let tuesday = try Self.threeNights("too-bright-tonight").nights[1]
        #expect(tuesday.slots.map(\.hour) == ["20", "23", "02", "05"])
        #expect(tuesday.slots.map(\.sky) == [nil, .clear, .clear, nil])
    }

    @Test("Where the weather forecast ends, the slots turn Unknown")
    func weatherHorizon() throws {
        let wednesday = try Self.threeNights("partial-third-night").nights[2]
        #expect(wednesday.slots.compactMap(\.sky).suffix(2) == [.unknown, .unknown])
    }

    @Test("Out of date: every dark slot Unknown, no yellow hours, no tags")
    func outOfDateSlots() throws {
        let state = try Self.threeNights("stale-weather")
        #expect(state.nights.allSatisfy { night in night.slots.allSatisfy { $0.sky == nil || $0.sky == .unknown } })
        #expect(state.nights.allSatisfy { $0.slots.allSatisfy { !$0.isClear } && $0.tag == nil })
        #expect(state.nights.allSatisfy { $0.calendar == nil })
    }

    // MARK: Tags

    @Test("Two clear later nights within 30 minutes tie: no Best tag, Skip stays, no calendar")
    func tie() throws {
        // Tonight cloudy; Tuesday and Wednesday differ by two minutes.
        let state = try Self.threeNights(Self.edited("promising-now") { night, _, segment in
            night == 0 ? "obstructed" : segment
        })
        #expect(state.nights.map(\.tag) == [.skip, nil, nil])
        #expect(state.nights.allSatisfy { $0.calendar == nil })
    }

    @Test("More than 30 minutes apart, the later night with more clear time is Best")
    func clearWinnerBeyondMargin() throws {
        // Tonight cloudy; Tuesday is clear until 05:54, Wednesday only until 00:00.
        let state = try Self.threeNights(Self.edited("partial-third-night") { night, _, segment in
            night == 0 ? "obstructed" : segment
        })
        #expect(state.nights.map(\.tag) == [.skip, .best, nil])
        #expect(Self.calendar(state) == "1 19:14")
    }

    @Test("A clear night beats a Mostly Cloudy one with more clear minutes")
    func clearBeatsMostlyCloudy() throws {
        // Tonight cloudy; Wednesday cloudy after 23:00, so it has some clear time but less
        // than half its dark time.
        let state = try Self.threeNights(Self.edited("promising-now") { night, start, segment in
            switch night {
            case 0: "obstructed"
            case 2: start < "2026-10-14T21:00" ? segment : "obstructed"
            default: segment
            }
        })
        #expect(state.nights.map(\.tag) == [.skip, .best, nil])
        #expect(state.nights[2].sky == .partlyCloudy)
    }

    @Test("One clear dark hour is a window; a night without one is Skip")
    func oneHourWindow() throws {
        // Only Wednesday 20:00–21:00 is clear.
        let state = try Self.threeNights(Self.edited("promising-now") { night, start, _ in
            night == 2 && start.hasPrefix("2026-10-14T18:00") ? "favorable" : "obstructed"
        })
        #expect(state.nights[2].tag == .best)
        #expect(state.nights[1].tag == .skip)
    }

    // MARK: Place groups

    @Test("Each place group has its place line and note; south adds Clear sky and storm marks")
    func groups() throws {
        let forecast = try ScreenStateTests.forecast("promising-now")
        let zone = try Self.threeNights(forecast, reach: AuroraReach(group: .underZone, kpLowInNorth: 1))
        #expect(zone.placeLine == "In Stockholm, aurora shows most clear nights, so the clearest night is the best one.")
        #expect(zone.note == "Clear, dark hours decide here. Aurora itself can only be known about 90 minutes ahead.")
        let edge = try Self.threeNights(forecast, reach: AuroraReach(group: .edge, kpLowInNorth: 3))
        #expect(edge.placeLine == "In Stockholm, aurora often shows low in the northern sky, so the clearest night is the best one.")
        #expect(edge.note == zone.note)
        // Under the zone and at the edge, storms are never marked.
        let marked = [zone, edge].flatMap(\.nights).filter { $0.storm || $0.tag == .clearSky }
        #expect(marked.isEmpty)
        let south = try Self.threeNights(forecast, reach: AuroraReach(group: .south, kpLowInNorth: 9.5))
        #expect(south.placeLine == "Aurora reaches here only in storms, so the best night is a clear one a storm could reach.")
        #expect(south.note == "Most of the time aurora comes without warning. It needs darkness and a clear sky.")
        // No storm reaches: Best as before, the other clear nights read Clear sky.
        #expect(south.nights.map(\.tag) == [.best, .clearSky, .clearSky])
    }

    @Test("South: the clear night a storm could reach is Best, even over a clear tonight")
    func southStorm() throws {
        // Kp 6 only over Wednesday night's bins.
        let forecast = try Self.editedKp("promising-now") { bin in
            let start = (bin["interval"] as! [String: String])["start"]!
            return start >= "2026-10-14T15:00" && start < "2026-10-15T06:00" ? 6 : 2
        }
        let state = try Self.threeNights(forecast, reach: AuroraReach(group: .south, kpLowInNorth: 5))
        #expect(state.nights.map(\.tag) == [.clearSky, .clearSky, .best])
        #expect(state.nights.map(\.storm) == [false, false, true])
        #expect(state.nights[2].slots.contains { $0.storm })
        #expect(state.nights[0].slots.allSatisfy { !$0.storm })
        #expect(Self.calendar(state) == "2 19:11")
    }

    @Test("South: the API's night outlook decides which nights a storm could reach")
    func southOutlookDecides() throws {
        // Kp 3 never reaches Edinburgh by the bins, but the outlook says Wednesday could.
        let forecast = try ScreenStateTests.forecast("south-not-expected") { json in
            Self.editPlanning(&json) { index, night in
                var outlook = night["auroraOutlook"] as! [String: Any]
                outlook["status"] = index == 2 ? "could_reach" : "not_expected"
                night["auroraOutlook"] = outlook
            }
        }
        let state = try Self.threeNights(forecast)
        #expect(state.nights.map(\.storm) == [false, false, true])
        #expect(state.nights.map(\.tag) == [.clearSky, .clearSky, .best])
        // A stale outlook marks no night, even where old bins would reach.
        let stale = try ScreenStateTests.forecast("south-could-reach") { json in
            Self.editPlanning(&json) { _, night in
                var outlook = night["auroraOutlook"] as! [String: Any]
                outlook["status"] = "stale"
                night["auroraOutlook"] = outlook
            }
        }
        #expect(try Self.threeNights(stale).nights.allSatisfy { !$0.storm })
    }

    // MARK: Calendar

    @Test("Add To Calendar: the event covers the Best night's clear window, from now if it has begun")
    func calendarEvent() throws {
        // Tonight and Tuesday cloudy, so Wednesday is the Best night.
        let state = try Self.threeNights(Self.edited("promising-now") { night, _, segment in
            night < 2 ? "obstructed" : segment
        })
        #expect(state.nights.map(\.tag) == [.skip, .skip, .best])
        let draft = try #require(state.nights[2].calendar)
        let wednesday = try #require(try ScreenStateTests.forecast("promising-now").planning[2].windows.first?.interval)
        // Whole minutes: 19:11 to 05:56.
        #expect(draft.start == TonightTests.date("2026-10-14T17:11:00Z"))
        #expect(draft.end == TonightTests.date("2026-10-15T03:56:00Z"))
        #expect(wednesday.start.timeIntervalSince(draft.start) < 60 && wednesday.end.timeIntervalSince(draft.end) < 60)
        #expect(draft.location == "Stockholm")
        #expect(Self.calendar(state) == "2 19:11")

        // Building the event reads nothing and asks for nothing: no access is requested.
        let store = EKEventStore()
        let event = draft.event(in: store)
        #expect(event.title == "Look for the aurora")
        #expect(event.startDate == draft.start && event.endDate == draft.end)
        #expect(event.location == "Stockholm")
        #expect(event.notes == "Give your eyes 20 minutes to adjust. A Zorja outlook, not a promise.")
        #expect(event.timeZone?.identifier == "Europe/Stockholm")
    }

    @Test("The app never declares calendar access: the system sheet needs none")
    func noCalendarPermission() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription"] {
            #expect(info[key] == nil)
        }
    }

    @Test("Long dates: 1st, 2nd, 3rd, 11th, 12th, 13th, 21st, 22nd")
    func longDates() throws {
        let clock = CopyClock(timeZone: .gmt)
        let days = [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31]
        let dates = days.map { clock.longDate(TonightTests.date(String(format: "2026-12-%02dT12:00:00Z", $0))) }
        #expect(dates == ["1st December", "2nd December", "3rd December", "4th December", "11th December",
                          "12th December", "13th December", "21st December", "22nd December", "23rd December",
                          "31st December"])
    }

    // MARK: App states

    @Test("Loading: the next three nights by name, Checking, no tags, Sky or slots")
    func loading() throws {
        let now = TonightTests.date("2026-11-10T19:14:00Z")
        let state = try #require(ScreenState.make(ScreenInput(place: "Tromsø"), now: now).threeNights)
        #expect(state.nights.map(\.darkSky) == ["Checking", "Checking", "Checking"])
        #expect(state.nights.allSatisfy { $0.tag == nil && $0.sky == nil && $0.slots.isEmpty })
        #expect(state.nights.allSatisfy { $0.calendar == nil } && state.placeLine == nil)
    }

    @Test("Offline without a forecast and errors show Now's message")
    func appStatesWithoutList() {
        #expect(ScreenState.make(ScreenInput(problem: .unavailable, place: "Tromsø"), now: .now).threeNights == nil)
        #expect(ScreenState.make(ScreenInput(problem: .offline, place: "Tromsø"), now: .now).threeNights == nil)
    }

    @Test("Offline with a current forecast: the Best night keeps Add To Calendar")
    func offlineKeepsCalendar() throws {
        let forecast = try ScreenStateTests.forecast("promising-now")
        let input = ScreenInput(forecast: forecast, problem: .offline, place: "Stockholm")
        let state = try #require(ScreenState.make(input, now: forecast.generatedAt).threeNights)
        #expect(Self.calendar(state) == "0 23:00")
    }

    @Test("A forecast past refreshAfter: out of date, no Best night")
    func expired() throws {
        let forecast = try ScreenStateTests.forecast("promising-now")
        let state = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.refreshAfter).threeNights)
        #expect(state.nights.allSatisfy { $0.tag == nil && $0.sky == .unknown })
        #expect(state.note?.hasPrefix("Updated ") == true)
        #expect(state.nights.allSatisfy { $0.calendar == nil })
    }

    // MARK: Helpers

    /// "2 23:43": which card has Add To Calendar and the event's local start; nil without one.
    static func calendar(_ state: ThreeNightsState) -> String? {
        let cards = state.nights.enumerated().filter { $0.element.calendar != nil }
        guard let card = cards.first, let draft = card.element.calendar else { return nil }
        #expect(cards.count == 1)
        return "\(card.offset) \(CopyClock(timeZone: draft.timeZone).time(draft.start))"
    }

    static func threeNights(_ sample: String) throws -> ThreeNightsState {
        try threeNights(try ScreenStateTests.forecast(sample))
    }

    static func threeNights(_ forecast: Forecast) throws -> ThreeNightsState {
        try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).threeNights)
    }

    /// With a place group other than the sample's own.
    static func threeNights(_ forecast: Forecast, reach: AuroraReach) throws -> ThreeNightsState {
        let words = ForecastWords(forecast: forecast, now: forecast.generatedAt, nextCheck: nil)
        let kind = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).kind
        return ThreeNightsBuilder(words: words, kind: kind, place: "Stockholm", reach: reach).state()
    }

    static func editPlanning(_ json: inout [String: Any], _ change: (Int, inout [String: Any]) -> Void) {
        var planning = json["planning"] as! [[String: Any]]
        for index in planning.indices { change(index, &planning[index]) }
        json["planning"] = planning
    }

    /// Changes each dark segment's weather: (night index, segment start, weather) → weather.
    static func edited(_ sample: String, _ weather: @escaping (Int, String, String) -> String) throws -> Forecast {
        try ScreenStateTests.forecast(sample) { json in
            editPlanning(&json) { index, night in
                var windows = night["windows"] as! [[String: Any]]
                for w in windows.indices {
                    var segments = windows[w]["segments"] as! [[String: Any]]
                    for s in segments.indices {
                        let start = (segments[s]["interval"] as! [String: String])["start"]!
                        var factors = segments[s]["factors"] as! [String: Any]
                        factors["weather"] = weather(index, start, factors["weather"] as! String)
                        segments[s]["factors"] = factors
                    }
                    windows[w]["segments"] = segments
                }
                night["windows"] = windows
            }
        }
    }

    static func editedKp(_ sample: String, _ kp: @escaping ([String: Any]) -> Double) throws -> Forecast {
        try ScreenStateTests.forecast(sample) { json in
            editPlanning(&json) { _, night in
                var context = night["globalKpContext"] as! [String: Any]
                context["bins"] = (context["bins"] as! [[String: Any]]).map { bin in
                    var bin = bin
                    bin["kp"] = kp(bin)
                    return bin
                }
                night["globalKpContext"] = context
            }
        }
    }
}
