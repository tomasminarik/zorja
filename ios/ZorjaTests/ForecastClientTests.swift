import Foundation
import Synchronization
import Testing
@testable import Zorja

// Public city-centre coordinate from the API docs; not a personal location.
private let stockholm = ForecastQuery(latitude: 59.3293, longitude: 18.0686, timezone: "Europe/Stockholm")
private let base = URL(string: "https://staging.invalid")!

private func example(_ name: String) throws -> Data {
    let root = ProcessInfo.processInfo.environment["AURORA_REPO_ROOT"].map { URL(filePath: $0) }
        ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: "api/examples/\(name).json"))
}

private func forecast(_ name: String = "promising-now") throws -> Forecast {
    try JSONDecoder.forecast().decode(Forecast.self, from: example(name))
}

private func errorBody(_ code: String) -> Data {
    Data(#"{"code":"\#(code)","message":"Synthetic.","requestId":"req-synthetic"}"#.utf8)
}

/// Answers every request with one canned reply and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
    }

    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var sent: [(request: URLRequest, body: Data)] = []

    static func reset(_ reply: Reply) {
        self.reply = reply
        sent = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.sent.append((request, body))
        let reply = Self.reply
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ForecastClientTests {
    private let client = ForecastClient(
        endpoint: ForecastEndpoint(baseURL: base)!,
        session: ForecastClient.makeSession(protocolClasses: [StubProtocol.self]))

    @Test func postsTheLocationOnlyInAJSONBody() async throws {
        StubProtocol.reset(.init(body: try example("promising-now")))
        _ = await client.fetch(stockholm)
        let sent = try #require(StubProtocol.sent.first)
        #expect(StubProtocol.sent.count == 1)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://staging.invalid/v1/forecast")
        #expect(sent.request.url?.query == nil)
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let object = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(Set(object.keys) == ["latitude", "longitude", "timezone"])
        // Rounded to two decimals before the request (docs/privacy.md).
        #expect(object["latitude"] as? Double == 59.33)
        #expect(object["longitude"] as? Double == 18.07)
        #expect(object["timezone"] as? String == "Europe/Stockholm")
        #expect(sent.body.count < 1024)
    }

    @Test func decodesAForecastWithItsRequestID() async throws {
        StubProtocol.reset(.init(headers: ["X-Request-ID": "req-1"], body: try example("promising-now")))
        let outcome = await client.fetch(stockholm)
        #expect(outcome == .forecast(try forecast(), requestID: "req-1"))
    }

    @Test func rateLimitCarriesRetryAfter() async {
        StubProtocol.reset(.init(status: 429, headers: ["Retry-After": "60"], body: errorBody("rate_limited")))
        guard case .rejected(let error, 429, 60) = await client.fetch(stockholm) else {
            Issue.record("Expected a 429 rejection with Retry-After")
            return
        }
        #expect(error.code == .rateLimited && error.requestId == "req-synthetic")
    }

    @Test func serviceUnavailableUsesTheContractExample() async throws {
        StubProtocol.reset(.init(status: 503, headers: ["Retry-After": "60"], body: try example("error-503")))
        guard case .rejected(let error, 503, 60) = await client.fetch(stockholm) else {
            Issue.record("Expected a 503 rejection")
            return
        }
        #expect(error.code == .forecastUnavailable)
    }

    @Test func offlineMakesOneRequestAndNeverFallsBackToGET() async {
        StubProtocol.reset(.init(error: URLError(.notConnectedToInternet)))
        #expect(await client.fetch(stockholm) == .failed(.offline, retryAfter: nil))
        #expect(StubProtocol.sent.map(\.request.httpMethod) == ["POST"])
    }

    @Test func unexpectedOrUnreadableResponses() async {
        StubProtocol.reset(.init(status: 502, body: Data("<html>".utf8)))
        #expect(await client.fetch(stockholm) == .failed(.unexpectedResponse(status: 502), retryAfter: nil))
        StubProtocol.reset(.init(status: 200, body: Data("{}".utf8)))
        #expect(await client.fetch(stockholm) == .failed(.undecodable, retryAfter: nil))
        StubProtocol.reset(.init(error: URLError(.timedOut)))
        #expect(await client.fetch(stockholm) == .failed(.timedOut, retryAfter: nil))
    }

    @Test func endpointsAreHTTPSOrLoopbackOnly() {
        #expect(ForecastEndpoint(baseURL: URL(string: "https://a.example")!) != nil)
        #expect(ForecastEndpoint(baseURL: URL(string: "http://127.0.0.1:8000")!) != nil)
        #expect(ForecastEndpoint(baseURL: URL(string: "http://localhost:8000")!) != nil)
        #expect(ForecastEndpoint(baseURL: URL(string: "http://a.example")!) == nil)
        #expect(ForecastEndpoint(baseURL: URL(string: "https://a.example?x=1")!) == nil)
        #expect(ForecastEndpoint(baseURL: URL(string: "https://user:pw@a.example")!) == nil)
    }

    @Test func releaseBuildsCallTheHostedService() {
        #expect(ForecastEndpoint.hosted.url.absoluteString == "https://api.zorja.app/v1/forecast")
        #expect(ForecastSource.hosted.endpoint(localBaseURL: "") == .hosted)
        #expect(ForecastSource.samples.endpoint(localBaseURL: ForecastEndpoint.localBaseURL) == nil)
        #expect(ForecastSource.local.endpoint(localBaseURL: ForecastEndpoint.localBaseURL)?.url.absoluteString
            == "http://127.0.0.1:8000/v1/forecast")
        // A local address that isn't loopback or HTTPS is refused, not sent.
        #expect(ForecastSource.local.endpoint(localBaseURL: "http://192.168.1.5:8000") == nil)
    }

    @Test func queriesNeverDescribeTheirCoordinates() {
        var dumped = ""
        dump(stockholm, to: &dumped)
        for text in [String(describing: stockholm), String(reflecting: stockholm), "\(stockholm)", dumped] {
            #expect(!text.contains("59.3") && !text.contains("18.0") && !text.contains("Stockholm"))
        }
    }

    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // Fri, 15 Jan 2027 08:00:00 GMT
        #expect(ForecastClient.retryAfter("60") == 60)
        #expect(ForecastClient.retryAfter("999999") == 86_400)
        #expect(ForecastClient.retryAfter("-1") == nil)
        #expect(ForecastClient.retryAfter("soon") == nil)
        #expect(ForecastClient.retryAfter(nil) == nil)
        #expect(ForecastClient.retryAfter("Fri, 15 Jan 2027 08:02:00 GMT", now: now) == 120)
        #expect(ForecastClient.retryAfter("Fri, 15 Jan 2027 07:00:00 GMT", now: now) == 0)
    }
}

/// A clock the tests move by hand.
private final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

/// Returns queued outcomes in order and counts calls.
private final class FakeFetch: Sendable {
    private let state: Mutex<(outcomes: [ForecastOutcome], calls: Int)>
    init(_ outcomes: [ForecastOutcome]) { state = Mutex((outcomes, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    func callAsFunction(_ query: ForecastQuery) async -> ForecastOutcome {
        await Task.yield()
        return state.withLock {
            $0.calls += 1
            return $0.outcomes.isEmpty ? .failed(.transport, retryAfter: nil) : $0.outcomes.removeFirst()
        }
    }
}

@MainActor
struct ForecastLoaderTests {
    private let tromso = ForecastQuery(latitude: 69.65, longitude: 18.96, timezone: "Europe/Oslo")

    @Test func oneRequestStartPerSixtySecondsIncludingFailures() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetch = FakeFetch([.failed(.offline, retryAfter: nil), .failed(.offline, retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { clock.now })
        #expect(await loader.refresh(stockholm))
        clock.advance(59)
        #expect(await loader.refresh(stockholm) == false)
        clock.advance(1)
        #expect(await loader.refresh(stockholm))
        #expect(fetch.calls == 2)
        #expect(loader.problem(for: stockholm) == .offline)
    }

    @Test func longerRetryAfterPushesEveryPlace() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let fetch = FakeFetch([
            .rejected(
                APIError(code: .rateLimited, message: "Synthetic.", requestId: "req-2"),
                status: 429, retryAfter: 120)
        ])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { start })
        await loader.refresh(stockholm)
        #expect(loader.earliestStart(for: stockholm) == start.addingTimeInterval(120))
        #expect(loader.earliestStart(for: tromso) == start.addingTimeInterval(120))
        #expect(loader.problem(for: stockholm) == .rateLimited && loader.lastRequestID == "req-2")
        #expect(loader.problem(for: tromso) == nil)
    }

    @Test func firewallTooManyRequestsReadsAsBusy() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let fetch = FakeFetch([.failed(.unexpectedResponse(status: 429), retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { start })
        await loader.refresh(stockholm)
        #expect(loader.problem(for: stockholm) == .rateLimited)
    }

    @Test func successWaitsForTheLaterOfFloorAndRefreshAfter() async throws {
        let value = try forecast()
        let start = value.generatedAt
        let fetch = FakeFetch([.forecast(value, requestID: "req-3")])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { start })
        await loader.refresh(stockholm)
        #expect(loader.earliestStart(for: stockholm) == max(start.addingTimeInterval(60), value.refreshAfter))
        #expect(loader.isCurrent(stockholm, at: value.refreshAfter.addingTimeInterval(-1)))
        #expect(loader.isCurrent(stockholm, at: value.refreshAfter) == false)
    }

    @Test func aFailureKeepsTheLastForecastWithItsTimestamps() async throws {
        let value = try forecast()
        let clock = TestClock(value.generatedAt)
        let fetch = FakeFetch([.forecast(value, requestID: nil), .failed(.offline, retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { clock.now })
        await loader.refresh(stockholm)
        clock.advance(max(60, value.refreshAfter.timeIntervalSince(value.generatedAt)))
        #expect(await loader.refresh(stockholm))
        #expect(loader.forecast(for: stockholm) == value)
        #expect(loader.problem(for: stockholm) == .offline)
        #expect(loader.isCurrent(stockholm, at: clock.now) == false)
    }

    @Test func aNewPlaceLoadsAfterTheSpacingNotTheMinute() async throws {
        let value = try forecast()
        let clock = TestClock(value.generatedAt)
        let fetch = FakeFetch([.forecast(value, requestID: nil), .forecast(value, requestID: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { clock.now })
        await loader.refresh(stockholm)
        // The same place waits for refreshAfter (five minutes in this sample).
        #expect(loader.earliestStart(for: stockholm) == value.refreshAfter)
        clock.advance(4)
        #expect(await loader.refresh(tromso) == false)
        clock.advance(1)
        #expect(loader.earliestStart(for: tromso) == clock.now)
        #expect(await loader.refresh(tromso))
        #expect(fetch.calls == 2)
        // Each place keeps its own forecast and schedule.
        #expect(loader.forecast(for: stockholm) == value && loader.forecast(for: tromso) == value)
        #expect(loader.earliestStart(for: stockholm) == value.refreshAfter)
    }

    @Test func aPlacePickedAgainShowsItsForecastWithoutAskingAgain() async throws {
        let value = try forecast()
        let clock = TestClock(value.generatedAt)
        let fetch = FakeFetch([.forecast(value, requestID: nil), .failed(.offline, retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { clock.now })
        await loader.refresh(stockholm)
        clock.advance(10)
        await loader.refresh(tromso)
        clock.advance(10)
        // Back to Stockholm: its forecast is still current, so no request is due.
        #expect(await loader.refresh(stockholm) == false)
        #expect(loader.isCurrent(stockholm, at: clock.now))
        #expect(loader.problem(for: stockholm) == nil)
        #expect(loader.problem(for: tromso) == .offline)
        #expect(fetch.calls == 2)
    }

    @Test func aFailedPlaceStillWaitsAMinuteBeforeItsRetry() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetch = FakeFetch([.failed(.offline, retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { clock.now })
        await loader.refresh(stockholm)
        clock.advance(30)
        #expect(await loader.refresh(stockholm) == false)
        #expect(loader.earliestStart(for: stockholm) == clock.now.addingTimeInterval(30))
    }

    @Test func aRequestCancelledByAPlaceChangeIsNotOffline() async {
        let fetch = FakeFetch([.failed(.transport, retryAfter: nil)])
        let start = Date.now
        let loader = ForecastLoader(fetch: { await fetch($0) }, now: { start })
        let task = Task { await loader.refresh(stockholm) }
        task.cancel()
        #expect(await task.value)
        #expect(loader.problem(for: stockholm) == nil)
        // Only the spacing holds it back: picked again, the place loads without a minute's wait.
        #expect(loader.earliestStart(for: stockholm) == start.addingTimeInterval(RevalidationSchedule.minimumSpacing))
    }

    @Test func concurrentCallersStartOnlyOneRequest() async {
        let fetch = FakeFetch([.failed(.offline, retryAfter: nil)])
        let loader = ForecastLoader(fetch: { await fetch($0) })
        async let first = loader.refresh(stockholm)
        async let second = loader.refresh(stockholm)
        let started = await [first, second]
        #expect(started.filter { $0 }.count == 1)
        #expect(fetch.calls == 1)
    }
}
