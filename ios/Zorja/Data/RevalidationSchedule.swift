import Foundation

/// When the next foreground forecast request may start. The floor limits request
/// rate only; it never keeps a recommendation alive past `refreshAfter`.
enum RevalidationSchedule {
    /// Per place: at most one request start a minute (docs/api.md).
    static let minimumFloor: TimeInterval = 60
    /// Across places: the shortest gap between any two request starts, so picking a new
    /// place loads at once but fast switching can't flood the service.
    static let minimumSpacing: TimeInterval = 5

    static func nextRequest(
        after lastRequestStart: Date, forecast: Forecast?, retryAfter: TimeInterval? = nil
    ) -> Date {
        let floor = max(
            minimumFloor,
            TimeInterval(forecast?.minimumRevalidationIntervalSeconds ?? 0),
            retryAfter ?? 0)
        let earliest = lastRequestStart.addingTimeInterval(floor)
        return max(earliest, forecast?.refreshAfter ?? earliest)
    }
}
