import SwiftUI

struct ForecastScreen: View {
    let forecast: Forecast
    /// False once `refreshAfter` has passed.
    let isCurrent: Bool
    let showSources: () -> Void

    private var clock: LocalClock { LocalClock(timeZone: forecast.location.timeZone) }
    private var showsAurora: Bool { forecast.now.action == .tryNow && isCurrent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VerdictSection(forecast: forecast, clock: clock, isCurrent: isCurrent)
                NightsSection(forecast: forecast, clock: clock)
                Footer(forecast: forecast, showSources: showSources)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .top) {
            SkyBackdrop(factors: forecast.now.factors, showsAurora: showsAurora)
                .frame(height: 520)
                .ignoresSafeArea(edges: .top)
        }
        .background(Palette.background)
    }
}

// MARK: - Verdict

private struct VerdictSection: View {
    let forecast: Forecast
    let clock: LocalClock
    let isCurrent: Bool

    var body: some View {
        let now = forecast.now
        let headline = now.headline(upcoming: forecast.upcoming, clock: clock, isCurrent: isCurrent)
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(isCurrent ? "Now · \(clock.time(forecast.generatedAt))" : "Last checked \(clock.time(forecast.generatedAt))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(headline.title)
                    .font(.system(.largeTitle, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(headline.detail)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 44)

            VStack(spacing: 0) {
                ForEach(Array(now.factorLines.enumerated()), id: \.offset) { index, line in
                    if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                    FactorRow(line: line)
                }
            }
            .padding(.horizontal, 16)
            .background(Palette.surface, in: .rect(cornerRadius: 20))
        }
    }
}

private struct FactorRow: View {
    let line: FactorLine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: line.tone.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(line.tone.color)
                .frame(width: 24)
            Text(line.label)
                .fontWeight(.medium)
            Spacer(minLength: 12)
            Text(line.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Nights

private struct NightsSection: View {
    let forecast: Forecast
    let clock: LocalClock

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(forecast.planning.enumerated()), id: \.element.id) { index, night in
                PrototypeNightCard(
                    night: night, clock: clock,
                    evaluatedAt: forecast.generatedAt, isProminent: index == 0)
            }
        }
    }
}

private struct PrototypeNightCard: View {
    let night: PlanningNight
    let clock: LocalClock
    let evaluatedAt: Date
    let isProminent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(night.title(evaluatedAt: evaluatedAt, clock: clock))
                    .font(isProminent ? .title2.weight(.semibold) : .headline)
                Spacer()
                if let range = night.darkRange(clock: clock) {
                    Text(range)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            switch night.darknessStatus {
            case .windowsAvailable:
                NightTimeline(
                    windows: night.windows, marker: isProminent ? evaluatedAt : nil,
                    height: isProminent ? 64 : 32)
                    .accessibilityElement()
                    .accessibilityLabel("Dark \(night.darkRange(clock: clock) ?? ""). \(night.skySummary).")
                if isProminent {
                    Text("Taller bars mean clearer sky.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(night.skySummary, systemImage: "cloud")
                    KpLabel(night: night)
                }
            case .noDarkness:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Doesn't get dark enough", systemImage: "sun.max")
                    KpLabel(night: night)
                }
            case .unavailable:
                Label("Darkness times couldn't be calculated", systemImage: "questionmark.circle")
            }
        }
        .font(.subheadline)
        .labelStyle(NightLabelStyle())
        .padding(isProminent ? 20 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: 20))
    }
}

private struct KpLabel: View {
    let night: PlanningNight

    var body: some View {
        Label {
            Text(night.globalKpSummary)
            + Text(" · worldwide, not local").foregroundStyle(.tertiary)
        } icon: {
            Image(systemName: "globe")
        }
        .foregroundStyle(.secondary)
    }
}

private struct NightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 20)
            configuration.title
        }
    }
}

/// The night on one time axis: each evaluated segment is a bar whose height is how
/// clear the sky is forecast to be. Hollow dashed bars have no usable cloud forecast.
private struct NightTimeline: View {
    let windows: [ViewingWindow]
    let marker: Date?
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let start = windows.first?.interval.start, let end = windows.last?.interval.end,
                  end > start else { return }
            let span = end.timeIntervalSince(start)
            func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(start) / span }

            for window in windows {
                let baseline = CGRect(
                    x: x(window.interval.start), y: size.height - 1.5,
                    width: x(window.interval.end) - x(window.interval.start), height: 1.5)
                context.fill(Path(baseline), with: .color(.white.opacity(0.18)))

                for segment in window.segments {
                    let left = x(segment.interval.start)
                    let width = max(1, x(segment.interval.end) - left - 2)
                    if let clearness = segment.clearness {
                        let barHeight = max(4, (size.height - 3) * clearness)
                        let rect = CGRect(x: left, y: size.height - 3 - barHeight, width: width, height: barHeight)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                            with: .color(segment.factors.weather.barColor))
                    } else {
                        let rect = CGRect(x: left + 0.5, y: 0.5, width: max(1, width - 1), height: size.height - 4)
                        context.stroke(
                            Path(roundedRect: rect, cornerRadius: min(3, width / 2)),
                            with: .color(.white.opacity(0.28)),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }

            if let marker, marker >= start, marker < end {
                let position = max(1, x(marker))
                context.fill(
                    Path(CGRect(x: position - 1, y: 0, width: 2, height: size.height)),
                    with: .color(.white))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Footer

private struct Footer: View {
    let forecast: Forecast
    let showSources: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("An experimental assessment, not a probability of seeing aurora.")
            Text(attributions)
            Button("Data and limits", action: showSources)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var attributions: String {
        var seen = Set<String>()
        return forecast.sources.map(\.attribution).filter { seen.insert($0).inserted }.joined(separator: " · ")
    }
}

// MARK: - Sky backdrop

/// A depiction of the sky the assessment describes: brightness from the darkness
/// factor, stars only under a clear forecast, a veil under heavy cloud, and an
/// aurora glow only for a live `try_now`.
private struct SkyBackdrop: View {
    let factors: Factors
    let showsAurora: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)
            if isDark, factors.weather == .favorable || factors.weather == .mixed {
                StarField().opacity(factors.weather == .favorable ? 1 : 0.45)
            }
            if showsAurora { AuroraGlow() }
            if factors.weather == .obstructed {
                LinearGradient(
                    colors: [.white.opacity(0.20), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: 0.45), .init(color: Palette.background, location: 1)],
                startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }

    private var isDark: Bool {
        factors.darkness == .astronomicalNight || factors.darkness == .astronomicalTwilight
    }

    private var skyColors: [Color] {
        switch factors.darkness {
        case .daylight:
            [Color(red: 0.16, green: 0.34, blue: 0.60), Color(red: 0.38, green: 0.52, blue: 0.68)]
        case .civilTwilight, .nauticalTwilight:
            [Color(red: 0.09, green: 0.12, blue: 0.32), Color(red: 0.50, green: 0.30, blue: 0.30)]
        case .astronomicalTwilight, .astronomicalNight:
            [Color(red: 0.03, green: 0.06, blue: 0.17), Color(red: 0.05, green: 0.08, blue: 0.15)]
        case .mixed, .unknown:
            [Palette.background, Palette.background]
        }
    }
}

private struct StarField: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 33) / Double(1 << 31)
            }
            for _ in 0..<80 {
                let x = next() * size.width
                let y = next() * size.height * 0.8
                let radius = 0.4 + next() * 0.8
                let opacity = (0.25 + next() * 0.6) * (1 - y / size.height)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(opacity)))
            }
        }
    }
}

private struct AuroraGlow: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(
                    colors: [Palette.aurora.opacity(0.05), Palette.aurora.opacity(0.6), Color(red: 0.35, green: 0.55, blue: 1).opacity(0.3)],
                    startPoint: .bottom, endPoint: .top))
                .frame(width: 560, height: 230)
                .rotationEffect(.degrees(-14))
                .offset(x: -50, y: -70)
                .blur(radius: 55)
            Ellipse()
                .fill(Palette.aurora.opacity(0.35))
                .frame(width: 320, height: 110)
                .rotationEffect(.degrees(16))
                .offset(x: 100, y: 10)
                .blur(radius: 45)
        }
        .blendMode(.screen)
    }
}

// MARK: - Style

enum Palette {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.07)
    static let surface = Color.white.opacity(0.07)
    static let aurora = Color(red: 0.42, green: 0.95, blue: 0.66)
    static let clearSky = Color(red: 0.66, green: 0.83, blue: 1.0)
}

extension Tone {
    var color: Color {
        switch self {
        case .good: Palette.aurora
        case .blocked: Color(red: 1.0, green: 0.55, blue: 0.45)
        case .unknown: .secondary
        case .stale: Color(red: 1.0, green: 0.80, blue: 0.40)
        }
    }
}

extension WeatherFactor {
    var barColor: Color {
        switch self {
        case .favorable: Palette.clearSky
        case .mixed: Palette.clearSky.opacity(0.55)
        default: .white.opacity(0.26)
        }
    }
}
