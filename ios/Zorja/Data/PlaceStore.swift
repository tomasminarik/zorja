import Foundation
import Observation

/// Saved places and which place is selected, kept on the phone only (docs/privacy.md).
///
/// Everything is stored as one JSON value under a fixed key, so no storage key ever contains a
/// name or coordinate. Coordinates are rounded to two decimals before they are stored.
@MainActor @Observable
final class PlaceStore {
    /// The only key this store writes. Fixed, so it can never carry a location.
    nonisolated static let storageKey = "places.v1"

    private(set) var places: [SavedPlace]
    private(set) var selection: PlaceSelection

    @ObservationIgnored private let defaults: UserDefaults?

    private struct Stored: Codable {
        var places: [SavedPlace]
        var selection: PlaceSelection
    }

    /// `defaults: nil` keeps everything in memory (screenshots, previews).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let stored = defaults?.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        places = stored?.places ?? []
        selection = stored?.selection ?? .myLocation
        if case .saved(let id) = selection, !places.contains(where: { $0.id == id }) {
            selection = .myLocation
        }
    }

    /// In memory only, with the given places; the first is selected.
    init(places: [SavedPlace], selection: PlaceSelection? = nil) {
        defaults = nil
        self.places = places
        self.selection = selection ?? places.first.map { .saved($0.id) } ?? .myLocation
    }

    var selectedPlace: SavedPlace? {
        guard case .saved(let id) = selection else { return nil }
        return places.first { $0.id == id }
    }

    func select(_ selection: PlaceSelection) {
        if case .saved(let id) = selection, !places.contains(where: { $0.id == id }) { return }
        self.selection = selection
        save()
    }

    /// Saves a found place and selects it. A place already saved at the same rounded coordinate
    /// is selected instead of being saved twice. New places go to the end of the list.
    @discardableResult
    func add(_ candidate: PlaceCandidate) -> SavedPlace {
        if let existing = places.first(where: { $0.coordinate == candidate.coordinate }) {
            select(.saved(existing.id))
            return existing
        }
        let place = SavedPlace(candidate)
        places.append(place)
        selection = .saved(place.id)
        save()
        return place
    }

    /// Removing the place in use selects the next saved place (the one that moves into its
    /// slot, or the one before it if it was last); with none left, the app goes back to your
    /// location (decision of 2026-11-05).
    func remove(_ id: UUID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places.remove(at: index)
        if selection == .saved(id) {
            if places.indices.contains(index) {
                selection = .saved(places[index].id)
            } else if let last = places.last {
                selection = .saved(last.id)
            } else {
                selection = .myLocation
            }
        }
        save()
    }

    /// Moves a place to `destination`, an index in the list after the move.
    func move(_ id: UUID, to destination: Int) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        let place = places.remove(at: index)
        places.insert(place, at: min(max(destination, 0), places.count))
        save()
    }

    private func save() {
        guard let defaults else { return }
        let stored = Stored(places: places, selection: selection)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension PlaceStore {
    /// Public city centres for screenshots and previews (Figma: Places).
    static let samplePlaces: [SavedPlace] = [
        SavedPlace(name: "Tromsø", countryCode: "NO",
                   coordinate: RoundedCoordinate(latitude: 69.65, longitude: 18.96), timeZone: "Europe/Oslo"),
        SavedPlace(name: "Abisko", countryCode: "SE",
                   coordinate: RoundedCoordinate(latitude: 68.35, longitude: 18.83), timeZone: "Europe/Stockholm"),
        SavedPlace(name: "Rovaniemi", countryCode: "FI",
                   coordinate: RoundedCoordinate(latitude: 66.50, longitude: 25.73), timeZone: "Europe/Helsinki"),
        SavedPlace(name: "Reykjavík", countryCode: "IS",
                   coordinate: RoundedCoordinate(latitude: 64.15, longitude: -21.94), timeZone: "Atlantic/Reykjavik"),
    ]
}
