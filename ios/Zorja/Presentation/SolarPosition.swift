import Foundation

/// The sun's geometric altitude, from NOAA's solar calculator (Meeus, accurate to well under
/// 0.1° for current dates). The API gives darkness windows (sun at −12° or lower) but not
/// sunset or sunrise, which the Tonight arc needs for its twilight ends.
enum SolarPosition {
    /// Degrees above the horizon, without refraction, matching the backend's 0° daylight edge.
    static func altitude(at date: Date, latitude: Double, longitude: Double) -> Double {
        let rad = Double.pi / 180
        let julianDay = date.timeIntervalSince1970 / 86400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36525
        let meanLongitude = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = meanAnomaly * rad
        let centre = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t) + sin(3 * m) * 0.000289
        let omega = (125.04 - 1934.136 * t) * rad
        let apparentLongitude = (meanLongitude + centre - 0.00569 - 0.00478 * sin(omega)) * rad
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = (meanObliquity + 0.00256 * cos(omega)) * rad
        let declination = asin(sin(obliquity) * sin(apparentLongitude))

        let y = pow(tan(obliquity / 2), 2)
        let l0 = meanLongitude * rad
        let equationOfTime = 4 / rad * (y * sin(2 * l0) - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0) - 0.5 * y * y * sin(4 * l0)
            - 1.25 * eccentricity * eccentricity * sin(2 * m))
        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        let solarTime = minutesUTC + equationOfTime + 4 * longitude
        let hourAngle = (solarTime / 4 - 180) * rad

        let lat = latitude * rad
        let cosZenith = sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)
        return 90 - acos(min(1, max(-1, cosZenith))) / rad
    }

    /// The last moment the sun is up (altitude ≥ 0) before `date`, searching back no further
    /// than `limit`. Nil when it stays down all that time (polar night).
    static func sunset(before date: Date, notBefore limit: Date, latitude: Double, longitude: Double) -> Date? {
        crossing(from: date, to: limit, latitude: latitude, longitude: longitude)
    }

    /// The first moment the sun is up after `date`, searching no further than `limit`.
    static func sunrise(after date: Date, notAfter limit: Date, latitude: Double, longitude: Double) -> Date? {
        crossing(from: date, to: limit, latitude: latitude, longitude: longitude)
    }

    /// Sunset to sunrise around a night's dark time, clipped to the night's noon-to-noon period
    /// where the sun doesn't set or rise. Without dark time (midnight sun) it is the period.
    static func nightSpan(dark: [Interval], period: Interval, latitude: Double, longitude: Double) -> Interval {
        guard let first = dark.first, let last = dark.last else { return period }
        let sunset = Self.sunset(before: first.start, notBefore: period.start, latitude: latitude, longitude: longitude) ?? period.start
        let sunrise = Self.sunrise(after: last.end, notAfter: period.end, latitude: latitude, longitude: longitude) ?? period.end
        return Interval(start: min(sunset, first.start), end: max(sunrise, last.end))
    }

    /// Solar midnight: when the sun is lowest within `interval`, to the minute.
    static func lowest(in interval: Interval, latitude: Double, longitude: Double) -> Date {
        func altitude(_ date: Date) -> Double { Self.altitude(at: date, latitude: latitude, longitude: longitude) }
        func lowest(from start: Date, to end: Date, step: TimeInterval) -> Date {
            var best = start, time = start
            while time <= end {
                if altitude(time) < altitude(best) { best = time }
                time = time.addingTimeInterval(step)
            }
            return best
        }
        let rough = lowest(from: interval.start, to: interval.end, step: 600)
        return lowest(from: max(interval.start, rough.addingTimeInterval(-600)),
                      to: min(interval.end, rough.addingTimeInterval(600)), step: 60)
    }

    /// When darkness (sun at −12° or lower, as the backend counts it) began before `date`,
    /// searching back no further than `limit`. Nil when it was dark all that time.
    static func darkStart(before date: Date, notBefore limit: Date, latitude: Double, longitude: Double) -> Date? {
        crossing(from: date, to: limit, above: -12, latitude: latitude, longitude: longitude)
    }

    /// Walks from `start` (sun below `threshold`) towards `limit` in 10-minute steps until the
    /// sun is above it, then narrows the edge to a few seconds.
    private static func crossing(from start: Date, to limit: Date, above threshold: Double = 0,
                                 latitude: Double, longitude: Double) -> Date? {
        let step: TimeInterval = limit < start ? -600 : 600
        func isUp(_ date: Date) -> Bool {
            let altitude = altitude(at: date, latitude: latitude, longitude: longitude)
            return threshold == 0 ? altitude >= 0 : altitude > threshold
        }
        var down = start
        while true {
            var next = down.addingTimeInterval(step)
            if step < 0 ? next < limit : next > limit { next = limit }
            if isUp(next) {
                var (a, b) = (down, next)
                while abs(b.timeIntervalSince(a)) > 5 {
                    let mid = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                    if isUp(mid) { b = mid } else { a = mid }
                }
                return b
            }
            if next == limit { return nil }
            down = next
        }
    }
}
