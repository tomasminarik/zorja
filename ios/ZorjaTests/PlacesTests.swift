import CoreLocation
import Foundation
import Testing
@testable import Zorja

/// Places and location: coordinates are rounded to two decimals before every request and
/// before they are stored, and no location reaches URLs, logs or storage keys
/// (docs/privacy.md). Also the saved-place rules and search while typing.
@Suite("Places")
struct PlacesTests {
    /// Synthetic points with more precision than two decimals, across the hemispheres.
    static let rawPoints: [(Double, Double)] = [
        (69.649_234, 18.955_321), (59.329_3, 18.068_6), (64.146_6, -21.942_6),
        (-33.868_8, 151.209_3), (78.223_2, 15.626_7), (0.004_9, -0.004_9), (45.555_5, -73.554_4),
        (89.999_9, 179.999_9), (-89.999_9, -179.999_9), (60.169_9, 24.938_4),
    ]

    /// Digits that would give a raw point away: its first four decimals.
    static func fingerprints(_ point: (Double, Double)) -> [String] {
        [point.0, point.1].map { String(format: "%.4f", abs($0)) }
    }

    /// The number of decimals in each number of a JSON text.
    static func decimals(inJSON text: String) -> [Int] {
        let regex = /-?\d+(\.(\d+))?(e-?\d+)?/
        return text.matches(of: regex).map { $0.output.2.map { $0.count } ?? 0 }
    }

    // MARK: Rounding

    @Test func roundsToTwoDecimals() {
        let tromso = RoundedCoordinate(latitude: 69.649_234, longitude: 18.955_321)
        #expect(tromso.latitude == 69.65 && tromso.longitude == 18.96)
        let reykjavik = RoundedCoordinate(latitude: 64.146_6, longitude: -21.942_6)
        #expect(reykjavik.latitude == 64.15 && reykjavik.longitude == -21.94)
        // No negative zero, out-of-range values clamped or wrapped, nothing invalid.
        let nearZero = RoundedCoordinate(latitude: -0.001, longitude: -0.004)
        #expect(nearZero.latitude.sign == .plus && nearZero.longitude.sign == .plus)
        #expect(RoundedCoordinate(latitude: 95, longitude: 190) == RoundedCoordinate(latitude: 90, longitude: -170))
        #expect(RoundedCoordinate(latitude: .nan, longitude: .infinity) == RoundedCoordinate(latitude: 0, longitude: 0))
    }

    @Test("Rounding moves a point by at most half of 0.01°", arguments: rawPoints.indices)
    func roundingStaysWithinHalfAHundredth(_ index: Int) {
        let (latitude, longitude) = Self.rawPoints[index]
        let rounded = RoundedCoordinate(latitude: latitude, longitude: longitude)
        #expect(abs(rounded.latitude - latitude) <= 0.005 + 1e-9)
        #expect(abs(rounded.longitude - longitude) <= 0.005 + 1e-9)
        #expect(Self.decimals(inJSON: "\(rounded.latitude),\(rounded.longitude)").allSatisfy { $0 <= 2 })
    }

    /// Every forecast request body carries two decimals at most, however the query was made,
    /// and the URL carries no location.
    @Test("Every request is rounded and its URL is clean", arguments: rawPoints.indices)
    func everyRequestIsRounded(_ index: Int) throws {
        let point = Self.rawPoints[index]
        let client = ForecastClient(endpoint: ForecastEndpoint(baseURL: URL(string: "https://staging.invalid")!)!)
        let place = SavedPlace(name: "Synthetic", countryCode: "NO",
                               coordinate: RoundedCoordinate(latitude: point.0, longitude: point.1))
        let queries = [
            ForecastQuery(latitude: point.0, longitude: point.1, timezone: "Europe/Oslo"),
            ForecastQuery(RoundedCoordinate(latitude: point.0, longitude: point.1)),
            place.query,
        ]
        for query in queries {
            let request = try client.makeRequest(query)
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(Self.decimals(inJSON: body).allSatisfy { $0 <= 2 }, "\(body.count) bytes")
            let url = try #require(request.url?.absoluteString)
            #expect(url == "https://staging.invalid/v1/forecast")
            for digits in Self.fingerprints(point) {
                #expect(!body.contains(digits) && !url.contains(digits))
            }
        }
    }

    @MainActor @Test func theLocationReadIsRoundedBeforeItIsKept() async throws {
        let reader = LocationReader(forcedOff: false)
        let raw = CLLocation(latitude: 69.649_234, longitude: 18.955_321)
        reader.locationManager(CLLocationManager(), didUpdateLocations: [raw])
        for _ in 0..<100 where reader.coordinate == nil { await Task.yield() }
        let kept = try #require(reader.coordinate)
        #expect(kept == RoundedCoordinate(latitude: 69.65, longitude: 18.96))
        #expect(kept.latitude == 69.65)
    }

    @MainActor @Test func theRequestForTheSelectionIsRounded() {
        let model = PlacesModel(store: PlaceStore(places: PlaceStore.samplePlaces), location: LocationReader(forcedOff: true),
                                connectivity: Connectivity(), search: SamplePlaceSearch())
        let query = model.query
        #expect(query == ForecastQuery(latitude: 69.65, longitude: 18.96, timezone: "Europe/Oslo"))
        // My Location before any reading has no request, and the header keeps the sample's name.
        model.store.select(.myLocation)
        #expect(model.query == nil)
        #expect(model.placeName(fallback: "Stockholm") == "Stockholm")
    }

    // MARK: No location in logs, storage keys or stored precision

    @Test func locationValuesNeverDescribeThemselves() {
        let coordinate = RoundedCoordinate(latitude: 69.65, longitude: 18.96)
        let place = SavedPlace(name: "Tromsø", countryCode: "NO", coordinate: coordinate)
        let candidate = PlaceCandidate(name: "Tromsø", countryCode: "NO", coordinate: coordinate)
        let reading = LocationReader.Reading.found(coordinate)
        let query = place.query
        let values: [Any] = [coordinate, place, candidate, reading, query, [place], Optional(place) as Any]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
                #expect(!text.contains("69.6") && !text.contains("18.9"), "\(text)")
                #expect(!text.contains("Tromsø"), "\(text)")
            }
        }
    }

    @MainActor @Test func storageUsesOneFixedKeyAndRoundedCoordinates() throws {
        let suite = "PlacesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaceStore(defaults: defaults)
        for (latitude, longitude) in Self.rawPoints {
            store.add(PlaceCandidate(name: "Synthetic \(latitude)", countryCode: "no",
                                     coordinate: RoundedCoordinate(latitude: latitude, longitude: longitude)))
        }
        store.move(store.places[3].id, to: 0)
        store.remove(store.places[1].id)
        store.select(.myLocation)

        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        #expect(keys == [PlaceStore.storageKey])
        #expect(PlaceStore.storageKey.allSatisfy { !$0.isNumber || $0 == "1" })

        let stored = String(decoding: try #require(defaults.data(forKey: PlaceStore.storageKey)), as: UTF8.self)
        // Names here hold raw numbers on purpose; check only the coordinate fields.
        let object = try #require(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        let places = try #require(object["places"] as? [[String: Any]])
        #expect(places.count == Self.rawPoints.count - 1)
        for place in places {
            let coordinate = try #require(place["coordinate"] as? [String: Double])
            #expect(Set(coordinate.keys) == ["latitude", "longitude"])
            for value in coordinate.values {
                #expect(Self.decimals(inJSON: "\(value)").allSatisfy { $0 <= 2 })
            }
        }
    }

    @MainActor @Test func storedPrecisionIsRoundedAgainOnTheWayIn() throws {
        let suite = "PlacesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let json = """
            {"places":[{"id":"\(id.uuidString)","name":"Edited","countryCode":"NO",\
            "coordinate":{"latitude":69.649234,"longitude":18.955321},"timeZone":"Europe/Oslo"}],
            "selection":{"saved":{"_0":"\(id.uuidString)"}}}
            """
        defaults.set(Data(json.utf8), forKey: PlaceStore.storageKey)
        let store = PlaceStore(defaults: defaults)
        #expect(store.places.first?.coordinate.latitude == 69.65)
        #expect(store.places.first?.coordinate.longitude == 18.96)
        #expect(store.selection == .saved(id))
    }

    @MainActor @Test func unreadableStorageStartsEmpty() throws {
        let suite = "PlacesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: PlaceStore.storageKey)
        let store = PlaceStore(defaults: defaults)
        #expect(store.places.isEmpty && store.selection == .myLocation)
    }

    /// The app has no logging calls, so nothing (location included) can reach a log.
    @Test func theAppNeverLogs() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Zorja")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for call in ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump("] {
                #expect(!source.contains(call), "\(url.lastPathComponent) calls \(call)")
            }
            checked += 1
        }
        #expect(checked > 20)
    }

    @Test func locationIsAskedWhenInUseOnly() {
        let info = Bundle.main.infoDictionary ?? [:]
        let usage = info["NSLocationWhenInUseUsageDescription"] as? String
        #expect(usage?.isEmpty == false)
        #expect(info["NSLocationAlwaysAndWhenInUseUsageDescription"] == nil)
        #expect(info["NSLocationAlwaysUsageDescription"] == nil)
        #expect(info["UIBackgroundModes"] == nil)
    }

    // MARK: Saved places

    @MainActor @Test func removingThePlaceInUseSelectsTheNextOne() {
        let samples = PlaceStore.samplePlaces
        let store = PlaceStore(places: samples, selection: .saved(samples[1].id))
        store.remove(samples[1].id)
        #expect(store.selection == .saved(samples[2].id))
        // The last place in use: the one before it.
        store.select(.saved(samples[3].id))
        store.remove(samples[3].id)
        #expect(store.selection == .saved(samples[2].id))
        // Removing another place keeps the selection.
        store.remove(samples[0].id)
        #expect(store.selection == .saved(samples[2].id))
        // None left: back to your location.
        store.remove(samples[2].id)
        #expect(store.places.isEmpty && store.selection == .myLocation)
    }

    @MainActor @Test func reorderingAndAdding() {
        let samples = PlaceStore.samplePlaces
        let store = PlaceStore(places: samples)
        store.move(samples[2].id, to: 1)
        #expect(store.places.map(\.name) == ["Tromsø", "Rovaniemi", "Abisko", "Reykjavík"])
        store.move(samples[0].id, to: 99)
        #expect(store.places.last?.name == "Tromsø")
        // A new place goes to the end and is selected; the same spot again is not saved twice.
        let kiruna = PlaceCandidate(name: "Kiruna", countryCode: "se",
                                    coordinate: RoundedCoordinate(latitude: 67.855_8, longitude: 20.225_3),
                                    timeZone: "Europe/Stockholm")
        let added = store.add(kiruna)
        #expect(store.places.last == added && added.countryCode == "SE")
        #expect(store.selection == .saved(added.id))
        store.select(.saved(samples[1].id))
        let again = store.add(PlaceCandidate(name: "Kiruna again", countryCode: "SE", coordinate: kiruna.coordinate))
        #expect(again.id == added.id && store.places.count == 5 && store.selection == .saved(added.id))
        // An unknown place can't be selected.
        store.select(.saved(UUID()))
        #expect(store.selection == .saved(added.id))
    }

    @MainActor @Test func savedPlacesSurviveARelaunch() throws {
        let suite = "PlacesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PlaceStore(defaults: defaults)
        let tromso = first.add(PlaceCandidate(name: "Tromsø", countryCode: "NO",
                                              coordinate: RoundedCoordinate(latitude: 69.65, longitude: 18.96),
                                              timeZone: "Europe/Oslo"))
        first.add(PlaceCandidate(name: "Abisko", countryCode: "SE",
                                 coordinate: RoundedCoordinate(latitude: 68.35, longitude: 18.83)))
        first.select(.saved(tromso.id))
        let second = PlaceStore(defaults: defaults)
        #expect(second.places == first.places)
        #expect(second.selection == .saved(tromso.id))
        #expect(second.selectedPlace?.timeZone == "Europe/Oslo")
    }

    // MARK: Search while typing

    @MainActor static func phase(after text: String, offline: Bool = false,
                                 kind: PlaceSearchKind = .towns) async -> PlaceSearchModel.Phase {
        let model = PlaceSearchModel(kind: kind, service: SamplePlaceSearch()) { offline }
        model.debounce = .zero
        model.text = text
        for _ in 0..<200 where model.phase == .searching { await Task.yield() }
        return model.phase
    }

    @MainActor @Test func searchWhileTyping() async {
        guard case .results(let towns) = await Self.phase(after: "Tro") else {
            Issue.record("No results")
            return
        }
        #expect(towns.map(\.name) == ["Tromsø", "Trondheim", "Trollhättan", "Trois-Rivières"])
        #expect(towns.map(\.detail) == ["Troms, Norway", "Trøndelag, Norway", "Västra Götaland, Sweden", "Québec, Canada"])
        guard case .results(let addresses) = await Self.phase(after: "Prestvann", kind: .placesAndAddresses) else {
            Issue.record("No results")
            return
        }
        #expect(addresses.map(\.name) == ["Prestvannet", "Prestvannveien", "Prestvannveien 12"])
        #expect(await Self.phase(after: "Kvalsundd") == .noMatch("Kvalsundd"))
        #expect(await Self.phase(after: "Kiruna", offline: true) == .offline)
        #expect(await Self.phase(after: "   ") == .idle)
    }

    @MainActor @Test func aChosenSuggestionIsRounded() async throws {
        let service = SamplePlaceSearch()
        let tromso = try #require(try await service.suggestions(for: "Tromsø", kind: .towns).first)
        let candidate = try await service.resolve(tromso)
        #expect(candidate.coordinate == RoundedCoordinate(latitude: 69.65, longitude: 18.96))
        #expect(candidate.countryCode == "NO" && candidate.timeZone == "Europe/Oslo")
    }

    // MARK: Words and map

    @Test func copyMatchesAppCopy() {
        #expect(PlacesCopy.noMatch("Kvalsundd")
            == "No places match “Kvalsundd”. Try a nearby town, or pick the spot on the map.")
        #expect(PlacesCopy.searchOffline == "You’re offline, so search can’t look up places. Your saved places still work.")
        #expect(PlacesCopy.mapOffline
            == "You’re offline, so the map may not load and search can’t look up places. You can still save this spot.")
        #expect(PlacesCopy.moveTheMap == "Move the map to place the pin.")
        #expect(PlacesCopy.near("Tromsø") == "Near Tromsø")
        #expect(RoundedCoordinate(latitude: 69.65, longitude: 18.96).displayText == "69.65° N, 18.96° E")
        #expect(RoundedCoordinate(latitude: 64.1, longitude: -21.94).displayText == "64.10° N, 21.94° W")
        #expect(RoundedCoordinate(latitude: -33.87, longitude: 151.21).displayText == "33.87° S, 151.21° E")
    }

    @MainActor @Test func mapOpensOnTheRegionCountry() {
        #expect(MapRegions.country("NO")?.center.latitude == 65)
        #expect(MapRegions.country("ca") != nil)
        #expect(MapRegions.country("JP") == nil && MapRegions.country(nil) == nil)
        #expect(MapKitPlaceSearch.countryCode(named: "Norway") == "NO")
        #expect(MapKitPlaceSearch.countryCode(named: "Nowhere") == "")
    }

    @Test("A place without a MapKit time zone keeps the phone's only when it is near")
    func fallbackTimeZone() throws {
        let oslo = try #require(TimeZone(identifier: "Europe/Oslo"))
        let winter = Date(timeIntervalSince1970: 1_798_761_600)  // 2027-01-01
        func zone(_ lat: Double, _ lon: Double) -> String {
            TimeZone.fallbackIdentifier(for: RoundedCoordinate(latitude: lat, longitude: lon),
                                        phone: oslo, at: winter)
        }
        #expect(zone(69.65, 18.96) == "Europe/Oslo")  // Tromsø
        #expect(zone(60.17, 24.94) == "Europe/Oslo")  // Helsinki: near enough to keep the phone's
        #expect(zone(58.30, -134.42) == "Etc/GMT+9")  // Juneau, 10 h behind Oslo
        #expect(zone(-33.87, 151.21) == "Etc/GMT-10")
        #expect(TimeZone(identifier: zone(58.30, -134.42))?.secondsFromGMT(for: winter) == -9 * 3600)
        let utc = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(TimeZone.fallbackIdentifier(for: RoundedCoordinate(latitude: 51.5, longitude: -0.1),
                                            phone: utc, at: winter) == "Etc/GMT")
    }
}
