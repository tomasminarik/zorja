import SwiftUI

/// One hour of tonight (Figma: Hour mark): 58 pt in the strip, 88 pt for the selected hour, 48 pt
/// in the legend. A dark circle that says what the sky does in that hour:
/// filled yellow when clear and dark, a small yellow dot for gaps in the cloud, empty when cloudy,
/// in twilight or while loading, a dashed ring when the weather isn't known (or is out of date),
/// and only an outline in daylight. A magenta ring with a flickering glow marks live aurora.
/// Hours before now are drawn at 45 % by the Hour slot, not here.
struct HourMark: View {
    enum Sky: Sendable, CaseIterable {
        /// Clear and dark.
        case clear
        /// Gaps in the cloud (30–70 %).
        case partlyCloudy
        /// No clear time.
        case cloudy
        /// Weather not known, or the data is out of date.
        case unknown
        /// Clear, but too bright for the aurora.
        case twilight
        /// The sun is up.
        case daylight
        /// Checking the sky.
        case loading

        var label: String {
            switch self {
            case .clear: "Clear and dark"
            case .partlyCloudy: "Gaps in the cloud"
            case .cloudy: "Cloudy"
            case .unknown: "Weather not known"
            case .twilight: "Twilight"
            case .daylight: "Daylight"
            case .loading: "Checking"
            }
        }

        /// Daylight and loading have no aurora variant in Figma: no aurora is shown in a bright
        /// sky or before the sky is known.
        var canShowAurora: Bool { self != .daylight && self != .loading }
    }

    enum Size: Sendable, CaseIterable {
        /// In the strip.
        case regular
        /// The selected hour.
        case focus
        /// In the Hour legend.
        case legend

        var diameter: CGFloat {
            switch self {
            case .regular: ZorjaHour.size
            case .focus: ZorjaHour.focus
            case .legend: ZorjaHour.legend
            }
        }

        /// Width of the aurora ring.
        var auroraWidth: CGFloat { self == .legend ? 3 : 4 }

        /// How far the clear fill, the dashed ring and the aurora ring around a cloudy hour sit
        /// inside the circle.
        var inset: CGFloat {
            switch self {
            case .regular: 5
            case .focus: 4
            case .legend: 3
            }
        }

        /// How far the clear fill sits inside the circle when the aurora ring hugs its edge.
        var insetInsideAurora: CGFloat {
            switch self {
            case .regular: 10
            case .focus: 9
            case .legend: 6
            }
        }

        /// The yellow dot for gaps in the cloud.
        var gapDot: CGFloat {
            switch self {
            case .regular: 21
            case .focus: 32
            case .legend: 17
            }
        }
    }

    let sky: Sky
    var aurora = false
    var size: Size = .regular
    /// Where this ring is in the glow's flicker, so neighbouring rings don't flicker in step.
    var flickerPhase: Double = 0

    var showsAurora: Bool { aurora && sky.canShowAurora }

    /// The yellow fill inside the circle, if any.
    var clearDiameter: CGFloat? {
        switch sky {
        case .clear: size.diameter - 2 * (showsAurora ? size.insetInsideAurora : size.inset)
        case .partlyCloudy: size.gapDot
        default: nil
        }
    }

    /// The aurora ring hugs the circle's edge around a clear hour and sits `size.inset` in otherwise.
    var auroraInset: CGFloat { sky == .clear ? 0 : size.inset }

    var body: some View {
        let diameter = size.diameter
        ZStack {
            if sky == .daylight {
                Circle().strokeBorder(.lineOutline, lineWidth: 1.5)
            } else {
                Circle().fill(.dataTrack)
            }
            if let clearDiameter {
                Circle().fill(.dataClearSky).frame(width: clearDiameter, height: clearDiameter)
            }
            if sky == .unknown {
                Circle()
                    .strokeBorder(.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .padding(size.inset)
            }
            if showsAurora {
                Circle()
                    .strokeBorder(.dataAurora, lineWidth: size.auroraWidth)
                    .auroraGlow(phase: flickerPhase)
                    .padding(auroraInset)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(showsAurora ? "\(sky.label), aurora" : sky.label)
    }
}

/// The Figma "Aurora glow" effect (#E742FD at 55 %, blur 10), flickering like gas or a flame in
/// the wind: three waves of different speeds added together, so it never settles into an even
/// pulse, and the whole pattern repeats every `period` seconds. It holds still at full strength
/// under Reduce Motion, in Low Power Mode and while the app is in the background, the same rule
/// as the aurora sky.
enum HourGlow {
    /// The glow's colour opacity in Figma.
    static let opacity: Double = 0.55
    /// Figma's blur radius; SwiftUI's shadow radius is about half of it.
    static let blur: CGFloat = 10
    /// Seconds before the flicker repeats.
    static let period: TimeInterval = 6
    /// The faintest the glow gets, as a share of full strength.
    static let floor: Double = 0.4
    /// The waves: cycles per period, share of the swing, and offset. Whole cycles per period
    /// keep the loop seamless.
    private static let waves: [(cycles: Double, weight: Double, offset: Double)] = [
        (2, 0.5, 0), (5, 0.3, 1.3), (13, 0.2, 0.4),
    ]

    /// Glow strength from `floor` to 1 at `time` seconds, shifted by `phase` (0–1 of a period).
    static func strength(at time: TimeInterval, phase: Double = 0) -> Double {
        let t = (time / period + phase).truncatingRemainder(dividingBy: 1)
        let wave = waves.reduce(0) { $0 + $1.weight * sin(2 * .pi * ($1.cycles * t) + $1.offset) }  // -1…1
        return floor + (1 - floor) * (wave + 1) / 2
    }
}

private struct HourGlowEffect: ViewModifier {
    let phase: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = LowPowerModeMonitor()

    private var isStill: Bool {
        SkyMotion.isPaused(scenePhase: scenePhase, isLowPowerMode: lowPower.isEnabled, reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / SkyMotion.framesPerSecond, paused: isStill)) { context in
            let strength = isStill ? 1 : HourGlow.strength(at: context.date.timeIntervalSinceReferenceDate, phase: phase)
            content.shadow(
                color: .dataAurora.opacity(HourGlow.opacity * strength),
                radius: HourGlow.blur / 2 * (0.75 + 0.25 * strength)
            )
        }
    }
}

/// Loading circles breathe together between 45 % and full opacity, every four seconds; they
/// hold still under the same rule as the glow.
private struct LoadingBreathEffect: ViewModifier {
    static let period: TimeInterval = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = LowPowerModeMonitor()

    private var isStill: Bool {
        SkyMotion.isPaused(scenePhase: scenePhase, isLowPowerMode: lowPower.isEnabled, reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / SkyMotion.framesPerSecond, paused: isStill)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let strength = isStill ? 1 : (1 + cos(2 * .pi * phase)) / 2
            content.opacity(0.45 + 0.55 * strength)
        }
    }
}

extension View {
    /// The shared breathing of the loading circles on Tonight.
    func loadingBreath() -> some View {
        modifier(LoadingBreathEffect())
    }

    /// The flickering aurora glow of an Hour mark's ring.
    func auroraGlow(phase: Double = 0) -> some View {
        modifier(HourGlowEffect(phase: phase))
    }
}

/// What the hour under the readout means (Figma: Hour legend): the same Hour mark at Legend size,
/// then a title for the mark and the app's note for that time.
struct HourLegend: View {
    let sky: HourMark.Sky
    var aurora = false
    let title: String
    let note: String

    var body: some View {
        HStack(spacing: Space.s16) {
            HourMark(sky: sky, aurora: aurora, size: .legend)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.titleS)
                    .foregroundStyle(.textPrimary)
                Text(note)
                    .textStyle(.bodyM)
                    .foregroundStyle(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The system spinner while Tonight checks the sky (Figma: Activity indicator, 20 pt, spokes in
/// `text/secondary`).
struct ActivityIndicator: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.textSecondary)
            .frame(width: 20, height: 20)
            .accessibilityLabel("Checking the sky")
    }
}

/// One column of the Tonight timeline (Figma: Hour slot): the Hour mark above its hour. Regular:
/// a 58 pt mark with the hour 20 pt below in `text/secondary`. Focus, the selected hour: an 88 pt
/// mark with the hour 8 pt below in `text/primary`. A past hour's mark is at 45 %; its hour stays
/// at full strength. While loading the marks breathe instead.
struct HourSlot: View {
    /// Space between a Regular mark and its hour.
    static let regularLabelGap: CGFloat = 20
    /// Space between the Focus mark and its hour.
    static let focusLabelGap: CGFloat = 8
    /// Figma: Label/S, 14 pt line.
    static let labelHeight: CGFloat = 14
    /// The tallest slot, the Focus one: every slot sits on the same bottom line.
    static let height: CGFloat = ZorjaHour.focus + focusLabelGap + labelHeight

    let label: String
    let sky: HourMark.Sky
    var aurora = false
    var isFocus = false
    var isPast = false
    var flickerPhase: Double = 0

    var body: some View {
        let size: HourMark.Size = isFocus ? .focus : .regular
        VStack(spacing: isFocus ? Self.focusLabelGap : Self.regularLabelGap) {
            Group {
                if sky == .loading {
                    HourMark(sky: .loading, size: size).loadingBreath()
                } else {
                    HourMark(sky: sky, aurora: aurora, size: size, flickerPhase: flickerPhase)
                        .opacity(isPast ? 0.45 : 1)
                }
            }
            Text(label)
                .textStyle(.labelS)
                .foregroundStyle(isFocus ? Color.textPrimary : .textSecondary)
                .fixedSize()
                .frame(height: Self.labelHeight)
        }
        .frame(width: size.diameter)
        .accessibilityHidden(true)
    }
}

/// Tonight's timeline (Figma: Hour timeline): the time 10 pt above a strip of Hour slots, 8 pt
/// apart and bottom-aligned, with 16 pt under the hours and a hairline at the bottom. The
/// selected hour sits in the middle and the others run off both edges. `shift` moves the strip
/// with the finger during a swipe. The view spans the screen.
struct HourTimeline: View {
    struct Slot: Identifiable {
        let id: Date
        let label: String
        let sky: HourMark.Sky
        var aurora = false
        var isPast = false
    }

    /// One hour along the strip: a Regular mark and the gap after it.
    static let pitch: CGFloat = ZorjaHour.size + ZorjaHour.gap
    /// The selected mark is 30 pt wider than the others.
    static let focusExtra: CGFloat = ZorjaHour.focus - ZorjaHour.size
    /// Figma: the time above the strip.
    static let timeGap: CGFloat = 10
    /// Figma: Strip, under the hours.
    static let bottomPadding: CGFloat = 16
    /// The strip with its hairline.
    static let stripHeight: CGFloat = HourSlot.height + bottomPadding + 1

    let time: String
    let slots: [Slot]
    let focus: Int
    var shift: CGFloat = 0

    /// The centre of slot `index` from the strip's start, with `focus` drawn at Focus size.
    static func centre(of index: Int, focus: Int) -> CGFloat {
        CGFloat(index) * pitch + ZorjaHour.size / 2 + (index > focus ? focusExtra : index == focus ? focusExtra / 2 : 0)
    }

    var body: some View {
        VStack(spacing: Self.timeGap) {
            Text(time)
                .textStyle(.titleS)
                .foregroundStyle(.textPrimary)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            strip
        }
    }

    private var strip: some View {
        GeometryReader { proxy in
            let offset = proxy.size.width / 2 - Self.centre(of: focus, focus: focus) + shift
            ZStack(alignment: .topLeading) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let x = offset + Self.centre(of: index, focus: focus)
                    if x > -ZorjaHour.focus, x < proxy.size.width + ZorjaHour.focus {
                        HourSlot(label: slot.label, sky: slot.sky, aurora: slot.aurora, isFocus: index == focus,
                                 isPast: slot.isPast, flickerPhase: Double(index) * 0.37)
                            .frame(height: HourSlot.height, alignment: .bottom)
                            .position(x: x, y: HourSlot.height / 2)
                    }
                }
            }
        }
        .frame(height: HourSlot.height)
        .padding(.bottom, Self.bottomPadding + 1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.lineHairline).frame(height: 1)
        }
        .clipped()
        .contentShape(Rectangle())
    }
}
