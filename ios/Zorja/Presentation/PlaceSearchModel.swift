import Foundation
import Observation

/// Search while typing, for Places and Pick On Map (decision of 2026-11-05): suggestions
/// replace the list; when nothing matches the screen says so; offline it says search can't
/// look up places.
@MainActor @Observable
final class PlaceSearchModel {
    enum Phase: Equatable {
        /// Nothing typed: Places shows its actions and list.
        case idle
        /// Waiting for the first answer to this text.
        case searching
        case results([PlaceSuggestion])
        case noMatch(String)
        case offline
    }

    var text = "" {
        didSet { if text != oldValue { schedule() } }
    }
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let kind: PlaceSearchKind
    @ObservationIgnored private let service: PlaceSearchService
    @ObservationIgnored private let isOffline: () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The pause after a keystroke before asking MapKit.
    @ObservationIgnored var debounce: Duration = .milliseconds(200)

    init(kind: PlaceSearchKind, service: PlaceSearchService, isOffline: @escaping () -> Bool) {
        self.kind = kind
        self.service = service
        self.isOffline = isOffline
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Re-reads the connection (it may have changed while the text didn't).
    func refresh() { schedule(immediately: true) }

    private func schedule(immediately: Bool = false) {
        task?.cancel()
        let query = trimmed
        guard !query.isEmpty else {
            phase = .idle
            return
        }
        guard !isOffline() else {
            phase = .offline
            return
        }
        // Earlier suggestions stay on screen while the next ones load.
        if case .results = phase {} else { phase = .searching }
        task = Task { [weak self, debounce] in
            if !immediately { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled, let self else { return }
            do {
                let found = try await self.service.suggestions(for: query, kind: self.kind)
                guard !Task.isCancelled else { return }
                self.phase = found.isEmpty ? .noMatch(query) : .results(found)
            } catch PlaceSearchError.cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A failed lookup while the connection is up reads as offline, the only
                // reason search can't answer that the person can act on.
                self.phase = .offline
            }
        }
    }
}
