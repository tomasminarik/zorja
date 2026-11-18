import Foundation
import Testing
@testable import Zorja

/// Tonight's words and strip for every sample; the strip's ends, each hour's circle, a clock
/// change, the live aurora limit and the legend's tense when the readout is swiped.
@Suite("Tonight")
struct TonightTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let sample: String
        let headline: String
        let lead: String
        let note: String
        var card: TonightCard?
        var placeLine: String? = edge
        var testDescription: String { sample }
    }

    static let edge = "In Stockholm, aurora often shows low in the northern sky, and overhead on active nights."
    static let underZone = "In Stockholm, aurora shows overhead on most clear, dark nights."

    static let go = "Dark, clear and aurora active overhead since at least 22:55."
    static let clearOn = "Aurora is on, and the sky is clear."
    static let tooBrightOn = "Aurora is on, but it’s too bright to see it."
    static let outOfDate = "Zorja can’t get fresh data right now. Don’t rely on the last forecast."

    // Times are Europe/Stockholm, read at each sample's own generatedAt.
    static let samples: [Expected] = [
        .init(sample: "promising-now", headline: "Go Out Right Now.", lead: go, note: clearOn, card: .giveYourEyes),
        // Edinburgh (Europe/London): the place line follows tonight's storm outlook.
        .init(sample: "south-could-reach", headline: "Go Out Right Now.",
              lead: "Dark, clear and aurora active overhead since at least 21:55.", note: clearOn, card: .giveYourEyes,
              placeLine: "A storm forecast tonight could bring aurora this far south."),
        .init(sample: "south-not-expected", headline: "Go Out Right Now.",
              lead: "Dark, clear and aurora active overhead since at least 21:55.", note: clearOn, card: .giveYourEyes,
              placeLine: "No storm is forecast to reach here tonight. Aurora can still come without warning."),
        .init(sample: "partial-third-night", headline: "Go Out Right Now.", lead: go, note: clearOn, card: .giveYourEyes),
        .init(sample: "after-midnight-current-night", headline: "Go Out Right Now.",
              lead: "Dark, clear and aurora active overhead since at least 02:55.", note: clearOn, card: .giveYourEyes),
        .init(sample: "disjoint-darkness", headline: "Go Out Right Now.",
              lead: "Dark, clear and aurora active overhead since at least 12:55.", note: clearOn, card: .giveYourEyes,
              placeLine: underZone),
        .init(sample: "polar-night", headline: "Go Out Right Now.", lead: "It’s polar night, dark all day. Clear until 12:00.",
              note: clearOn, card: .giveYourEyes, placeLine: underZone),
        // Daytime: the strip, from now through tonight, and the tips card for the dark time ahead.
        .init(sample: "daylight-next-window", headline: "Go Out At 19:17.", lead: "It’s too bright to see anything now.",
              note: tooBrightOn, card: .giveYourEyes),
        .init(sample: "morning-finished-night", headline: "Go Out At 19:14.", lead: "It’s too bright to see anything now.",
              note: tooBrightOn, card: .giveYourEyes),
        // The next three nights are just as cloudy, so there is no "Looks Clearer" card.
        .init(sample: "cloud-blocked", headline: "Skip Tonight.", lead: "Thick cloud all night, whatever the aurora does.",
              note: "Aurora is on, but clouds cover it."),
        .init(sample: "midnight-sun", headline: "Too Bright All Night.", lead: "The sun stays too high here for aurora to show.",
              note: "Too bright all night.", placeLine: underZone),
        .init(sample: "too-bright-tonight", headline: "Too Bright Tonight.", lead: "It doesn’t get dark enough here tonight.",
              note: tooBrightOn, placeLine: underZone),
        .init(sample: "limited-clouds", headline: "Partly Cloudy.", lead: "Cloud comes and goes. Watch for gaps.",
              note: "Aurora is on, with gaps in the clouds.", card: .giveYourEyes),
        .init(sample: "low-activity", headline: "Aurora Not Known.", lead: "It’s dark and clear, but there’s no live aurora data for here.",
              note: "Clear and dark. No live aurora data here.", card: .giveYourEyes),
        .init(sample: "weather-missing", headline: "Clouds Not Known.", lead: "There’s no cloud forecast for this place right now.",
              note: "Aurora is on. No cloud forecast here right now."),
        .init(sample: "weather-unavailable", headline: "Can’t Check Right Now.",
              lead: "Some of the data Zorja needs isn’t available. It tries again soon.", note: "Weather not known yet.", card: .giveYourEyes),
        .init(sample: "stale-weather", headline: "Out Of Date Since 16:00.", lead: outOfDate,
              note: "Updated 16:00. Cloud and aurora are hidden until fresh data arrives."),
        .init(sample: "stale-aurora", headline: "Out Of Date Since 22:10.", lead: outOfDate,
              note: "Updated 22:10. Cloud and aurora are hidden until fresh data arrives."),
    ]

    @Test("South: without a current storm outlook, tonight's isn't known yet")
    func southOutlookNotKnown() throws {
        for status in ["not_known_yet", "stale", "unavailable"] {
            let forecast = try ScreenStateTests.forecast("south-could-reach") { json in
                ThreeNightsTests.editPlanning(&json) { _, night in
                    var outlook = night["auroraOutlook"] as! [String: Any]
                    outlook["status"] = status
                    night["auroraOutlook"] = outlook
                }
            }
            let tonight = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Edinburgh"), now: forecast.generatedAt).tonight)
            #expect(tonight.placeLine == "Tonight’s storm forecast isn’t known yet.")
        }
    }

    @Test(arguments: samples)
    func sampleWords(_ expected: Expected) throws {
        let tonight = try Self.tonight(expected.sample)
        #expect(tonight.headline.text == expected.headline)
        #expect(tonight.lead == expected.lead)
        #expect(tonight.strip.note(at: tonight.strip.now) == expected.note)
        #expect(tonight.card == expected.card)
        #expect(tonight.placeLine == expected.placeLine)
        #expect(tonight.strip.timeStamp(tonight.strip.now).hasPrefix("Now "))
        // Only midnight sun hides the strip.
        #expect(tonight.tooBright == (expected.sample == "midnight-sun"))
        // The readout always has a circle under it.
        #expect(tonight.strip.focus(at: tonight.strip.now).map { tonight.strip.hours[$0].contains(tonight.strip.now) } == true)
        // Only times are underlined.
        if let emphasis = tonight.headline.emphasis {
            #expect(tonight.headline.text.contains(emphasis) && emphasis.wholeMatch(of: /\d\d:\d\d/) != nil)
        }
        if !tonight.headline.text.contains(":") { #expect(tonight.headline.emphasis == nil) }
    }

    @Test func everySampleIsCovered() {
        #expect(Set(FixtureLibrary.names) == Set(Self.samples.map(\.sample) + ["error-503"]))
    }

    @Test("Wait: go out when the cloud clears")
    func waitForCloud() throws {
        // promising-now with cloud now and the clear stretch starting at 01:00.
        let forecast = try ScreenStateTests.forecast("promising-now") { json in
            ScreenStateTests.editNow(&json) { now in
                now["action"] = "wait"
                now["reasons"] = [["code": "cloud_obstruction", "effect": "blocker", "message": "x", "sourceId": NSNull()]]
            }
            var planning = json["planning"] as! [[String: Any]]
            var windows = planning[0]["windows"] as! [[String: Any]]
            var segments = windows[0]["segments"] as! [[String: Any]]
            for index in segments.indices where (segments[index]["interval"] as! [String: String])["start"]! < "2026-10-12T23:00:00Z" {
                var factors = segments[index]["factors"] as! [String: Any]
                factors["weather"] = "obstructed"
                segments[index]["factors"] = factors
            }
            windows[0]["segments"] = segments
            planning[0]["windows"] = windows
            json["planning"] = planning
        }
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .wait)
        let tonight = try #require(state.tonight)
        #expect(tonight.headline == Phrase("Go Out At 01:00.", emphasis: "01:00"))
        #expect(tonight.lead == "It’s too cloudy to see anything now.")
        #expect(tonight.strip.note(at: tonight.strip.now) == "Aurora is on, but clouds cover it.")
        #expect(tonight.strip.clear.first?.start == Self.date("2026-10-12T23:00:00Z"))
    }

    // MARK: Strip ends and circles

    @Test("The strip runs hour by hour from sunset to sunrise")
    func sunsetToSunrise() throws {
        let forecast = try ScreenStateTests.forecast("promising-now")
        let strip = try Self.tonight("promising-now").strip
        let span = try #require(strip.span)
        let place = forecast.location
        // Stockholm, 12–13 October: the sun sets about 17:42 and rises about 07:27.
        #expect(abs(SolarPosition.altitude(at: span.start, latitude: place.latitude, longitude: place.longitude)) < 0.05)
        #expect(abs(span.start.timeIntervalSince(Self.date("2026-10-12T15:42:00Z"))) < 5 * 60)
        #expect(abs(span.end.timeIntervalSince(Self.date("2026-10-13T05:27:00Z"))) < 5 * 60)
        // The hours holding sunset and sunrise, every one an hour after the last.
        #expect(strip.hours.first?.label == "17" && strip.hours.last?.label == "07")
        #expect(strip.hours.first!.contains(span.start) && strip.hours.last!.contains(span.end))
        #expect(zip(strip.hours, strip.hours.dropFirst()).allSatisfy { $1.start == $0.end })
    }

    @Test("Polar night: the strip runs noon to noon, no daylight")
    func polarNightNoonToNoon() throws {
        let forecast = try ScreenStateTests.forecast("polar-night")
        let strip = try Self.tonight("polar-night").strip
        #expect(strip.span == forecast.planning[0].period)
        #expect(strip.hours.count == 24)
        // The sun never rises; around noon it is only twilight.
        #expect(!strip.hours.contains { $0.sky == .daylight })
        #expect(strip.hours.filter { $0.start >= strip.now }.allSatisfy { $0.sky == .clear })
    }

    @Test("Midnight sun: too bright, nothing to swipe")
    func midnightSun() throws {
        let tonight = try Self.tonight("midnight-sun")
        #expect(tonight.tooBright && tonight.card == nil)
        #expect(tonight.strip.dark.isEmpty && tonight.strip.clear.isEmpty && tonight.strip.aurora == nil)
        #expect(tonight.strip.hours.allSatisfy { $0.sky == .twilight || $0.sky == .daylight })
        #expect(!tonight.strip.canSwipe)
    }

    @Test("Each hour's circle: daylight and twilight at the ends, the sky over the dark hours, dashed before the forecast starts, aurora within live data")
    func hourCircles() throws {
        let strip = try Self.tonight("promising-now").strip
        let skies = strip.hours.map(\.sky)
        // Now is 23:00 local; dark (−12°) from about 19:20 to 05:52, clear from now.
        #expect(Array(skies.prefix(6)) == [.daylight, .twilight, .unknown, .unknown, .unknown, .unknown])
        #expect(Array(skies[6...12]) == Array(repeating: .clear, count: 7))
        #expect(Array(skies.suffix(2)) == [.twilight, .daylight])
        #expect(strip.hours.filter(\.aurora).allSatisfy { hour in strip.aurora.map { $0.start < hour.end && hour.start < $0.end } ?? false })
        #expect(strip.hours.contains { $0.aurora && $0.contains(strip.now) })
    }

    @Test("Gaps in the cloud, cloud and unknown weather each get their own circle")
    func mixedSkies() throws {
        #expect(try Self.tonight("limited-clouds").strip.hours.contains { $0.sky == .partlyCloudy })
        let cloudy = try Self.tonight("cloud-blocked").strip
        #expect(cloudy.hours.filter { $0.end > cloudy.now && cloudy.isDark($0.start.addingTimeInterval(1800)) }
            .allSatisfy { $0.sky == .cloudy })
        #expect(try Self.tonight("weather-missing").strip.hours.contains { $0.sky == .unknown })
    }

    @Test("A night when the clocks go back: a real hour each, 02 twice")
    func clockChange() throws {
        // promising-now moved to 24–25 October 2026; Stockholm goes from UTC+2 to UTC+1 at 03:00.
        let forecast = try ScreenStateTests.forecast("promising-now") { json in
            json = ScreenStateTests.shifted(json, by: 12 * 86400) as! [String: Any]
        }
        let tonight = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).tonight)
        let strip = tonight.strip
        let labels = strip.hours.map(\.label)
        #expect(labels.filter { $0 == "02" }.count == 2)
        #expect(zip(strip.hours, strip.hours.dropFirst()).allSatisfy { $1.start.timeIntervalSince($0.start) == 3600 })
        #expect(strip.timeStamp(strip.latest) == "04:52")
    }

    @Test("Times are the place's own, whatever the phone's timezone")
    func placeTimezone() throws {
        let forecast = try ScreenStateTests.forecast("promising-now") { json in
            var location = json["location"] as! [String: Any]
            location["timezone"] = "America/Toronto"
            json["location"] = location
        }
        let tonight = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Toronto"), now: forecast.generatedAt).tonight)
        #expect(tonight.strip.timeStamp(tonight.strip.now) == "Now 17:00")
    }

    @Test("Hour slots sit 8 pt apart; the Focus slot is 30 pt wider")
    func stripGeometry() {
        #expect(HourTimeline.pitch == 66)
        // Slots 0–4 are Regular (5 × 66 = 330), then the 88 pt Focus slot centred at 374.
        #expect(HourTimeline.centre(of: 5, focus: 5) == 374)
        #expect(HourTimeline.centre(of: 6, focus: 5) == 455)  // 330 + 88 + 8 = 426, + 29
        #expect(HourTimeline.centre(of: 4, focus: 5) == 293)
    }

    @Test("Figma: Hour timeline is 159 pt: the 22 pt time, 10 pt, the 110 pt slots, 16 pt and the 1 pt hairline")
    func timelineHeight() {
        #expect(HourSlot.height == 110)
        #expect(HourTimeline.stripHeight == 127)
        #expect(22 + HourTimeline.timeGap + HourTimeline.stripHeight == 159)
        #expect(TonightForecast.legendGap == 30)
    }

    @Test("The tips card is dropped when it would need scrolling, as on 375 pt iPhones")
    func tipsCardFits() {
        // Figma: 431 pt between the top and the menu on the 402 pt frame, 341 for the Body.
        #expect(TonightScreen.showsCard(visible: 431, forecast: 237, card: 74))
        // Small iPhone: about 233 pt for the Body.
        #expect(!TonightScreen.showsCard(visible: 233, forecast: 237, card: 74))
    }

    // MARK: Needle and note

    @Test("The readout moves in 5-minute steps, never before now or past the dark time")
    func readoutLimits() throws {
        let strip = try Self.tonight("promising-now").strip
        #expect(strip.readout(hoursFromNow: -2) == strip.now)
        #expect(strip.readout(hoursFromNow: 0.02) == strip.now)
        #expect(strip.timeStamp(strip.readout(hoursFromNow: 1.07)) == "00:05")
        #expect(strip.readout(hoursFromNow: 20) == strip.latest)
        #expect(strip.latest == strip.dark.last?.end)
        #expect(strip.note(at: strip.latest) == "Clear and dark. Aurora can only be known about 90 minutes ahead.")
    }

    @Test("Every note the readout can reach is known up front, so the legend never changes height while swiping")
    func allNotesCoverTheSwipe() throws {
        let strip = try Self.tonight("promising-now").strip
        let notes = strip.allNotes
        #expect(Set(notes).count == notes.count)
        for minutes in stride(from: 0.0, through: strip.latest.timeIntervalSince(strip.now) / 60 + 5, by: 1) {
            #expect(notes.contains(strip.note(at: strip.readout(hoursFromNow: minutes / 60))))
        }
    }

    @Test("Live aurora reaches 90 minutes at most; the note says should within it and nothing beyond")
    func liveAuroraLimit() throws {
        // The newest prediction is 3 hours ahead, more than live data can say.
        let forecast = try ScreenStateTests.forecast("promising-now") { json in
            json["upcomingActivityInstant"] = ["forecastAt": "2026-10-13T00:00:00Z", "activity": "supported"]
        }
        let strip = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).tonight?.strip)
        #expect(strip.liveEnd == strip.now.addingTimeInterval(90 * 60))
        #expect(strip.aurora == Interval(start: strip.now, end: strip.now.addingTimeInterval(90 * 60)))
        #expect(strip.note(at: strip.readout(hoursFromNow: 1)) == "Aurora should stay on, and the sky will be clear.")
        #expect(strip.note(at: strip.readout(hoursFromNow: 1.5)) == "Aurora should stay on, and the sky will be clear.")
        #expect(strip.note(at: strip.readout(hoursFromNow: 1.6)) == "Clear and dark. Aurora can only be known about 90 minutes ahead.")
        // Circles carry the ring only for the hours live data reaches.
        #expect(strip.hours.filter(\.aurora).count == 2)
        #expect(strip.legend(at: strip.now)?.title == "Aurora, Clear Sky")
        #expect(strip.legend(at: strip.readout(hoursFromNow: 2.5))?.title == "Clear And Dark")
    }

    @Test("Within live data the note says should be when aurora changes, and will for the sky")
    func noteTense() throws {
        func strip(now activity: String, later: String, weather: String) throws -> TonightStrip {
            let forecast = try ScreenStateTests.forecast("promising-now") { json in
                json["upcomingActivityInstant"] = ["forecastAt": "2026-10-12T22:00:00Z", "activity": later]
                ScreenStateTests.editNow(&json) { now in
                    var factors = now["factors"] as! [String: Any]
                    factors["activity"] = activity
                    now["factors"] = factors
                }
                var planning = json["planning"] as! [[String: Any]]
                var windows = planning[0]["windows"] as! [[String: Any]]
                windows[0]["segments"] = (windows[0]["segments"] as! [[String: Any]]).map { segment in
                    var segment = segment, factors = segment["factors"] as! [String: Any]
                    factors["weather"] = weather
                    segment["factors"] = factors
                    return segment
                }
                planning[0]["windows"] = windows
                json["planning"] = planning
            }
            return try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).tonight?.strip)
        }
        let soon = 0.5
        #expect(try strip(now: "supported", later: "low", weather: "favorable").note(at: strip(now: "supported", later: "low", weather: "favorable").readout(hoursFromNow: soon))
                == "Clear and dark, but aurora should be quiet.")
        let cloudy = try strip(now: "supported", later: "supported", weather: "obstructed")
        #expect(cloudy.note(at: cloudy.readout(hoursFromNow: soon)) == "Aurora should stay on, but clouds will cover it.")
        #expect(cloudy.note(at: cloudy.readout(hoursFromNow: 3)) == "Cloudy.")
        let quiet = try strip(now: "low", later: "low", weather: "mixed")
        #expect(quiet.note(at: quiet.now) == "Some gaps in the clouds. Aurora is quiet.")
        #expect(quiet.note(at: quiet.readout(hoursFromNow: soon)) == "Some gaps in the clouds. Aurora should stay quiet.")
        #expect(quiet.note(at: quiet.readout(hoursFromNow: 3)) == "Some gaps in the clouds. Aurora can only be known about 90 minutes ahead.")
        #expect(quiet.aurora == nil)
        // The legend: the hour's circle, its title, the note in the readout's tense.
        let behind = try #require(cloudy.legend(at: cloudy.readout(hoursFromNow: soon)))
        #expect(behind.title == "Aurora Behind Cloud" && behind.aurora && behind.sky == .cloudy)
        #expect(behind.note == "Aurora should stay on, but clouds will cover it.")
        #expect(cloudy.legend(at: cloudy.now)?.note == "Aurora is on, but clouds cover it.")
        #expect(quiet.legend(at: quiet.now)?.title == "Gaps In Cloud")
        let rising = try strip(now: "low", later: "supported", weather: "favorable")
        #expect(rising.note(at: rising.readout(hoursFromNow: soon)) == "Aurora should be on, and the sky will be clear.")
    }

    @Test("Daytime: too bright until dark, then the night ahead")
    func daytimeSwipe() throws {
        let strip = try Self.tonight("daylight-next-window").strip
        #expect(strip.aurora == nil)
        #expect(strip.note(at: strip.readout(hoursFromNow: 4)) == "Too bright until 19:17.")
        #expect(strip.note(at: strip.readout(hoursFromNow: 10)) == "Clear and dark. Aurora can only be known about 90 minutes ahead.")
    }

    // MARK: States

    @Test("Out of date: dashed circles over the dark hours, no aurora, the readout stays at now")
    func outOfDate() throws {
        let forecast = try ScreenStateTests.forecast("promising-now")
        let tonight = try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.refreshAfter).tonight)
        #expect(tonight.headline.text == "Out Of Date Since 23:00.")
        #expect(tonight.strip.note(at: tonight.strip.now) == "Updated 23:00. Cloud and aurora are hidden until fresh data arrives.")
        #expect(tonight.strip.clear.isEmpty && tonight.strip.aurora == nil && !tonight.strip.dark.isEmpty)
        #expect(tonight.strip.hours.allSatisfy { [.unknown, .twilight, .daylight].contains($0.sky) && !$0.aurora })
        #expect(tonight.strip.hours.contains { $0.sky == .unknown })
        #expect(tonight.strip.legend(at: tonight.strip.now)?.title == "Out Of Date")
        #expect(!tonight.strip.canSwipe && tonight.card == nil)
    }

    @Test("Loading: empty circles around now, no legend, Checking the sky")
    func loading() throws {
        let state = ScreenState.make(ScreenInput(place: "Tromsø"), now: Self.date("2026-11-20T21:14:00Z"))
        let tonight = try #require(state.tonight)
        #expect(tonight.headline.text == "Checking The Sky.")
        #expect(tonight.lead == "Looking at darkness, clouds and aurora over Tromsø.")
        #expect(tonight.strip.note(at: tonight.strip.now) == "Checking the sky.")
        // Figma: 15 to 06 at 20:14, the hour under the readout the sixth.
        #expect(tonight.strip.span == nil && tonight.strip.hours.count == 16 && tonight.strip.hours.allSatisfy { $0.sky == .loading })
        #expect(tonight.strip.focus(at: tonight.strip.now) == 5)
        #expect(tonight.strip.legend(at: tonight.strip.now) == nil)
        #expect(!tonight.strip.canSwipe && tonight.card == nil)
    }

    @Test("Errors and offline without a forecast show Now's message on Tonight")
    func appStatesWithoutTonight() {
        #expect(ScreenState.make(ScreenInput(problem: .unavailable, place: "Tromsø"), now: .now).tonight == nil)
        #expect(ScreenState.make(ScreenInput(problem: .offline, place: "Tromsø"), now: .now).tonight == nil)
    }

    @Test("The sun's altitude: Stockholm at the June solstice noon, and below the horizon at midnight")
    func solarAltitude() {
        let noon = SolarPosition.altitude(at: Self.date("2026-06-21T11:00:00Z"), latitude: 59.33, longitude: 18.07)
        #expect(abs(noon - 54.1) < 0.3)
        let midnight = SolarPosition.altitude(at: Self.date("2026-12-21T23:00:00Z"), latitude: 59.33, longitude: 18.07)
        #expect(midnight < -50)
    }

    // MARK: Helpers

    static func tonight(_ sample: String) throws -> TonightState {
        let forecast = try ScreenStateTests.forecast(sample)
        return try #require(ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt).tonight)
    }

    static func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
}
