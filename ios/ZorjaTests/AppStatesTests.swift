import Foundation
import Testing
@testable import Zorja

/// App states: each frame forced from the developer menu, Try Again's delay,
/// and the screen redrawing when that delay ends.
@MainActor
struct AppStatesTests {
    static let forcedAt = APITimestamp.parse("2026-10-12T21:00:00Z")!

    static func payload(_ name: String = "promising-now") throws -> FixtureLibrary.Payload {
        try FixtureLibrary.load(name)
    }

    static func screen(_ forced: ForcedAppState, lastRequest: Date? = nil, unexpired: Bool = false, now: Date? = nil) throws -> ScreenState {
        let payload = try payload()
        let input = forced.input(from: payload, forcedAt: forcedAt, lastRequest: lastRequest)
        let clock = forced.pinnedNow(for: input.forecast, unexpired: unexpired) ?? now ?? forcedAt
        return ScreenState.make(input, now: clock)
    }

    // MARK: Each frame

    @Test func loading() throws {
        let state = try Self.screen(.loading)
        #expect(state.kind == .loading)
        #expect(state.sky == .full)
        #expect(state.headline.text == "Checking The Sky.")
        #expect(state.tonight != nil)
        #expect(state.threeNights != nil)
    }

    @Test func offlineWithCurrentForecastKeepsTheScreen() throws {
        let state = try Self.screen(.offline, unexpired: true)
        #expect(state.kind == .go)
        #expect(state.status == .offline(updated: "23:00"))
    }

    /// Figma: "Now · Offline, no current forecast" keeps "Last update HH:MM" above the
    /// headline, also with "Show as unexpired" on.
    @Test(arguments: [false, true])
    func offlineWithoutCurrentForecastShowsLastUpdate(unexpired: Bool) throws {
        let state = try Self.screen(.offlineNoForecast, unexpired: unexpired)
        #expect(state.kind == .offlineNoForecast)
        #expect(state.sky == .off)
        #expect(state.status == .lastUpdate("23:00"))
        #expect(state.headline.text == "No Connection.")
        #expect(state.tonight == nil)
        #expect(state.threeNights == nil)
    }

    /// Figma: "Now · Error" opens with Try Again on.
    @Test func errorOpensWithTryAgainOn() throws {
        let state = try Self.screen(.error)
        #expect(state.kind == .error)
        #expect(state.headline.text == "Can’t Check Right Now.")
        #expect(state.lead == "Something went wrong on Zorja’s side. It isn’t your connection.")
        #expect(state.retry?.isEnabled(at: Self.forcedAt) == true)
    }

    // MARK: Try Again's delay

    /// After Try Again the button is off for the request floor, then on again.
    @Test func errorAfterRetryWaitsForTheFloor() throws {
        let retried = Self.forcedAt.addingTimeInterval(120)
        let state = try Self.screen(.error, lastRequest: retried, now: retried)
        let opens = retried.addingTimeInterval(RevalidationSchedule.minimumFloor)
        #expect(state.retry == RetryAction(enabledAt: opens))
        #expect(state.retry?.isEnabled(at: opens.addingTimeInterval(-1)) == false)
        #expect(state.retry?.isEnabled(at: opens) == true)
    }

    /// The delay is counted from when the state was chosen, so it doesn't move on redraw.
    @Test func rateLimitedDelayStaysPut() throws {
        let payload = try Self.payload()
        let first = ForcedAppState.rateLimited.input(from: payload, forcedAt: Self.forcedAt)
        let later = ForcedAppState.rateLimited.input(from: payload, forcedAt: Self.forcedAt)
        #expect(first.nextCheck == Self.forcedAt.addingTimeInterval(60))
        #expect(first.nextCheck == later.nextCheck)

        let state = ScreenState.make(first, now: Self.forcedAt)
        let at = CopyClock(timeZone: .current).time(Self.forcedAt.addingTimeInterval(60))
        #expect(state.lead == "Zorja is busy. It tries again at \(at).")
        #expect(state.retry?.isEnabled(at: Self.forcedAt.addingTimeInterval(59)) == false)
        #expect(state.retry?.isEnabled(at: Self.forcedAt.addingTimeInterval(60)) == true)
    }

    // MARK: Redraws

    /// The screen redraws when Try Again turns on, not up to a minute later.
    @Test func scheduleRedrawsAtTheNextAllowedRequest() {
        let start = Self.forcedAt
        let opens = start.addingTimeInterval(25)
        let schedule = ScreenSchedule(boundaries: [opens])
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(3))
        #expect(entries == [start, opens, opens.addingTimeInterval(60)])
    }

    /// The earliest of several boundaries comes first; past ones are ignored.
    @Test func scheduleTakesTheEarliestBoundary() {
        let start = Self.forcedAt
        let schedule = ScreenSchedule(boundaries: [start.addingTimeInterval(40), start.addingTimeInterval(10), start.addingTimeInterval(-5)])
        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(4))
        #expect(entries == [start, start.addingTimeInterval(10), start.addingTimeInterval(40), start.addingTimeInterval(100)])
    }

    @Test func scheduleWithoutBoundariesTicksEveryMinute() {
        let start = Self.forcedAt
        let entries = Array(ScreenSchedule(boundaries: []).entries(from: start, mode: .normal).prefix(3))
        #expect(entries == [start, start.addingTimeInterval(60), start.addingTimeInterval(120)])
    }
}
