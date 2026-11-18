import Foundation
import Testing
@testable import Zorja

private final class BundleToken {}

private struct ReplayEntry: Decodable {
    let city: String
    let forecast: Forecast
}

struct ForecastDecodingTests {
    @Test func everySyntheticFixtureDecodes() throws {
        let names = FixtureLibrary.names
        #expect(names.count == 19)
        for name in names {
            let payload = try FixtureLibrary.load(name)
            if case .forecast(let forecast) = payload {
                #expect(forecast.planning.count == 3, "\(name)")
                #expect(forecast.now.reasons.allSatisfy { $0.code != .unrecognized }, "\(name)")
            } else {
                #expect(name == "error-503")
            }
        }
    }

    @Test func recordedBackendResponsesDecode() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "four-cities-replay", withExtension: "json"))
        let entries = try JSONDecoder.forecast().decode([ReplayEntry].self, from: Data(contentsOf: url))
        #expect(entries.map(\.city) == ["stockholm", "oslo", "helsinki", "berlin"])
        let stockholm = try #require(entries.first).forecast
        #expect(stockholm.now.factors.weather == .obstructed)
        #expect(stockholm.now.action == .skip)
        #expect(stockholm.refreshAfter > stockholm.generatedAt)
        let unavailable = try #require(stockholm.sources.first { $0.status == .unavailable })
        #expect(unavailable.role == .auroraPlanning)
        #expect(stockholm.now.reasons.contains { $0.code == .sourceUnavailable && $0.sourceId == unavailable.id })
        #expect(stockholm.planning.allSatisfy { $0.globalKpContext?.status == .unavailable })
        #expect(stockholm.minimumRevalidationIntervalSeconds == 60)
    }

    @Test func auroraReachOutlookAndActiveSinceDecode() throws {
        guard case .forecast(let south) = try FixtureLibrary.load("south-could-reach") else {
            Issue.record("south-could-reach is not a forecast")
            return
        }
        let reach = try #require(south.auroraReach)
        #expect(reach.group == .south)
        #expect(reach.kpLowInNorth == 4.43)
        #expect(south.planning.map { $0.auroraOutlook?.status } == [.couldReach, .couldReach, .couldReach])
        #expect(south.now.activeSince != nil && south.now.activeSinceIsBufferLimited == true)
        guard case .forecast(let edge) = try FixtureLibrary.load("low-activity") else { return }
        #expect(edge.auroraReach?.group == .edge)
        #expect(edge.planning.allSatisfy { $0.auroraOutlook?.status == .notApplicable })
        // Quiet now: no active stretch.
        #expect(edge.now.activeSince == nil && edge.now.activeSinceIsBufferLimited == false)
    }

    @Test func unknownReachValuesShowNoGroup() throws {
        let forecast = try ScreenStateTests.forecast("south-could-reach") { json in
            var reach = json["auroraReach"] as! [String: Any]
            reach["group"] = "polar_cap"
            json["auroraReach"] = reach
            ThreeNightsTests.editPlanning(&json) { _, night in
                night["auroraOutlook"] = ["status": "maybe", "highestKp": NSNull(), "sourceId": "kp"]
            }
        }
        #expect(forecast.auroraReach?.group == .unrecognized)
        #expect(forecast.planning.allSatisfy { $0.auroraOutlook?.status == .unrecognized })
        #expect(AuroraReach(forecast.auroraReach) == nil)
        let state = try ThreeNightsTests.threeNights(forecast)
        #expect(state.placeLine == nil && state.nights.allSatisfy { !$0.storm })
    }

    @Test func olderResponsesWithoutNewFieldsDecode() throws {
        let forecast = try ScreenStateTests.forecast("south-could-reach") { json in
            json.removeValue(forKey: "auroraReach")
            var now = json["now"] as! [String: Any]
            now.removeValue(forKey: "activeSince")
            now.removeValue(forKey: "activeSinceIsBufferLimited")
            json["now"] = now
            ThreeNightsTests.editPlanning(&json) { _, night in night.removeValue(forKey: "auroraOutlook") }
        }
        #expect(forecast.auroraReach == nil && forecast.now.activeSince == nil)
        #expect(try ThreeNightsTests.threeNights(forecast).placeLine == nil)
    }

    @Test func timestampsParseWithAndWithoutFractions() throws {
        let whole = try #require(APITimestamp.parse("2026-10-12T19:45:39Z"))
        let micro = try #require(APITimestamp.parse("2026-10-12T19:45:10.547903Z"))
        #expect(abs(whole.timeIntervalSince(micro) - 28.452097) < 0.001)
        #expect(APITimestamp.parse("2026-10-12 19:45") == nil)
    }

    @Test func unknownEnumValuesFallBackToNeutral() throws {
        let json = #"{"darkness":"lunar_eclipse","weather":"sparkly","activity":"extreme"}"#
        let factors = try JSONDecoder.forecast().decode(Factors.self, from: Data(json.utf8))
        #expect(factors == Factors(darkness: .unknown, weather: .unknown, activity: .unknown))
        let action = try JSONDecoder.forecast().decode([Action].self, from: Data(#"["run_outside"]"#.utf8))
        #expect(action == [.unrecognized])
    }

    @Test func missingRequiredFieldFailsDecoding() {
        let json = #"{"darkness":"daylight","weather":"favorable"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder.forecast().decode(Factors.self, from: Data(json.utf8))
        }
    }
}

struct ForecastCopyTests {
    private func forecast(_ name: String) throws -> Forecast {
        guard case .forecast(let forecast) = try FixtureLibrary.load(name) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return forecast
    }

    private func title(_ name: String) throws -> String {
        let f = try forecast(name)
        return f.now.headline(
            upcoming: f.upcoming, clock: LocalClock(timeZone: f.location.timeZone), isCurrent: true).title
    }

    @Test func headlinesKeepStatesDistinct() throws {
        #expect(try title("promising-now") == "Worth a look now")
        #expect(try title("cloud-blocked") == "Clouded over")
        #expect(try title("daylight-next-window") == "Too bright right now")
        #expect(try title("stale-aurora") == "Can't tell yet")
        #expect(try title("weather-unavailable") == "Can't tell yet")
        #expect(try title("weather-missing") == "Can't tell yet")
        // Weak overhead signal is unknown, not quiet: aurora may still show toward the horizon.
        #expect(try title("low-activity") == "Can't tell yet")
        #expect(try title("limited-clouds") == "Mixed skies")
        #expect(try title("midnight-sun") == "No darkness")
    }

    @Test func missingWeatherNeverReadsAsClear() throws {
        for name in ["weather-unavailable", "weather-missing", "stale-weather"] {
            let sky = try forecast(name).now.factorLines[1]
            #expect(sky.tone != .good, "\(name)")
            #expect(!sky.value.contains("Clear"), "\(name)")
        }
    }

    @Test func expiredTryNowIsWithdrawn() throws {
        let f = try forecast("promising-now")
        #expect(f.now.action == .tryNow)
        // Bracketed activity evidence (visibility-v0.2) keeps it current until refreshAfter, not after.
        #expect(f.refreshAfter > f.generatedAt)
        #expect(f.isCurrent(at: f.generatedAt))
        #expect(!f.isCurrent(at: f.refreshAfter))
        let headline = f.now.headline(
            upcoming: f.upcoming, clock: LocalClock(timeZone: f.location.timeZone), isCurrent: false)
        #expect(headline.title == "Looked promising at 23:00")
    }

    @Test func globalKpIsLabelledContext() throws {
        #expect(try forecast("promising-now").planning[0].globalKpSummary == "Global Kp up to 5")
        #expect(try forecast("midnight-sun").planning[0].globalKpSummary == "Global Kp up to 5")
    }

    @Test func requestFloorNeverPrecedesSixtySeconds() throws {
        let f = try forecast("promising-now")
        // A request started right as the forecast expires still waits for the 60-second floor.
        let start = f.refreshAfter
        #expect(RevalidationSchedule.nextRequest(after: start, forecast: f) == start.addingTimeInterval(60))
        #expect(RevalidationSchedule.nextRequest(after: start, forecast: f, retryAfter: 120) == start.addingTimeInterval(120))
        // Before expiry, the next request waits for refreshAfter.
        #expect(RevalidationSchedule.nextRequest(after: f.generatedAt, forecast: f) == f.refreshAfter)
        let slow = try forecast("low-activity")
        #expect(RevalidationSchedule.nextRequest(after: slow.generatedAt, forecast: slow) == slow.refreshAfter)
    }
}
