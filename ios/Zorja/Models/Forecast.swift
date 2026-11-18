import Foundation

// Mirrors api/openapi.json 1.0.0 (frozen v1 contract).

struct Forecast: Decodable, Sendable, Equatable {
    let apiVersion: String
    let modelVersion: String
    let generatedAt: Date
    let refreshAfter: Date
    let location: Location
    let now: Assessment
    let upcomingStatus: UpcomingStatus
    let upcoming: ViewingWindow?
    let planning: [PlanningNight]
    let sources: [Source]
    let limitations: [String]
    let minimumRevalidationIntervalSeconds: Int?
    /// The newest received short-term aurora prediction after `generatedAt`. Optional and
    /// additive: absent or null means no future prediction, never zero activity.
    let upcomingActivityInstant: UpcomingActivityInstant?
    /// How far aurora usually reaches this place. Optional and additive; null or absent
    /// means the app shows no group-specific words or marks.
    let auroraReach: AuroraReachInfo?

    /// A `try_now` recommendation must be withdrawn from `refreshAfter` onward.
    func isCurrent(at date: Date) -> Bool { date < refreshAfter }
}

struct Location: Decodable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let timezone: String

    var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .gmt }
}

/// One exact-instant aurora model forecast. It has no duration and never makes a viewing rating.
struct UpcomingActivityInstant: Decodable, Sendable, Equatable {
    let forecastAt: Date
    let activity: ActivityFactor
}

/// How far aurora usually reaches a place, from its corrected magnetic latitude and NOAA's
/// average oval rule (docs/forecast-model.md → Aurora reach). A planning frame, never a rating;
/// the Kp numbers are never shown.
struct AuroraReachInfo: Decodable, Sendable, Equatable {
    let group: AuroraReachGroup
    let magneticLatitude: Double?
    let kpOverhead: Double?
    /// Null where the magnetic latitude is undefined: never reached by the rule.
    let kpLowInNorth: Double?
}

/// A southern place's night outlook: whether the night's highest forecast Kp over its
/// remaining dark hours reaches the place. Helps choose a night; never a promise.
struct AuroraOutlook: Decodable, Sendable, Equatable {
    let status: AuroraOutlookStatus
    let highestKp: Double?
}

/// Half-open `[start, end)`.
struct Interval: Decodable, Sendable, Equatable {
    let start: Date
    let end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

struct Assessment: Decodable, Sendable, Equatable {
    let interval: Interval
    let rating: Rating
    let action: Action
    let basis: Basis
    let confidence: Confidence
    let summary: String
    let reasons: [Reason]
    let solarAltitudeDegrees: Double?
    let cloudCoverPercent: Double?
    /// Only on `now`: when current activity is supported, the start of the unbroken active
    /// stretch in the last three hours of received model runs. A past measurement, never a forecast.
    let activeSince: Date?
    /// True when the active stretch reaches the start of the retained runs, so it may be longer.
    let activeSinceIsBufferLimited: Bool?
    let sourceIds: [String]
    let factors: Factors
}

struct Reason: Decodable, Sendable, Equatable {
    let code: ReasonCode
    let effect: ReasonEffect
    let message: String
    let sourceId: String?
}

struct Factors: Decodable, Sendable, Equatable {
    let darkness: DarknessFactor
    let weather: WeatherFactor
    let activity: ActivityFactor
}

struct ViewingWindow: Decodable, Sendable, Equatable {
    let interval: Interval
    let endIsSearchLimited: Bool
    let segments: [Assessment]
}

struct PlanningNight: Decodable, Sendable, Equatable, Identifiable {
    let localDate: String
    let period: Interval
    let assessment: Assessment
    let windows: [ViewingWindow]
    let darknessStatus: DarknessStatus
    let globalKpContext: GlobalKpContext?
    let auroraOutlook: AuroraOutlook?

    var id: String { localDate }
}

struct Source: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let provider: SourceProvider
    let product: String
    let kind: SourceKind
    let status: SourceStatus
    let issuedAt: Date?
    let fetchedAt: Date?
    let validFrom: Date?
    let validUntil: Date?
    let attribution: String
    let url: String
    let role: SourceRole?
}

/// Global geomagnetic forecast context. Never a local visibility signal.
struct GlobalKpContext: Decodable, Sendable, Equatable {
    let status: KpContextStatus
    let sourceId: String
    let bins: [GlobalKpBin]
}

struct GlobalKpBin: Decodable, Sendable, Equatable {
    let interval: Interval
    let kp: Double
}

struct APIError: Decodable, Sendable, Equatable {
    let code: APIErrorCode
    let message: String
    let requestId: String
}
