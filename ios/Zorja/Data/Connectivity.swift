import Foundation
import Network
import Observation

/// Whether the phone has a connection, for the offline versions of search and the map.
/// Debug builds count the developer menu's Offline app states as offline too.
@MainActor @Observable
final class Connectivity {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "Zorja.Connectivity"))
    }

    deinit { monitor.cancel() }
}
