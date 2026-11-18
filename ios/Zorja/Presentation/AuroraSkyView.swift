import SwiftUI

/// The aurora sky behind the Now screen: the "Sky (Zorja Aurora Sky shader)" layer,
/// drawn by `AuroraSkyRenderer`, with "Fade to black" over its bottom 360 pt.
///
/// The first time it shows (loading, at launch) the aurora rises from the horizon. Level
/// changes fade when the caller animates them. With Reduce Motion the sky simply appears.
///
/// The first sky of the app also draws the launch screen's green glow (`LaunchGlow`) and
/// fades it out while the aurora rises, so the launch screen hands over without a jump.
struct AuroraSkyView: View {
    var level: SkyLevel = .full
    var parameters = AuroraSkyParameters()

    /// Height of "Fade to black", the same on the 402 and 375 pt frames.
    static let fadeHeight: CGFloat = 360
    /// How long the aurora takes to rise.
    static let riseDuration: TimeInterval = 2.4

    /// The developer menu's choice of look; release builds never write it.
    @AppStorage(AuroraSkyStyle.defaultsKey) private var style = AuroraSkyStyle.appDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = LowPowerModeMonitor()
    @State private var hasRisen = false
    @State private var launchGlowDone = LaunchGlow.isFinished(at: .now)

    private var isPaused: Bool {
        SkyMotion.isPaused(scenePhase: scenePhase, isLowPowerMode: lowPower.isEnabled, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.bgBase)
            if level != .off {
                AuroraSkyMetalView(parameters: styled, isPaused: isPaused)
                    .opacity(level.opacity)
                    .mask { RiseMask(hasRisen: hasRisen) }
                    .transition(.opacity)
                    .onAppear(perform: rise)
                fade
                    .transition(.opacity)
            }
            if !launchGlowDone {
                // Driven by the clock, not by this view's state, so a sky that SwiftUI
                // recreates during launch carries on with the same fade.
                TimelineView(.animation) { context in
                    LaunchGlow().opacity(LaunchGlow.opacity(at: context.date))
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task { await handOverFromLaunch() }
    }

    private var styled: AuroraSkyParameters {
        var parameters = parameters
        parameters.style = style
        return parameters
    }

    private func handOverFromLaunch() async {
        guard !launchGlowDone else { return }
        LaunchGlow.startFade(at: .now, duration: reduceMotion ? LaunchGlow.reducedFade : Self.riseDuration)
        try? await Task.sleep(for: .seconds(LaunchGlow.remaining(at: .now)))
        launchGlowDone = true
    }

    private func rise() {
        guard !hasRisen else { return }
        if reduceMotion {
            hasRisen = true
        } else {
            withAnimation(.easeOut(duration: Self.riseDuration)) { hasRisen = true }
        }
    }

    /// "Fade to black": bg/base from clear at the top, 85 % at 55 %, solid at the bottom.
    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .bgBase.opacity(0), location: 0),
                .init(color: .bgBase.opacity(0.85), location: 0.55),
                .init(color: .bgBase, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.fadeHeight)
    }
}

/// The launch screen's green glow along the bottom edge (`LaunchScreen.storyboard`): the same
/// image at the same size, 240 pt tall and stretched to the screen's width.
struct LaunchGlow: View {
    static let height: CGFloat = 240
    /// With Reduce Motion the glow fades quickly instead of with the rise.
    static let reducedFade: TimeInterval = 0.4
    /// When the first sky of the app started fading the glow out, and for how long. Shared by
    /// every sky, so the hand-over happens once per launch.
    @MainActor private static var fade: (start: Date, duration: TimeInterval)?

    /// Starts the fade unless it has already started.
    @MainActor static func startFade(at date: Date, duration: TimeInterval) {
        if fade == nil { fade = (date, duration) }
    }

    /// Full until the fade starts, then easing out to nothing.
    @MainActor static func opacity(at date: Date) -> Double {
        guard let fade else { return 1 }
        let progress = min(max(date.timeIntervalSince(fade.start) / fade.duration, 0), 1)
        return (1 - progress) * (1 - progress)
    }

    @MainActor static func remaining(at date: Date) -> TimeInterval {
        guard let fade else { return 0 }
        return max(fade.duration - date.timeIntervalSince(fade.start), 0)
    }

    @MainActor static func isFinished(at date: Date) -> Bool {
        fade != nil && remaining(at: date) == 0
    }

    #if DEBUG
    @MainActor static func resetForTesting() { fade = nil }
    #endif

    var body: some View {
        Image("Launch/LaunchGlow")
            .resizable()
            .frame(height: Self.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
    }
}

/// Reveals the sky from the bottom up: a soft edge, a third of the screen tall, slides from
/// below the screen to above it.
private struct RiseMask: View {
    let hasRisen: Bool

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1.0 / 3)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: height * 1.5)
                .offset(y: hasRisen ? -height * 0.5 : height)
        }
    }
}

#if DEBUG
/// Development sheet: the sky at each level, side by side at a third of the Now frame.
struct AuroraSkyGallery: View {
    var body: some View {
        HStack(spacing: Space.s8) {
            ForEach(SkyLevel.allCases, id: \.self) { level in
                VStack(spacing: Space.s8) {
                    AuroraSkyView(level: level)
                        .frame(width: 402, height: 874)
                        .scaleEffect(1 / 3)
                        .frame(width: 134, height: 874 / 3)
                        .clipped()
                    Text(Self.caption(level)).textStyle(.bodyS).foregroundStyle(.textTertiary)
                }
            }
        }
        .padding(Space.s16)
        .background(.bgBase)
    }

    private static func caption(_ level: SkyLevel) -> String {
        switch level {
        case .full: "Full · 1"
        case .partlyCloudy: "Partly cloudy · 0.6"
        case .dim: "Dim · 0.3"
        case .off: "Off"
        }
    }
}

#Preview("Now frame") {
    AuroraSkyView()
}

#Preview("Levels") {
    AuroraSkyGallery()
}
#endif
