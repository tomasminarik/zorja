import CoreLocation
import Foundation
import Observation

/// Reads the phone's location once, when the forecast needs it (docs/privacy.md). Permission is
/// When In Use and is asked only by `readOnce()`. The reading is rounded to two decimals straight
/// away and kept in memory only: nothing about it is stored or logged.
@MainActor @Observable
final class LocationReader: NSObject {
    enum Access: Sendable, Equatable {
        /// Not asked yet.
        case notAsked
        case allowed
        /// Denied, restricted or Location Services off: Places offers "Turn On Location".
        case off
    }

    enum Reading: Sendable, Equatable {
        case found(RoundedCoordinate)
        /// Allowed, but the phone couldn't work out where it is ("Can't Find You.").
        case notFound
        case off
    }

    private(set) var access: Access
    /// The last reading, rounded. Memory only.
    private(set) var coordinate: RoundedCoordinate?
    /// When `coordinate` was read, so a long-suspended app reads again on return.
    @ObservationIgnored private(set) var readAt: Date?
    private(set) var isReading = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var accessWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var readingWaiters: [CheckedContinuation<Reading, Never>] = []
    @ObservationIgnored private let forcedOff: Bool

    /// The longest a single read waits before it counts as not found.
    nonisolated static let timeout: Duration = .seconds(15)

    init(forcedOff: Bool = DeveloperSettings.locationOff) {
        self.forcedOff = forcedOff
        access = forcedOff ? .off : Self.access(for: manager.authorizationStatus)
        super.init()
        manager.delegate = self
        // The forecast needs no more than a kilometre; it is rounded to about that anyway.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks for When In Use permission if it hasn't been asked, then reads the location once.
    func readOnce() async -> Reading {
        if forcedOff { return .off }
        if access == .notAsked {
            manager.requestWhenInUseAuthorization()
            await withCheckedContinuation { accessWaiters.append($0) }
        }
        guard access == .allowed else { return .off }
        isReading = true
        defer { isReading = false }
        let timeout = Task { [weak self] in
            // Cancelled when the read finished: it must not end a later read early.
            guard (try? await Task.sleep(for: Self.timeout)) != nil else { return }
            self?.finish(.notFound)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            readingWaiters.append(continuation)
            if readingWaiters.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ reading: Reading) {
        if case .found(let coordinate) = reading {
            self.coordinate = coordinate
            readAt = .now
        }
        let waiters = readingWaiters
        readingWaiters = []
        waiters.forEach { $0.resume(returning: reading) }
    }

    private func update(_ status: CLAuthorizationStatus) {
        guard !forcedOff else { return }
        access = Self.access(for: status)
        if access != .notAsked {
            let waiters = accessWaiters
            accessWaiters = []
            waiters.forEach { $0.resume() }
        }
        if access == .off { finish(.off) }
    }

    nonisolated static func access(for status: CLAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .notAsked
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        default: .off
        }
    }
}

extension LocationReader: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.update(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Rounded before it goes anywhere, including this object.
        guard let last = locations.last else { return }
        let rounded = RoundedCoordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        Task { @MainActor in self.finish(.found(rounded)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in self.finish(denied ? .off : .notFound) }
    }
}
