import Foundation

/// The body of `POST /v1/forecast`. Coordinates travel only in this body: never
/// in a URL, and never in a description, log line or error. They are rounded to two decimals
/// here, so no request can carry more (docs/privacy.md).
struct ForecastQuery: Encodable, Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let latitude: Double
    let longitude: Double
    let timezone: String

    init(latitude: Double, longitude: Double, timezone: String) {
        let rounded = RoundedCoordinate(latitude: latitude, longitude: longitude)
        self.latitude = rounded.latitude
        self.longitude = rounded.longitude
        self.timezone = timezone
    }

    var description: String { "ForecastQuery(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The forecast operation's URL. HTTPS only, except a loopback development server.
struct ForecastEndpoint: Sendable, Equatable {
    let url: URL

    init?(baseURL: URL) {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            parts.query == nil, parts.fragment == nil, parts.user == nil, parts.password == nil,
            let host = parts.host, !host.isEmpty
        else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback) else { return nil }
        url = baseURL.appending(path: "v1/forecast")
    }

    /// The hosted service (docs/hosting.md). Release builds use only this.
    static let hosted = ForecastEndpoint(baseURL: URL(string: "https://api.zorja.app")!)!
    /// A development server on this Mac, as `backend/` runs it.
    static let localBaseURL = "http://127.0.0.1:8000"
}

/// Where the forecast comes from. Release builds always use `hosted`; debug builds pick one in
/// the developer menu or at launch (`-source hosted`).
enum ForecastSource: String, CaseIterable, Identifiable {
    case samples, local, hosted

    var id: Self { self }

    var title: String {
        switch self {
        case .samples: "Bundled samples"
        case .local: "Local server"
        case .hosted: "Hosted (api.zorja.app)"
        }
    }

    /// The endpoint to call, or nil for the samples or a local address that isn't allowed.
    func endpoint(localBaseURL: String) -> ForecastEndpoint? {
        switch self {
        case .samples: nil
        case .local: URL(string: localBaseURL).flatMap(ForecastEndpoint.init(baseURL:))
        case .hosted: .hosted
        }
    }
}

/// What one request produced. Carries no request, URL or body.
enum ForecastOutcome: Sendable, Equatable {
    case forecast(Forecast, requestID: String?)
    /// The service answered with its Error schema (400, 429 or 503).
    case rejected(APIError, status: Int, retryAfter: TimeInterval?)
    case failed(ForecastFailure, retryAfter: TimeInterval?)
}

enum ForecastFailure: Sendable, Equatable {
    case offline
    case timedOut
    case transport
    case unexpectedResponse(status: Int)
    case undecodable
}

/// Sends forecast requests as POST with a JSON body. There is deliberately no GET
/// path and no fallback to one: that would put the location back in the URL.
struct ForecastClient: Sendable {
    let endpoint: ForecastEndpoint
    let session: URLSession

    init(endpoint: ForecastEndpoint, session: URLSession = ForecastClient.makeSession()) {
        self.endpoint = endpoint
        self.session = session
    }

    /// No URL cache, cookies or stored credentials: responses contain the location.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    func makeRequest(_ query: ForecastQuery) throws -> URLRequest {
        var request = URLRequest(
            url: endpoint.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(query)
        return request
    }

    func fetch(_ query: ForecastQuery) async -> ForecastOutcome {
        guard let request = try? makeRequest(query) else {
            return .failed(.transport, retryAfter: nil)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            return .failed(Self.failure(for: error), retryAfter: nil)
        } catch {
            return .failed(.transport, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            return .failed(.transport, retryAfter: nil)
        }
        let retryAfter = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        let decoder = JSONDecoder.forecast()
        switch http.statusCode {
        case 200:
            guard let forecast = try? decoder.decode(Forecast.self, from: data) else {
                return .failed(.undecodable, retryAfter: nil)
            }
            return .forecast(forecast, requestID: http.value(forHTTPHeaderField: "X-Request-ID"))
        case 400, 429, 503:
            guard let error = try? decoder.decode(APIError.self, from: data) else {
                return .failed(.unexpectedResponse(status: http.statusCode), retryAfter: retryAfter)
            }
            return .rejected(error, status: http.statusCode, retryAfter: retryAfter)
        default:
            return .failed(.unexpectedResponse(status: http.statusCode), retryAfter: retryAfter)
        }
    }

    static func failure(for error: URLError) -> ForecastFailure {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .offline
        case .timedOut:
            .timedOut
        default:
            .transport
        }
    }

    /// Delay seconds or an HTTP date, capped at one day. Anything else is ignored.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        let maximum: TimeInterval = 86_400
        if let seconds = Int(value), seconds >= 0 { return min(TimeInterval(seconds), maximum) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maximum)
    }
}
