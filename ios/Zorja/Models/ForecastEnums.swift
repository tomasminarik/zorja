import Foundation

/// A string enum whose unrecognised server values decode to a neutral case
/// instead of failing, so additive enum values never read as favorable.
protocol FallbackDecodable: RawRepresentable, Decodable, Sendable, Equatable where RawValue == String {
    static var fallback: Self { get }
}

extension FallbackDecodable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

enum Rating: String, FallbackDecodable {
    case unfavorable, limited, promising, unknown
    static let fallback = Rating.unknown
}

enum Action: String, FallbackDecodable {
    case tryNow = "try_now"
    case wait, skip
    case checkLater = "check_later"
    case unrecognized = "__unrecognized"
    static let fallback = Action.unrecognized
}

enum Basis: String, FallbackDecodable {
    case shortTerm = "short_term"
    case planning, unavailable
    static let fallback = Basis.unavailable
}

enum Confidence: String, FallbackDecodable {
    case low, moderate, unknown
    static let fallback = Confidence.unknown
}

enum ReasonCode: String, FallbackDecodable {
    case daylight
    case twilightTooBright = "twilight_too_bright"
    case cloudObstruction = "cloud_obstruction"
    case lowActivity = "low_activity"
    case activityNotCovered = "activity_not_covered"
    case weatherMissing = "weather_missing"
    case sourceStale = "source_stale"
    case sourceUnavailable = "source_unavailable"
    case noDarknessWithinHorizon = "no_darkness_within_horizon"
    case unmodeledLocalConditions = "unmodeled_local_conditions"
    case experimentalModel = "experimental_model"
    case unrecognized = "__unrecognized"
    static let fallback = ReasonCode.unrecognized
}

enum ReasonEffect: String, FallbackDecodable {
    case blocker, limitation, information
    case unrecognized = "__unrecognized"
    static let fallback = ReasonEffect.unrecognized
}

enum DarknessFactor: String, FallbackDecodable {
    case daylight
    case civilTwilight = "civil_twilight"
    case nauticalTwilight = "nautical_twilight"
    case astronomicalTwilight = "astronomical_twilight"
    case astronomicalNight = "astronomical_night"
    case mixed, unknown
    static let fallback = DarknessFactor.unknown
}

enum WeatherFactor: String, FallbackDecodable {
    case favorable, mixed, obstructed, missing, stale, unavailable
    case notCovered = "not_covered"
    case partial, unknown
    static let fallback = WeatherFactor.unknown
}

enum ActivityFactor: String, FallbackDecodable {
    case supported, low, missing, stale, unavailable
    case notCovered = "not_covered"
    case partial, unknown
    static let fallback = ActivityFactor.unknown
}

enum UpcomingStatus: String, FallbackDecodable {
    case windowAvailable = "window_available"
    case noDarknessWithinHorizon = "no_darkness_within_horizon"
    case unavailable
    static let fallback = UpcomingStatus.unavailable
}

enum DarknessStatus: String, FallbackDecodable {
    case windowsAvailable = "windows_available"
    case noDarkness = "no_darkness"
    case unavailable
    static let fallback = DarknessStatus.unavailable
}

enum SourceProvider: String, FallbackDecodable {
    case noaaSWPC = "noaa_swpc"
    case metNorway = "met_norway"
    case backendAstronomy = "backend_astronomy"
    case unrecognized = "__unrecognized"
    static let fallback = SourceProvider.unrecognized
}

enum SourceKind: String, FallbackDecodable {
    case observation
    case modelForecast = "model_forecast"
    case calculation
    case unrecognized = "__unrecognized"
    static let fallback = SourceKind.unrecognized
}

enum SourceStatus: String, FallbackDecodable {
    case fresh, stale, unavailable
    case notApplicable = "not_applicable"
    case unrecognized = "__unrecognized"
    static let fallback = SourceStatus.unrecognized
}

enum SourceRole: String, FallbackDecodable {
    case auroraShortTerm = "aurora_short_term"
    case auroraPlanning = "aurora_planning"
    case weather, darkness
    case unrecognized = "__unrecognized"
    static let fallback = SourceRole.unrecognized
}

enum KpContextStatus: String, FallbackDecodable {
    case available, partial
    case notCovered = "not_covered"
    case stale, unavailable
    static let fallback = KpContextStatus.unavailable
}

enum APIErrorCode: String, FallbackDecodable {
    case invalidRequest = "invalid_request"
    case rateLimited = "rate_limited"
    case forecastUnavailable = "forecast_unavailable"
    case unrecognized = "__unrecognized"
    static let fallback = APIErrorCode.unrecognized
}

enum AuroraReachGroup: String, FallbackDecodable {
    case underZone = "under_zone"
    case edge, south
    case unrecognized = "__unrecognized"
    static let fallback = AuroraReachGroup.unrecognized
}

enum AuroraOutlookStatus: String, FallbackDecodable {
    case couldReach = "could_reach"
    case notExpected = "not_expected"
    case notApplicable = "not_applicable"
    case notKnownYet = "not_known_yet"
    case stale, unavailable
    case unrecognized = "__unrecognized"
    static let fallback = AuroraOutlookStatus.unrecognized
}
