import Foundation
import Observation

/// Owns forecast requests for one device workflow, with a separate state per place.
/// Each place gets at most one request start per 60-second floor, across successes,
/// failures and retries, and a later `refreshAfter` delays that place's next request.
/// Any two request starts, for whatever place, are at least `minimumSpacing` apart, and a
/// Retry-After pushes every next start out. A newly picked place therefore loads at once,
/// and a place picked again shows its last forecast while that is still current (docs/api.md).
@MainActor @Observable
final class ForecastLoader {
    enum Problem: Sendable, Equatable {
        case offline
        case rateLimited
        case unavailable
        case rejectedRequest
        case unreadable
    }

    /// What the loader knows about one place.
    struct PlaceState: Equatable {
        /// The last successful forecast for this place, kept with its original timestamps
        /// when a later request fails. Whether it is still current is `Forecast.isCurrent(at:)`.
        var forecast: Forecast?
        /// Why the most recent request for this place did not produce a forecast, if it didn't.
        var problem: Problem?
        /// The next start for this place: its floor, or `refreshAfter` if later.
        var nextAllowedStart: Date = .distantPast
    }

    private(set) var places: [ForecastQuery: PlaceState] = [:]
    /// The place whose request is in flight, if any.
    private(set) var loadingQuery: ForecastQuery?
    var isLoading: Bool { loadingQuery != nil }
    /// The next start for any place: the spacing and any Retry-After.
    private(set) var floorEnd: Date = .distantPast
    /// Kept for support. Never contains location.
    private(set) var lastRequestID: String?

    private let fetch: @Sendable (ForecastQuery) async -> ForecastOutcome
    private let now: @Sendable () -> Date

    init(client: ForecastClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.fetch = { await client.fetch($0) }
        self.now = now
    }

    init(
        fetch: @escaping @Sendable (ForecastQuery) async -> ForecastOutcome,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fetch = fetch
        self.now = now
    }

    func forecast(for query: ForecastQuery) -> Forecast? { places[query]?.forecast }
    func problem(for query: ForecastQuery) -> Problem? { places[query]?.problem }
    func isLoading(_ query: ForecastQuery) -> Bool { loadingQuery == query }

    /// A recommendation is shown as current only before its `refreshAfter`.
    func isCurrent(_ query: ForecastQuery, at date: Date) -> Bool {
        forecast(for: query)?.isCurrent(at: date) ?? false
    }

    /// When a request for `query` may start next.
    func earliestStart(for query: ForecastQuery) -> Date {
        max(places[query]?.nextAllowedStart ?? .distantPast, floorEnd)
    }

    /// Starts a request if the floors allow one. Returns whether a request started.
    @discardableResult
    func refresh(_ query: ForecastQuery) async -> Bool {
        let start = now()
        guard !isLoading, start >= earliestStart(for: query) else { return false }
        loadingQuery = query
        // Reserve both floors before awaiting so a concurrent caller cannot start.
        floorEnd = start.addingTimeInterval(RevalidationSchedule.minimumSpacing)
        let previousStart = places[query]?.nextAllowedStart ?? .distantPast
        places[query, default: PlaceState()].nextAllowedStart =
            start.addingTimeInterval(RevalidationSchedule.minimumFloor)
        let outcome = await fetch(query)
        loadingQuery = nil
        // A request cancelled by a place change or leaving the foreground says nothing
        // about the service or the network: record no problem, and don't make the place
        // wait a full minute when it is picked again. The spacing still applies.
        if Task.isCancelled, case .failed = outcome {
            places[query]?.nextAllowedStart = previousStart
            return true
        }
        var state = places[query] ?? PlaceState()
        switch outcome {
        case .forecast(let forecast, let requestID):
            state.forecast = forecast
            state.problem = nil
            state.nextAllowedStart = RevalidationSchedule.nextRequest(after: start, forecast: forecast)
            lastRequestID = requestID
        case .rejected(let error, let status, let retryAfter):
            state.problem = Self.problem(code: error.code, status: status)
            state.nextAllowedStart = RevalidationSchedule.nextRequest(
                after: start, forecast: nil, retryAfter: retryAfter)
            floorEnd = Self.spacingEnd(after: start, retryAfter: retryAfter)
            lastRequestID = error.requestId
        case .failed(let failure, let retryAfter):
            state.problem = Self.problem(for: failure)
            state.nextAllowedStart = RevalidationSchedule.nextRequest(
                after: start, forecast: nil, retryAfter: retryAfter)
            floorEnd = Self.spacingEnd(after: start, retryAfter: retryAfter)
            lastRequestID = nil
        }
        places[query] = state
        return true
    }

    /// Refreshes whenever the schedule allows, until the calling task is cancelled
    /// (for example when the view disappears or the app leaves the foreground).
    func keepFresh(_ query: ForecastQuery) async {
        while !Task.isCancelled {
            await refresh(query)
            let wait = max(1, earliestStart(for: query).timeIntervalSince(now()))
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// A Retry-After is about the service, so it holds back every place.
    private static func spacingEnd(after start: Date, retryAfter: TimeInterval?) -> Date {
        start.addingTimeInterval(max(RevalidationSchedule.minimumSpacing, retryAfter ?? 0))
    }

    private static func problem(code: APIErrorCode, status: Int) -> Problem {
        switch code {
        case .rateLimited: .rateLimited
        case .invalidRequest: .rejectedRequest
        case .forecastUnavailable: .unavailable
        case .unrecognized: status == 429 ? .rateLimited : .unavailable
        }
    }

    private static func problem(for failure: ForecastFailure) -> Problem {
        switch failure {
        case .offline, .timedOut, .transport: .offline
        // A 429 without the API's body comes from the hosting firewall's per-address limit.
        case .unexpectedResponse(let status): status == 429 ? .rateLimited : .unavailable
        case .undecodable: .unreadable
        }
    }
}
