import Foundation

/// A coordinate rounded to two decimals (at most about 0.6 km from the real point), the only
/// precision that leaves the phone or is stored (see docs/privacy.md). Its text forms never
/// show the numbers, so it can't end up in a log line by accident.
struct RoundedCoordinate: Codable, Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let latitude: Double
    let longitude: Double

    /// Decimals kept before a coordinate leaves the phone.
    static let decimals = 2

    init(latitude: Double, longitude: Double) {
        self.latitude = Self.round(min(max(latitude, -90), 90))
        self.longitude = Self.round(Self.wrap(longitude))
    }

    /// Rounds half away from zero to two decimals; never returns -0.
    static func round(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let rounded = (value * 100).rounded() / 100
        return rounded == 0 ? 0 : rounded
    }

    /// Longitude in -180...180.
    private static func wrap(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return 0 }
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// Stored values are rounded again on the way in, so a hand-edited file can't add precision.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude))
    }

    /// "69.65° N, 18.96° E", for the map pin panel only.
    var displayText: String {
        "\(Self.format(abs(latitude)))° \(latitude < 0 ? "S" : "N"), "
            + "\(Self.format(abs(longitude)))° \(longitude < 0 ? "W" : "E")"
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX")))
    }

    var description: String { "RoundedCoordinate(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A place saved on the phone: a name, its country and a rounded coordinate. Nothing else, and
/// it never leaves the phone except as the rounded coordinate of a forecast request.
struct SavedPlace: Codable, Sendable, Hashable, Identifiable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let id: UUID
    var name: String
    /// ISO 3166-1 alpha-2, for the country badge. Empty when MapKit gave none.
    var countryCode: String
    let coordinate: RoundedCoordinate
    /// The place's IANA time zone, which groups its nights. Falls back to the phone's.
    let timeZone: String

    init(id: UUID = UUID(), name: String, countryCode: String, coordinate: RoundedCoordinate,
         timeZone: String = TimeZone.current.identifier) {
        self.id = id
        self.name = name
        self.countryCode = countryCode.uppercased()
        self.coordinate = coordinate
        self.timeZone = TimeZone(identifier: timeZone)?.identifier ?? TimeZone.current.identifier
    }

    init(_ candidate: PlaceCandidate) {
        self.init(name: candidate.name, countryCode: candidate.countryCode,
                  coordinate: candidate.coordinate, timeZone: candidate.timeZone)
    }

    var query: ForecastQuery { ForecastQuery(coordinate, timezone: timeZone) }

    var description: String { "SavedPlace(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the forecast is for: a saved place, or the phone's location read once when needed.
enum PlaceSelection: Codable, Sendable, Hashable {
    case myLocation
    case saved(UUID)
}

/// A place found by search or the map, before it is saved.
struct PlaceCandidate: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    var name: String
    var countryCode: String
    let coordinate: RoundedCoordinate
    var timeZone: String

    init(name: String, countryCode: String, coordinate: RoundedCoordinate,
         timeZone: String = TimeZone.current.identifier) {
        self.name = name
        self.countryCode = countryCode.uppercased()
        self.coordinate = coordinate
        self.timeZone = timeZone
    }

    var description: String { "PlaceCandidate(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension TimeZone {
    /// A time zone for a place MapKit gave none for (offline, at sea, in the wilderness).
    /// The phone's zone when its offset is within 2 hours of the place's solar time, so a spot
    /// near home keeps its real zone and daylight saving; otherwise a fixed `Etc/GMT` zone
    /// from the longitude, so a far-away place doesn't get its nights grouped in the phone's.
    static func fallbackIdentifier(for coordinate: RoundedCoordinate, phone: TimeZone = .current,
                                   at date: Date = .now) -> String {
        let solarHours = coordinate.longitude / 15
        let phoneHours = Double(phone.secondsFromGMT(for: date)) / 3600
        if abs(phoneHours - solarHours) <= 2 { return phone.identifier }
        let hours = Int(solarHours.rounded())
        // Etc zones have the POSIX sign: Etc/GMT-1 is one hour ahead of UTC.
        return hours == 0 ? "Etc/GMT" : "Etc/GMT\(hours > 0 ? "-" : "+")\(abs(hours))"
    }
}

extension ForecastQuery {
    /// The request for a rounded coordinate. `ForecastQuery` rounds in any case.
    init(_ coordinate: RoundedCoordinate, timezone: String = TimeZone.current.identifier) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, timezone: timezone)
    }
}
