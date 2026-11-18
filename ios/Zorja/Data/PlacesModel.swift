import Foundation
import Observation

/// Places, the location read and search, shared by the shell and the Places screens.
@MainActor @Observable
final class PlacesModel {
    let store: PlaceStore
    let location: LocationReader
    let connectivity: Connectivity
    @ObservationIgnored let search: PlaceSearchService
    /// The developer menu's Offline app states (debug builds) count as offline too.
    var forcedOffline = false
    /// The town of the last location read, for the header. Memory only.
    private(set) var myLocationName: String?
    /// The result of the last location read, so Now can say "Can't Find You.". Memory only.
    private(set) var lastReading: LocationReader.Reading?
    /// True from the tap until the read ends, including the permission prompt.
    private(set) var isLocating = false

    init(store: PlaceStore, location: LocationReader, connectivity: Connectivity, search: PlaceSearchService) {
        self.store = store
        self.location = location
        self.connectivity = connectivity
        self.search = search
    }

    var isOffline: Bool { forcedOffline || !connectivity.isOnline }

    /// The header's place name. `fallback` is used while My Location has no reading yet: the
    /// sample's place on the bundled samples, "My Location" on the live service.
    func placeName(fallback: String) -> String {
        if let place = store.selectedPlace { return place.name }
        if location.coordinate != nil { return myLocationName ?? Self.myLocationTitle }
        // A read that found nothing still names the choice ("Can't Find You.").
        if lastReading == .notFound { return Self.myLocationTitle }
        return fallback
    }

    /// Shown for My Location when its town isn't known (proposed copy).
    static let myLocationTitle = "My Location"

    /// The forecast request for the selection: rounded coordinates and the place's time zone,
    /// or nil while My Location hasn't been read.
    var query: ForecastQuery? {
        if let place = store.selectedPlace { return place.query }
        return location.coordinate.map { ForecastQuery($0) }
    }

    /// Reads the location once and selects My Location. Asks for permission first if needed.
    @discardableResult
    func useMyLocation() async -> LocationReader.Reading {
        isLocating = true
        defer { isLocating = false }
        let reading = await location.readOnce()
        lastReading = reading
        switch reading {
        case .found(let coordinate):
            store.select(.myLocation)
            myLocationName = isOffline ? nil : await search.name(at: coordinate)?.locality
        case .notFound:
            // Now says "Can't Find You."; the choice still stands.
            store.select(.myLocation)
        case .off:
            break
        }
        return reading
    }

    /// Why Now has no place to check, if it has none: My Location is chosen and location is
    /// off (or was never asked), or the last read found nothing.
    var locationProblem: LocationProblem? {
        Self.locationProblem(hasPlace: store.selectedPlace != nil, access: location.access,
                             hasReading: location.coordinate != nil, lastReading: lastReading)
    }

    nonisolated static func locationProblem(
        hasPlace: Bool, access: LocationReader.Access, hasReading: Bool, lastReading: LocationReader.Reading?
    ) -> LocationProblem? {
        guard !hasPlace else { return nil }
        switch access {
        case .off, .notAsked: return .off
        // Allowed and not read yet (the launch read is running): no problem yet.
        case .allowed: return !hasReading && lastReading == .notFound ? .notFound : nil
        }
    }

    /// The launch read: only when My Location is selected and permission was already given.
    func refreshMyLocationIfAllowed() async {
        guard store.selection == .myLocation, location.access == .allowed, !isLocating else { return }
        await useMyLocation()
    }

    /// How old My Location may be when the app comes back to the foreground.
    static let myLocationMaxAge: TimeInterval = 30 * 60

    /// Back in the foreground: read My Location again if the last reading is old, since the
    /// phone may have travelled while Zorja was suspended. Still one read, only when needed.
    func refreshMyLocationIfOld(now: Date = .now) async {
        guard let readAt = location.readAt, now.timeIntervalSince(readAt) > Self.myLocationMaxAge else { return }
        await refreshMyLocationIfAllowed()
    }
}

extension PlacesModel {
    /// The app's places. Debug builds can start from fixed places and search answers
    /// (`DeveloperSettings`), kept in memory so they never replace the real ones.
    static func makeDefault() -> PlacesModel {
        let store: PlaceStore = switch DeveloperSettings.placesFixture {
        case "sample": PlaceStore(places: PlaceStore.samplePlaces)
        case "none": PlaceStore(places: [])
        default: PlaceStore()
        }
        let search: PlaceSearchService = DeveloperSettings.usesSampleSearch ? SamplePlaceSearch() : MapKitPlaceSearch()
        return PlacesModel(store: store, location: LocationReader(), connectivity: Connectivity(), search: search)
    }

    /// Sample places and fixed search answers, for previews.
    static func preview() -> PlacesModel {
        PlacesModel(store: PlaceStore(places: PlaceStore.samplePlaces), location: LocationReader(forcedOff: false),
                    connectivity: Connectivity(), search: SamplePlaceSearch())
    }
}
