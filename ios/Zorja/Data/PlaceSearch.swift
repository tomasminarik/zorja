import Foundation
import MapKit
import Observation

/// One suggestion while typing (Figma: Search result row).
struct PlaceSuggestion: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    /// Region and country, or the address for addresses.
    let detail: String
}

/// What a search looks for. Places: towns and areas. Pick On Map: places and addresses.
enum PlaceSearchKind: Sendable {
    case towns
    case placesAndAddresses
}

/// A name for a spot on the map, from a reverse lookup of its rounded coordinate.
struct SpotName: Sendable, Equatable {
    /// Town or city ("Tromsø"); nil at sea or in the wilderness.
    var locality: String?
    /// Country name ("Norway").
    var country: String?
    var countryCode: String
    var timeZone: String?
}

/// Apple's place search, behind a protocol so tests and screenshots can use fixed answers.
/// Everything sent to Apple is either the typed text or a rounded coordinate.
@MainActor
protocol PlaceSearchService: AnyObject {
    func suggestions(for text: String, kind: PlaceSearchKind) async throws -> [PlaceSuggestion]
    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceCandidate
    func name(at coordinate: RoundedCoordinate) async -> SpotName?
    /// The map region of a country, for opening Pick On Map on the phone's Region.
    func region(ofCountry code: String) async -> MKCoordinateRegion?
}

enum PlaceSearchError: Error {
    case cancelled
    case notFound
}

// MARK: - MapKit

/// MapKit search while typing (`MKLocalSearchCompleter`), resolving a chosen suggestion with
/// `MKLocalSearch` and naming a pinned spot with `MKReverseGeocodingRequest`. All free.
@MainActor
final class MapKitPlaceSearch: NSObject, PlaceSearchService {
    private var completer = MKLocalSearchCompleter()
    private var pending: CheckedContinuation<[PlaceSuggestion], Error>?
    private var pendingKind: PlaceSearchKind = .towns
    private var completions: [String: MKLocalSearchCompletion] = [:]

    override init() {
        super.init()
        completer.delegate = self
    }

    func suggestions(for text: String, kind: PlaceSearchKind) async throws -> [PlaceSuggestion] {
        pending?.resume(throwing: PlaceSearchError.cancelled)
        pending = nil
        let types: MKLocalSearchCompleter.ResultType = kind == .towns ? [.address] : [.address, .pointOfInterest, .query]
        if completer.queryFragment == text, completer.resultTypes == types {
            // The same search again (back online, or after a failed resolve). A completer
            // doesn't call back when its fragment is unchanged, so ask a new one.
            completer.cancel()
            completer.delegate = nil
            completer = MKLocalSearchCompleter()
            completer.delegate = self
        }
        completer.resultTypes = types
        pendingKind = kind
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            completer.queryFragment = text
        }
    }

    /// Keeps the completions for `resolve` and turns them into suggestions.
    private func receive(_ results: [MKLocalSearchCompletion]) -> [PlaceSuggestion] {
        // Query suggestions ("coffee near…") have no place behind them.
        let places = results.filter { !$0.subtitle.isEmpty || pendingKind == .towns }
        completions = Dictionary(places.map { (Self.id(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        return places.map { PlaceSuggestion(id: Self.id(of: $0), name: $0.title, detail: $0.subtitle) }
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceCandidate {
        guard let completion = completions[suggestion.id] else { throw PlaceSearchError.notFound }
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else { throw PlaceSearchError.notFound }
        let point = item.location.coordinate
        let coordinate = RoundedCoordinate(latitude: point.latitude, longitude: point.longitude)
        return PlaceCandidate(
            name: suggestion.name,
            countryCode: Self.countryCode(of: item),
            coordinate: coordinate,
            timeZone: item.timeZone?.identifier ?? TimeZone.fallbackIdentifier(for: coordinate))
    }

    func name(at coordinate: RoundedCoordinate) async -> SpotName? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        // The app is English only, whatever the phone's language.
        request.preferredLocale = Locale(identifier: "en")
        guard let item = try? await request.mapItems.first else { return nil }
        return SpotName(
            locality: item.addressRepresentations?.cityName,
            country: item.addressRepresentations?.regionName,
            countryCode: Self.countryCode(of: item),
            timeZone: item.timeZone?.identifier)
    }

    func region(ofCountry code: String) async -> MKCoordinateRegion? {
        guard let country = Locale(identifier: "en_US_POSIX").localizedString(forRegionCode: code) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = country
        request.resultTypes = .address
        return try? await MKLocalSearch(request: request).start().boundingRegion
    }

    private static func id(of completion: MKLocalSearchCompletion) -> String {
        "\(completion.title)\u{1F}\(completion.subtitle)"
    }

    /// ISO code from the item's country name, matched against every region Foundation knows.
    static func countryCode(of item: MKMapItem) -> String {
        guard let name = item.addressRepresentations?.regionName else { return "" }
        return countryCode(named: name)
    }

    static func countryCode(named name: String) -> String {
        let locales = [Locale.current, Locale(identifier: "en_US_POSIX")]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            for locale in locales where locale.localizedString(forRegionCode: region.identifier) == name {
                return region.identifier
            }
        }
        return ""
    }
}

// MapKit calls the completer's delegate on the main thread.
extension MapKitPlaceSearch: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer else { return }
        pending?.resume(returning: receive(completer.results))
        pending = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer else { return }
        // MapKit reports "no results" as an error too.
        if (error as? MKError)?.code == .placemarkNotFound {
            pending?.resume(returning: [])
        } else {
            pending?.resume(throwing: error)
        }
        pending = nil
    }
}

// MARK: - Fixed answers

/// Fixed answers from the Figma frames, for screenshots (`-placeSearch sample`) and tests.
/// The coordinates are public town centres.
@MainActor
final class SamplePlaceSearch: PlaceSearchService {
    struct Entry {
        let name: String
        let detail: String
        let countryCode: String
        let latitude: Double
        let longitude: Double
        let timeZone: String
    }

    static let towns: [Entry] = [
        Entry(name: "Tromsø", detail: "Troms, Norway", countryCode: "NO", latitude: 69.6492, longitude: 18.9553, timeZone: "Europe/Oslo"),
        Entry(name: "Trondheim", detail: "Trøndelag, Norway", countryCode: "NO", latitude: 63.4305, longitude: 10.3951, timeZone: "Europe/Oslo"),
        Entry(name: "Trollhättan", detail: "Västra Götaland, Sweden", countryCode: "SE", latitude: 58.2837, longitude: 12.2886, timeZone: "Europe/Stockholm"),
        Entry(name: "Trois-Rivières", detail: "Québec, Canada", countryCode: "CA", latitude: 46.3432, longitude: -72.5432, timeZone: "America/Toronto"),
        Entry(name: "Kiruna", detail: "Norrbotten, Sweden", countryCode: "SE", latitude: 67.8558, longitude: 20.2253, timeZone: "Europe/Stockholm"),
    ]

    static let addresses: [Entry] = [
        Entry(name: "Prestvannet", detail: "Tromsø, Norway", countryCode: "NO", latitude: 69.6614, longitude: 18.9349, timeZone: "Europe/Oslo"),
        Entry(name: "Prestvannveien", detail: "9010 Tromsø, Norway", countryCode: "NO", latitude: 69.6588, longitude: 18.9372, timeZone: "Europe/Oslo"),
        Entry(name: "Prestvannveien 12", detail: "9010 Tromsø, Norway", countryCode: "NO", latitude: 69.6581, longitude: 18.9388, timeZone: "Europe/Oslo"),
    ]

    func suggestions(for text: String, kind: PlaceSearchKind) async throws -> [PlaceSuggestion] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let pool = kind == .towns ? Self.towns : Self.addresses + Self.towns
        return pool.filter { $0.name.lowercased().hasPrefix(needle) }
            .prefix(4)
            .map { PlaceSuggestion(id: $0.name, name: $0.name, detail: $0.detail) }
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> PlaceCandidate {
        guard let entry = (Self.towns + Self.addresses).first(where: { $0.name == suggestion.id }) else {
            throw PlaceSearchError.notFound
        }
        return PlaceCandidate(
            name: entry.name, countryCode: entry.countryCode,
            coordinate: RoundedCoordinate(latitude: entry.latitude, longitude: entry.longitude),
            timeZone: entry.timeZone)
    }

    func name(at coordinate: RoundedCoordinate) async -> SpotName? {
        // Near Tromsø, as in Figma, for anything in northern Norway.
        if (68...71).contains(coordinate.latitude), (15...24).contains(coordinate.longitude) {
            return SpotName(locality: "Tromsø", country: "Norway", countryCode: "NO", timeZone: "Europe/Oslo")
        }
        return nil
    }

    func region(ofCountry code: String) async -> MKCoordinateRegion? {
        code == "NO"
            ? MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 65.0, longitude: 15.0),
                                 span: MKCoordinateSpan(latitudeDelta: 16, longitudeDelta: 24))
            : nil
    }
}
