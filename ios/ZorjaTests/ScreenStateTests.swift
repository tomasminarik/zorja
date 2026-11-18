import Foundation
import Testing
@testable import Zorja

/// Every sample in `api/examples` against the Figma state it should show. The samples are
/// read at their own `generatedAt`, as the developer menu's "show as unexpired" switch does.
struct ScreenStateTests {
    struct Expected: Sendable, CustomTestStringConvertible {
        let sample: String
        let kind: ScreenKind
        let sky: SkyLevel
        let headline: String
        let bottom: String?
        var testDescription: String { sample }
    }

    // Times are Europe/Stockholm: summer time (UTC+2) in October and June, UTC+1 in December.
    static let samples: [Expected] = [
        .init(sample: "promising-now", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 05:52."),
        // Edinburgh, Europe/London.
        .init(sample: "south-could-reach", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 06:19."),
        .init(sample: "south-not-expected", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 06:19."),
        .init(sample: "partial-third-night", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 05:52."),
        .init(sample: "after-midnight-current-night", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 05:52."),
        .init(sample: "disjoint-darkness", kind: .go, sky: .full,
              headline: "Go Out Right Now.", bottom: "Tonight Best Until 07:45."),
        .init(sample: "polar-night", kind: .polarNight, sky: .full,
              headline: "Go Out Right Now.", bottom: "Today Best Until 12:00."),
        .init(sample: "daylight-next-window", kind: .daytime, sky: .off,
              headline: "Too Bright Until 19:17.", bottom: "Tonight Best 19:17–05:52."),
        .init(sample: "morning-finished-night", kind: .daytime, sky: .off,
              headline: "Too Bright Until 19:14.", bottom: "Tonight Best 19:14–05:54."),
        .init(sample: "cloud-blocked", kind: .skip, sky: .off,
              headline: "Skip Tonight.", bottom: "Next 3 Nights Look Cloudy."),
        .init(sample: "midnight-sun", kind: .midnightSun, sky: .off,
              headline: "Too Bright All Night.", bottom: "Next 3 Nights No Darkness."),
        // Tromsø on 31 August: `wait` for darkness that returns on Tuesday night, not tonight.
        .init(sample: "too-bright-tonight", kind: .tooBrightTonight, sky: .off,
              headline: "Too Bright Tonight.", bottom: "Tuesday Gets Dark."),
        .init(sample: "limited-clouds", kind: .partlyCloudy, sky: .partlyCloudy,
              headline: "Partly Cloudy.", bottom: "Tonight Dark Until 05:52."),
        // Despite its name, the sample's activity is `unknown` with `activity_not_covered`,
        // which App copy maps to "Aurora Not Known.", not to the low-activity blocker.
        .init(sample: "low-activity", kind: .auroraUnknown, sky: .off,
              headline: "Aurora Not Known.", bottom: "Look Up And Check."),
        .init(sample: "weather-missing", kind: .weatherUnknown, sky: .dim,
              headline: "Clouds Not Known.", bottom: "Look Up And Check."),
        .init(sample: "stale-aurora", kind: .outOfDate, sky: .off,
              headline: "Out Of Date Since 22:10.", bottom: "Checking Again At 23:05."),
        .init(sample: "stale-weather", kind: .outOfDate, sky: .off,
              headline: "Out Of Date Since 16:00.", bottom: "Checking Again At 23:05."),
        // `source_unavailable` has copy but no Figma frame.
        .init(sample: "weather-unavailable", kind: .cantCheck, sky: .off,
              headline: "Can’t Check Right Now.", bottom: "Checking Again At 23:05."),
    ]

    @Test(arguments: samples)
    func sampleMapsToFigmaState(_ expected: Expected) throws {
        let forecast = try Self.forecast(expected.sample)
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == expected.kind)
        #expect(state.sky == expected.sky)
        #expect(state.headline.text == expected.headline)
        #expect(state.bottomLine?.text == expected.bottom)
        #expect(state.retry == nil)
        if let emphasis = state.headline.emphasis { #expect(state.headline.text.contains(emphasis)) }
        if let bottom = state.bottomLine, let emphasis = bottom.emphasis { #expect(bottom.text.contains(emphasis)) }
        if let bottom = state.bottomLine, let subject = bottom.subject { #expect(bottom.text.hasPrefix(subject + " ")) }
    }

    @Test func everySampleIsCovered() {
        let covered = Set(Self.samples.map(\.sample) + ["error-503"])
        #expect(Set(FixtureLibrary.names) == covered)
    }

    @Test func errorSampleShowsTryAgain() throws {
        guard case .error(let error) = try FixtureLibrary.load("error-503") else {
            Issue.record("error-503 is not an error")
            return
        }
        #expect(error.code == .forecastUnavailable)
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ScreenState.make(ScreenInput(problem: .unavailable, nextCheck: retryAt, place: "Tromsø"), now: .now)
        #expect(state.kind == .error)
        #expect(state.sky == .off)
        #expect(state.headline == Phrase("Can’t Check Right Now.", emphasis: "Right Now"))
        #expect(state.lead == "Something went wrong on Zorja’s side. It isn’t your connection.")
        #expect(state.retry?.isEnabled(at: retryAt.addingTimeInterval(-1)) == false)
        #expect(state.retry?.isEnabled(at: retryAt) == true)
    }

    // MARK: Leads and status lines

    @Test func goWords() throws {
        let forecast = try Self.forecast("promising-now")
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.status == .updated("23:00"))
        #expect(state.lead == "Dark, clear and aurora active overhead since at least 22:55.")
        #expect(state.headline.emphasis == "Right Now")
        #expect(state.bottomLine?.emphasis == "05:52")
        #expect(state.auroraActive)
        // Without the buffer limit it is a plain "since"; without activeSince, no time.
        let since = try Self.forecast("promising-now") { json in
            var now = json["now"] as! [String: Any]
            now["activeSinceIsBufferLimited"] = false
            json["now"] = now
        }
        #expect(ScreenState.make(ScreenInput(forecast: since, place: "Stockholm"), now: since.generatedAt).lead
            == "Dark, clear and aurora active overhead since 22:55.")
        let older = try Self.forecast("promising-now") { json in
            var now = json["now"] as! [String: Any]
            now.removeValue(forKey: "activeSince")
            json["now"] = now
        }
        #expect(ScreenState.make(ScreenInput(forecast: older, place: "Stockholm"), now: older.generatedAt).lead
            == "Dark, clear and aurora active overhead.")
    }

    @Test("Quiet: under the zone and at the edge it often picks up; elsewhere it can pick up quickly")
    func quietLeadByGroup() throws {
        func lead(_ sample: String, group: String?) throws -> String {
            let forecast = try Self.forecast(sample) { json in
                if let group {
                    var reach = json["auroraReach"] as! [String: Any]
                    reach["group"] = group
                    json["auroraReach"] = reach
                } else {
                    json.removeValue(forKey: "auroraReach")
                }
            }
            return ForecastWords(forecast: forecast, now: forecast.generatedAt, nextCheck: nil).words(for: .quiet).1
        }
        let often = "Dark and clear, but there’s little aurora overhead. It often picks up here."
        let quickly = "Dark and clear, but there’s little aurora overhead. It can pick up quickly."
        #expect(try lead("promising-now", group: "edge") == often)
        #expect(try lead("promising-now", group: "under_zone") == often)
        #expect(try lead("promising-now", group: "south") == quickly)
        #expect(try lead("promising-now", group: nil) == quickly)
    }

    @Test func polarNightLead() throws {
        let forecast = try Self.forecast("polar-night")
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Longyearbyen"), now: forecast.generatedAt)
        #expect(state.lead == "It’s polar night, dark all day. Clear until 12:00, aurora active.")
        #expect(state.auroraActive)
    }

    @Test func daytimeLeadNamesActiveAuroraOnlyWhenSupported() throws {
        let forecast = try Self.forecast("daylight-next-window")
        #expect(forecast.upcomingActivityInstant?.activity == .supported)
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.lead == "Aurora is active, but daylight hides it. Tonight is checked on its own.")
        #expect(!state.auroraActive)

        let unknown = try Self.forecast("daylight-next-window") { json in
            var instant = json["upcomingActivityInstant"] as! [String: Any]
            instant["activity"] = "unknown"
            json["upcomingActivityInstant"] = instant
        }
        let quiet = ScreenState.make(ScreenInput(forecast: unknown, place: "Stockholm"), now: unknown.generatedAt)
        #expect(quiet.lead == "Daylight hides any aurora. Tonight is checked on its own.")
    }

    @Test func staleDataShowsLastUpdate() throws {
        let forecast = try Self.forecast("stale-weather")
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.status == .lastUpdate("16:00"))
        #expect(state.lead == "Zorja can’t get fresh data right now. Don’t rely on the last forecast.")
    }

    @Test func checkingAgainWaitsForTheRequestFloor() throws {
        let forecast = try Self.forecast("stale-aurora")
        let floor = forecast.refreshAfter.addingTimeInterval(10 * 60)
        let state = ScreenState.make(ScreenInput(forecast: forecast, nextCheck: floor, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.bottomLine?.text == "Checking Again At 23:15.")
    }

    // MARK: App states

    @Test func loading() {
        let state = ScreenState.make(ScreenInput(place: "Tromsø"), now: .now)
        #expect(state.kind == .loading)
        #expect(state.sky == .full)
        #expect(state.status == nil)
        #expect(state.headline == Phrase("Checking The Sky.", emphasis: "The Sky"))
        #expect(state.lead == "Looking at darkness, clouds and aurora over Tromsø.")
    }

    @Test func offlineWithCurrentForecastKeepsTheScreen() throws {
        let forecast = try Self.forecast("promising-now")
        let state = ScreenState.make(ScreenInput(forecast: forecast, problem: .offline, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .go)
        #expect(state.sky == .full)
        #expect(state.status == .offline(updated: "23:00"))
    }

    @Test func offlineWithoutCurrentForecast() throws {
        let none = ScreenState.make(ScreenInput(problem: .offline, place: "Stockholm"), now: .now)
        #expect(none.kind == .offlineNoForecast)
        #expect(none.sky == .off)
        #expect(none.status == nil)
        #expect(none.headline.text == "No Connection.")
        #expect(none.lead == "Your phone is offline, so Zorja can’t check the sky. It tries again when you’re back online.")

        let forecast = try Self.forecast("promising-now")
        let expired = ScreenState.make(
            ScreenInput(forecast: forecast, problem: .offline, place: "Stockholm"), now: forecast.refreshAfter)
        #expect(expired.kind == .offlineNoForecast)
        #expect(expired.status == .lastUpdate("23:00"))
    }

    @Test func rateLimitedSaysWhen() {
        let retry = APITimestamp.parse("2026-10-12T21:06:00Z")!
        var input = ScreenInput(problem: .rateLimited, nextCheck: retry, place: "Stockholm")
        input.forecast = nil
        let state = ScreenState.make(input, now: retry.addingTimeInterval(-30))
        #expect(state.kind == .error)
        // Without a forecast the device's timezone is used.
        #expect(state.lead == "Zorja is busy. It tries again at \(CopyClock(timeZone: .current).time(retry)).")
        #expect(state.retry?.isEnabled(at: retry.addingTimeInterval(-30)) == false)
    }

    // MARK: Expiry and stale data

    /// A Go recommendation is withdrawn at `refreshAfter`, not one second later.
    @Test func goIsWithdrawnAtRefreshAfter() throws {
        let forecast = try Self.forecast("promising-now")
        let before = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.refreshAfter.addingTimeInterval(-1))
        #expect(before.kind == .go)
        let at = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.refreshAfter)
        #expect(at.kind == .outOfDate)
        #expect(at.sky == .off)
        #expect(!at.auroraActive)
        #expect(at.status == .lastUpdate("23:00"))
        #expect(at.headline.text == "Out Of Date Since 23:00.")
        #expect(at.bottomLine?.text == "Checking Again At 23:05.")
        // Nothing failed: the words say fresh data is on its way, not that Zorja can't get it.
        #expect(at.lead == ForecastWords.refreshingLead)
        #expect(at.tonight?.lead == ForecastWords.refreshingLead)
    }

    /// While the refresh runs there is no "Checking Again At" time to wait for.
    @Test func expiredForecastWhileRefreshing() throws {
        let forecast = try Self.forecast("promising-now")
        var input = ScreenInput(forecast: forecast, nextCheck: forecast.refreshAfter.addingTimeInterval(60), place: "Stockholm")
        input.refreshing = true
        let state = ScreenState.make(input, now: forecast.refreshAfter.addingTimeInterval(1))
        #expect(state.kind == .outOfDate)
        #expect(state.lead == ForecastWords.refreshingLead)
        #expect(state.bottomLine == nil)
    }

    @Test func failedRefreshOfExpiredForecastShowsError() throws {
        let forecast = try Self.forecast("promising-now")
        let state = ScreenState.make(
            ScreenInput(forecast: forecast, problem: .unavailable, place: "Stockholm"), now: forecast.refreshAfter)
        #expect(state.kind == .error)
        #expect(state.retry != nil)
    }

    // MARK: Timezone

    /// The night of 24–25 October 2026 crosses the end of summer time in Stockholm
    /// (03:00 CEST becomes 02:00 CET). The same sample, moved 12 days, keeps 23:00 at the
    /// start but ends at 04:52 instead of 05:52.
    @Test func nightAcrossTheEndOfSummerTime() throws {
        let forecast = try Self.forecast("promising-now") { json in json = Self.shifted(json, by: 12 * 86_400) as! [String: Any] }
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .go)
        #expect(state.status == .updated("23:00"))
        #expect(state.bottomLine?.text == "Tonight Best Until 04:52.")
    }

    @Test func copyClockUsesTheForecastTimezone() {
        let instant = APITimestamp.parse("2026-10-25T01:30:00Z")!
        #expect(CopyClock(timeZone: TimeZone(identifier: "Europe/Stockholm")!).time(instant) == "02:30")
        #expect(CopyClock(timeZone: TimeZone(identifier: "America/Toronto")!).time(instant) == "21:30")
        #expect(CopyClock(timeZone: TimeZone(identifier: "Europe/Stockholm")!).weekday(instant) == "Sunday")
    }

    // MARK: Figma states without a sample

    @Test func tooBrightTonightWords() throws {
        let forecast = try Self.forecast("too-bright-tonight")
        #expect(forecast.now.action == .wait)
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Tromsø"), now: forecast.generatedAt)
        #expect(state.headline == Phrase("Too Bright Tonight.", emphasis: "Tonight"))
        #expect(state.lead == "It doesn’t get dark enough here tonight.")
        #expect(state.bottomLine == Phrase("Tuesday Gets Dark.", emphasis: "Tuesday", subject: "Tuesday"))
        #expect(state.status == .updated("14:00"))
        #expect(!state.auroraActive)
    }

    // There is no sample with `twilight_too_bright`, `low_activity` or a `wait` for cloud.
    // The backend no longer emits `low_activity` (a weak signal becomes unknown activity),
    // so "Quiet Right Now." can't occur with the current model.
    // These tests change one sample in memory to check the words; api/examples is unchanged.

    @Test func twilightWithoutASample() throws {
        let forecast = try Self.forecast("daylight-next-window") { json in
            Self.editNow(&json) { now in
                now["reasons"] = (now["reasons"] as! [[String: Any]]).map { reason in
                    var reason = reason
                    if reason["code"] as? String == "daylight" { reason["code"] = "twilight_too_bright" }
                    return reason
                }
            }
        }
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .twilight)
        #expect(state.sky == .dim)
        #expect(state.headline == Phrase("Dark Enough At 19:17.", emphasis: "19:17"))
        #expect(state.lead == "It’s twilight now, still too bright for faint aurora.")
        #expect(state.bottomLine?.text == "Tonight Best 19:17–05:52.")
    }

    @Test func skipForCloudWhileStillTwilight() throws {
        // Live answer for Tromsø at dusk: skip, with twilight listed before cloud, and a dark
        // window later tonight. Cloud is the reason to skip, so it isn't "Too Bright Tonight."
        let forecast = try Self.forecast("cloud-blocked") { json in
            Self.editNow(&json) { now in
                now["reasons"] = [["code": "twilight_too_bright", "effect": "blocker",
                                   "message": "Sun is above the experimental viewing threshold."]]
                    + (now["reasons"] as! [[String: Any]])
                var factors = now["factors"] as! [String: Any]
                factors["darkness"] = "nautical_twilight"
                now["factors"] = factors
            }
        }
        #expect(forecast.now.action == .skip)
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Tromsø"), now: forecast.generatedAt)
        #expect(state.kind == .skip)
        #expect(state.headline == Phrase("Skip Tonight.", emphasis: "Skip"))
    }

    @Test func quietWithoutASample() throws {
        let forecast = try Self.forecast("promising-now") { json in
            Self.editNow(&json) { now in
                now["action"] = "skip"
                now["rating"] = "unfavorable"
                now["reasons"] = [["code": "low_activity", "effect": "blocker", "message": "x"]]
            }
        }
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .quiet)
        #expect(state.sky == .off)
        #expect(state.headline.text == "Quiet Right Now.")
        #expect(state.bottomLine?.text == "Tonight Clear Until 05:52.")
    }

    @Test func waitForCloudWithoutASample() throws {
        let forecast = try Self.forecast("promising-now") { json in
            Self.editNow(&json) { now in
                now["action"] = "wait"
                now["rating"] = "unfavorable"
                now["reasons"] = [["code": "cloud_obstruction", "effect": "blocker", "message": "x"]]
            }
            // Cloud over the first three segments (21:00–23:00 UTC) of tonight.
            var planning = json["planning"] as! [[String: Any]]
            var windows = planning[0]["windows"] as! [[String: Any]]
            var segments = windows[0]["segments"] as! [[String: Any]]
            for index in 0..<3 {
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
        #expect(state.sky == .dim)
        #expect(state.headline == Phrase("Wait Until 01:00.", emphasis: "01:00"))
        #expect(state.lead == "Cloud clears around 01:00, and it stays dark all night.")
        #expect(state.bottomLine?.text == "Tonight Best 01:00–05:52.")
    }

    @Test func unknownActionIsNeutral() throws {
        let forecast = try Self.forecast("promising-now") { json in
            Self.editNow(&json) { $0["action"] = "something_new" }
        }
        let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
        #expect(state.kind == .cantCheck)
        #expect(!state.auroraActive)
    }

    @Test func skyLevelsMatchFigma() {
        let full: Set<ScreenKind> = [.go, .polarNight, .loading]
        let dim: Set<ScreenKind> = [.wait, .twilight, .weatherUnknown]
        for kind in ScreenKind.allCases {
            let expected: SkyLevel = full.contains(kind) ? .full : dim.contains(kind) ? .dim : kind == .partlyCloudy ? .partlyCloudy : .off
            #expect(kind.sky == expected, "\(kind)")
        }
    }

    // MARK: Helpers

    static func forecast(_ name: String, edit: ((inout [String: Any]) -> Void)? = nil) throws -> Forecast {
        let url = try #require(FixtureLibrary.directory?.appendingPathComponent("\(name).json"))
        var data = try Data(contentsOf: url)
        if let edit {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            edit(&json)
            data = try JSONSerialization.data(withJSONObject: json)
        }
        return try JSONDecoder.forecast().decode(Forecast.self, from: data)
    }

    static func editNow(_ json: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        var now = json["now"] as! [String: Any]
        change(&now)
        json["now"] = now
    }

    /// Moves every RFC3339 instant in the payload by `seconds`.
    static func shifted(_ value: Any, by seconds: TimeInterval) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { shifted($0, by: seconds) }
        case let array as [Any]:
            return array.map { shifted($0, by: seconds) }
        case let string as String:
            guard string.count >= 20, string.hasSuffix("Z"), let date = APITimestamp.parse(string) else { return string }
            return date.addingTimeInterval(seconds).formatted(.iso8601)
        default:
            return value
        }
    }
}
