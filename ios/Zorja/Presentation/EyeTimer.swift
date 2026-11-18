import Foundation

/// The 20-minute eye-adjustment timer on Tips. It runs inside the app only (no notification,
/// Live Activity or background task) and counts from the time it was started, so it keeps
/// the right time if Tips is closed or the app is briefly left.
struct EyeTimer: Equatable, Sendable {
    static let duration: TimeInterval = 20 * 60

    /// When Start Timer was tapped; nil while idle.
    private(set) var startedAt: Date?

    enum Phase: Equatable, Sendable {
        case idle
        /// `remaining` in seconds, `progress` from 0 to 1.
        case running(remaining: TimeInterval, progress: Double)
        case ready
    }

    init(startedAt: Date? = nil) {
        self.startedAt = startedAt
    }

    mutating func start(at now: Date) { startedAt = now }
    mutating func stop() { startedAt = nil }

    func phase(at now: Date) -> Phase {
        guard let startedAt else { return .idle }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        guard elapsed < Self.duration else { return .ready }
        return .running(remaining: Self.duration - elapsed, progress: elapsed / Self.duration)
    }

    /// The ring's time: whole minutes and seconds left, rounded up, so it reads 20:00 when
    /// started and reaches 00:00 only when the eyes are ready.
    static func clock(_ phase: Phase) -> String {
        let seconds: Int
        switch phase {
        case .idle: seconds = Int(duration)
        case let .running(remaining, _): seconds = Int(remaining.rounded(.up))
        case .ready: seconds = 0
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The ring's filled share.
    static func progress(_ phase: Phase) -> Double {
        switch phase {
        case .idle: 0
        case let .running(_, progress): progress
        case .ready: 1
        }
    }
}
