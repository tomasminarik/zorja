import SwiftUI

/// Viewing tips (Figma: Screens → Tips): the eye-adjustment timer, the red screen and camera
/// tips, and the Before You Go checklist. Opened from Tonight's More Tips, with Close.
/// The timer lives in the shell, so it keeps running while Tips is closed.
struct TipsScreen: View {
    @Binding var timer: EyeTimer
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZorjaHeader(kind: .close(close))
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s12) {
                    Text("Out There.")
                        .textStyle(.displayL)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        EyeTimerCard(timer: $timer, now: context.date)
                    }
                    AdaptiveStack(verticalAlignment: .top, spacing: Space.s12) {
                        TipCard(icon: .phone, title: "Red Screen",
                                message: "Red light keeps your eyes used to the dark. Turn it on in iPhone Settings.")
                        TipCard(icon: .camera, title: "Use Camera",
                                message: "Faint aurora looks grey to the eye. Use Night mode and hold still.")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    BeforeYouGoCard()
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.s16)
                .padding(.bottom, Space.s32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.bgBase)
        .preferredColorScheme(.dark)
    }
}

/// The ring and words of the eye timer in its three Figma states: idle, running, ready.
struct EyeTimerCard: View {
    @Binding var timer: EyeTimer
    let now: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = timer.phase(at: now)
        AdaptiveStack(spacing: Space.s20) {
            EyeTimerRing(progress: EyeTimer.progress(phase), clock: EyeTimer.clock(phase), stage: Stage(phase))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Eye timer")
                .accessibilityValue(Self.spokenTime(phase))
                .accessibilityAddTraits(phase == .idle ? [] : .updatesFrequently)
            VStack(alignment: .leading, spacing: Space.s4) {
                // Each stage's words take the space of the longest, so the card never changes
                // height; the old words leave before the new ones rise in.
                ZStack(alignment: .topLeading) {
                    ForEach([Stage.idle, .running, .ready], id: \.self) { stage in
                        words(stage).hidden()
                    }
                    words(Stage(phase))
                        .id(Stage(phase))
                        .transition(Self.handover(reduceMotion))
                }
                Spacer().frame(height: Space.s4)
                // Outline buttons are 2 pt taller (Figma counts their stroke); keep that
                // height for every stage so the cards below never move.
                ZStack(alignment: .leading) {
                    ZorjaButton("Stop", style: .outline) {}.hidden().accessibilityHidden(true)
                    button(phase)
                        .id(Stage(phase))
                        .transition(Self.handover(reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s20)
        .zorjaCard()
        // Starting, stopping and finishing change the words, button and ring together.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : ZorjaMotion.rise, value: Stage(phase))
        .sensoryFeedback(trigger: Stage(phase)) { _, stage in
            switch stage {
            case .running: .impact(weight: .medium)
            case .ready: .success
            case .idle: nil
            }
        }
    }

    private func words(_ stage: Stage) -> some View {
        let phase: EyeTimer.Phase = switch stage {
        case .idle: .idle
        case .running: .running(remaining: EyeTimer.duration, progress: 0)
        case .ready: .ready
        }
        return VStack(alignment: .leading, spacing: Space.s4) {
            Text(Self.title(phase)).textStyle(.titleM).foregroundStyle(.textPrimary)
            Text(Self.message(phase)).textStyle(.bodyM).foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Old words and button fade out fast; the new ones rise in just after.
    static func handover(_ reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 6))
                .animation(.spring(duration: 0.4, bounce: 0.1).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    /// The timer's phase without its countdown, to animate only real changes.
    enum Stage: Hashable {
        case idle, running, ready
        init(_ phase: EyeTimer.Phase) {
            switch phase {
            case .idle: self = .idle
            case .running: self = .running
            case .ready: self = .ready
            }
        }
    }

    @ViewBuilder
    private func button(_ phase: EyeTimer.Phase) -> some View {
        switch phase {
        case .idle:
            ZorjaButton("Start Timer") { timer.start(at: .now) }
        case .running:
            ZorjaButton("Stop", style: .outline) { timer.stop() }
        case .ready:
            ZorjaButton("Start Again", style: .outline) { timer.start(at: .now) }
        }
    }

    static func title(_ phase: EyeTimer.Phase) -> String {
        switch phase {
        case .idle: "Let Your Eyes Adjust"
        case .running: "Eyes Adjusting"
        case .ready: "Your Eyes Are Ready"
        }
    }

    static func message(_ phase: EyeTimer.Phase) -> String {
        switch phase {
        case .idle: "That’s how long they take to adjust to the dark."
        case .running: "Keep Zorja open and stay away from bright light."
        case .ready: "Look up. Faint aurora can look grey at first."
        }
    }

    static func spokenTime(_ phase: EyeTimer.Phase) -> String {
        switch phase {
        case .idle: return "20 minutes"
        case .ready: return "Done"
        case let .running(remaining, _):
            let seconds = Int(remaining.rounded(.up))
            let minutes = seconds / 60
            return minutes > 0 ? "\(minutes) minutes \(seconds % 60) seconds left" : "\(seconds) seconds left"
        }
    }
}

/// 104 pt ring: a 6 pt hairline track and green progress from the top, clockwise, with round
/// ends (Figma: Timer card → Ring).
struct EyeTimerRing: View {
    static let size: CGFloat = 104
    static let lineWidth: CGFloat = 6

    let progress: Double
    let clock: String
    var stage: EyeTimerCard.Stage = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts starts and finishes, the moments the ring answers with a beat and a wave.
    @State private var beats = 0

    var body: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(.lineHairline, lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(.actionPrimary, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Each second's step fills in smoothly instead of ticking.
                .animation(.linear(duration: 1), value: progress)
            if !reduceMotion { sweep }
            Text(clock)
                .textStyle(.titleL)
                .foregroundStyle(.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: clock)
        }
        .frame(width: Self.size, height: Self.size)
        .onChange(of: stage) { _, new in if new != .idle { beats += 1 } }
        .keyframeAnimator(initialValue: 1.0, trigger: beats) { ring, scale in
            ring.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            // A beat when the timer starts or finishes.
            CubicKeyframe(0.92, duration: 0.15)
            SpringKeyframe(1.0, duration: 0.6, spring: .bouncy)
        }
    }

    /// On start and finish a dimmed green comet, its tail fading out, runs one rapid turn round
    /// the ring from the top and back, ending where progress begins.
    private var sweep: some View {
        Circle()
            .inset(by: Self.lineWidth / 2)
            .trim(from: 0, to: Self.cometLength)
            .stroke(
                AngularGradient(colors: [.actionPrimary.opacity(0), .actionPrimary.opacity(0.55)],
                                center: .center, startAngle: .zero, endAngle: .degrees(360 * Self.cometLength)),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            .keyframeAnimator(initialValue: Comet(), trigger: beats) { comet, value in
                comet
                    // The head starts at the top: back by the comet's length, then a quarter.
                    .rotationEffect(.degrees(-90 - 360 * Self.cometLength + value.turn * 360))
                    .opacity(value.opacity)
                    // The card animates the stage change; the comet runs on its own keyframes.
                    .transaction { $0.animation = nil }
            } keyframes: { _ in
                KeyframeTrack(\.turn) {
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 0.65)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.4)
                    LinearKeyframe(0, duration: 0.15)
                }
            }
            .allowsHitTesting(false)
    }

    /// The comet's length, as a share of the ring.
    static let cometLength: CGFloat = 0.35

    private struct Comet {
        var turn: Double = 0
        var opacity: Double = 0
    }
}

/// Three ticks, kept on this phone only (Figma: Before you go).
struct BeforeYouGoCard: View {
    /// UserDefaults keys; plain booleans, nothing about the person or place.
    static let keys = ["tips.checklist.dark", "tips.checklist.warm", "tips.checklist.time"]
    static let labels = ["Away from streetlights and town glow", "Warm layers, hat and gloves", "Ready to stay 30 to 60 minutes"]

    @AppStorage(keys[0]) private var dark = false
    @AppStorage(keys[1]) private var warm = false
    @AppStorage(keys[2]) private var time = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text("Before You Go").textStyle(.titleM).foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ChecklistItem(label: Self.labels[0], isChecked: $dark)
            ChecklistItem(label: Self.labels[1], isChecked: $warm)
            ChecklistItem(label: Self.labels[2], isChecked: $time)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s20)
        .zorjaCard()
        .sensoryFeedback(.success, trigger: dark && warm && time) { _, allDone in allDone }
    }
}

#Preview("Tips · Out There") {
    @Previewable @State var timer = EyeTimer()
    TipsScreen(timer: $timer) {}
}

#Preview("Tips · Timer running") {
    @Previewable @State var timer = EyeTimer(startedAt: .now.addingTimeInterval(-328))
    TipsScreen(timer: $timer) {}
}

#Preview("Tips · Eyes ready") {
    @Previewable @State var timer = EyeTimer(startedAt: .now.addingTimeInterval(-EyeTimer.duration))
    TipsScreen(timer: $timer) {}
}
