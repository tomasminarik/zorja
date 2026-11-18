import Foundation
import Observation
import SwiftUI

/// How much of the aurora sky a screen shows. Values are the opacity of the
/// "Sky (Zorja Aurora Sky shader)" layer in the Figma Now and Forecast states frames.
enum SkyLevel: CaseIterable, Sendable {
    /// Go now, polar night, welcome, loading, offline with a current forecast.
    case full
    /// Partly cloudy: watch for gaps.
    case partlyCloudy
    /// Wait, twilight, weather unknown.
    case dim
    /// No sky: quiet, aurora unknown, skip, daytime, midnight sun, out of date, error.
    case off

    var opacity: Double {
        switch self {
        case .full: 1
        case .partlyCloudy: 0.6
        case .dim: 0.3
        case .off: 0
        }
    }
}

/// When the sky's slow motion runs.
enum SkyMotion {
    /// Frames per second while the sky moves.
    static let framesPerSecond: Double = 30

    /// The sky holds still unless the app is in front and nothing asks it to save
    /// battery or motion. `.inactive` (app switcher, Control Center) counts as hidden.
    static func isPaused(scenePhase: ScenePhase, isLowPowerMode: Bool, reduceMotion: Bool) -> Bool {
        scenePhase != .active || isLowPowerMode || reduceMotion
    }
}

/// Shader time that only advances while the sky runs, so the curtains carry on from
/// where they stopped instead of jumping after a pause.
struct SkyClock: Equatable {
    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?

    var isRunning: Bool { resumedAt != nil }

    mutating func setRunning(_ running: Bool, at now: Date) {
        if running, resumedAt == nil {
            resumedAt = now
        } else if !running, let resumedAt {
            accumulated += max(0, now.timeIntervalSince(resumedAt))
            self.resumedAt = nil
        }
    }

    /// Seconds the sky has been running up to `now`.
    func elapsed(at now: Date) -> TimeInterval {
        guard let resumedAt else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(resumedAt))
    }
}

/// Follows Low Power Mode through `NSProcessInfoPowerStateDidChange`.
@MainActor
@Observable
final class LowPowerModeMonitor {
    private(set) var isEnabled: Bool
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(
        center: NotificationCenter = .default,
        read: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.center = center
        isEnabled = read()
        // The notification arrives on any thread; the state is read again on the main actor.
        observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.isEnabled = read() }
        }
    }

    isolated deinit {
        if let observer { center.removeObserver(observer) }
    }
}
