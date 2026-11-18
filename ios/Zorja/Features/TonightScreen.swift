import SwiftUI

/// The Tonight screen (Figma: Screens → Tonight and 3 Nights, and every "· Tonight" frame).
///
/// A top under the header (place line, headline, lead) on `surface/top` that stays put, then a
/// Body centred between the top and the menu: the glass tips card, the Hour timeline and the
/// legend for the selected hour. The tips card is dropped when it
/// would not fit without scrolling. Too bright to see aurora, the Body is only "Aurora Needs
/// Darkness" and its line. On small iPhones the headline drops to 40 pt.
struct TonightScreen: View {
    /// Display/L size where the content is narrower than on the 402 pt frame.
    nonisolated static let smallHeadlineSize: CGFloat = NowScreen.smallBottomLineSize
    /// Figma: Body, between the tips card and the forecast.
    static let cardGap: CGFloat = 30
    /// The least space kept above and below the Body when deciding whether the card fits.
    static let bodyMargin: CGFloat = Space.s16

    let tonight: TonightState
    let status: StatusLine?
    var openTips: () -> Void = {}
    var openThreeNights: () -> Void = {}

    /// Hours the readout has been swiped ahead of now.
    @State private var hoursAhead: Double = 0
    /// The space between the top and the menu: the scroll view's container size leaves out the
    /// bars it runs under.
    @State private var visibleHeight: CGFloat = 0
    @State private var forecastHeight: CGFloat = 0
    /// The card's height when it last showed; Figma's two-line card until then.
    @State private var cardHeight: CGFloat = 74

    /// The tips card shows only when it fits with the forecast without scrolling.
    static func showsCard(visible: CGFloat, forecast: CGFloat, card: CGFloat) -> Bool {
        forecast + cardGap + card + 2 * bodyMargin <= visible
    }

    private var showsCard: Bool {
        tonight.card != nil && Self.showsCard(visible: visibleHeight, forecast: forecastHeight, card: cardHeight)
    }

    var body: some View {
        ScrollView {
            Group {
                if tonight.tooBright {
                    needsDarkness
                } else {
                    forecastBody
                        .frame(maxWidth: .infinity, minHeight: visibleHeight)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            visibleHeight = height
        }
        .scrollsUnderHeader(background: .surfaceTop) { top }
        .scrollsUnderMenu()
    }

    /// Figma: Body. Centred by the frame around it.
    private var forecastBody: some View {
        VStack(spacing: 0) {
            if let card = tonight.card, showsCard {
                actionCard(card)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardHeight = $0 }
                    .padding(.bottom, Self.cardGap)
                    .riseIn(2)
            }
            TonightForecast(strip: tonight.strip, hoursAhead: $hoursAhead)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { forecastHeight = $0 }
                .riseIn(3)
        }
        .padding(.vertical, Self.bodyMargin)
    }

    private func actionCard(_ card: TonightCard) -> some View {
        ActionCard(message: card.message, buttonTitle: card.buttonTitle) {
            switch card {
            case .giveYourEyes: openTips()
            case .clearer: openThreeNights()
            }
        }
        .coverSource(card == .giveYourEyes ? "tips" : "card", cornerRadius: Radius.full)
        .padding(.horizontal, Space.screenMargin)
    }

    /// Too bright: 30 pt under the top, from the left.
    private var needsDarkness: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Aurora Needs Darkness")
                .textStyle(.titleL)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("It shows only when the sky is truly dark, with the sun at least 12° below the horizon.")
                .textStyle(.bodyM)
                .foregroundStyle(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.screenMargin)
        .padding(.top, 30)
        .padding(.bottom, Space.s24)
        .riseIn(2)
    }

    /// Figma: Hero. 16 pt under the header, 30 pt between the place line and the headline,
    /// 15 pt between the lines below it, 28 pt at the bottom.
    private var top: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let placeLine = tonight.placeLine {
                PlaceLine(text: placeLine)
                    .riseIn(0)
            }
            VStack(alignment: .leading, spacing: 15) {
                if case .offline = status, let status {
                    AdaptiveStack(spacing: Space.s8) {
                        ZorjaTag(kind: .offline)
                        Text(status.text).textStyle(.bodyS).foregroundStyle(.textTertiary)
                    }
                    .frame(minHeight: 18)
                }
                ScreenHeadline(phrase: tonight.headline)
                Text(tonight.lead)
                    .textStyle(.bodyL)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .riseIn(1)
        }
        .padding(.horizontal, Space.screenMargin)
        .padding(.top, Space.s16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// VoiceOver moves the readout an hour per swipe up or down, only when it can move.
private struct HourSteps: ViewModifier {
    let enabled: Bool
    let step: (Double) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityHint("Swipe up or down to move by an hour.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
        } else {
            content
        }
    }
}

/// The headline of Tonight and 3 Nights (Display/L from the left), at 40 pt where the content
/// is narrower than on the 402 pt frame.
struct ScreenHeadline: View {
    let phrase: Phrase

    @State private var width = NowScreen.figmaContentWidth

    var body: some View {
        let size: CGFloat? = width < NowScreen.figmaContentWidth ? TonightScreen.smallHeadlineSize : nil
        BalancedText(phrase, style: .displayL, size: size, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// Figma: Tonight’s forecast. The Hour timeline, then 30 pt below it the legend for the
/// selected hour (the activity indicator while loading). Swiping the strip moves the readout in
/// 5-minute steps, never before now or past tonight's dark time; at rest the selected hour sits in
/// the middle of the screen. The view spans the screen.
struct TonightForecast: View {
    let strip: TonightStrip
    @Binding var hoursAhead: Double

    /// Figma: between the Hour timeline and the Hour legend.
    static let legendGap: CGFloat = 30
    static let pitch = HourTimeline.pitch

    /// A released swipe glides on with the flick's speed and settles on a 5-minute step.
    static let glide = Animation.spring(duration: 0.6, bounce: 0)
    /// How much of the flick's predicted run the readout keeps.
    static let momentum: CGFloat = 0.5

    @GestureState(resetTransaction: Transaction(animation: TonightForecast.glide)) private var drag: CGFloat = 0
    /// Every note the legend can show, worked out once per strip rather than on every frame
    /// of a swipe.
    @State private var notes: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let settled = strip.readout(hoursFromNow: hoursAhead)
        let live = strip.readout(hoursFromNow: clamped(hoursAhead - Double(drag / Self.pitch)))
        let settledFocus = strip.focus(at: settled) ?? 0
        let focus = strip.focus(at: live) ?? 0
        // The finger's travel, held at the strip's ends.
        let travel = CGFloat(hoursAhead - clamped(hoursAhead - Double(drag / Self.pitch))) * Self.pitch
        let shift = travel + CGFloat(focus - settledFocus) * Self.pitch
        VStack(spacing: 0) {
            HourTimeline(time: strip.timeStamp(live), slots: slots, focus: focus, shift: shift)
                .gesture(swipe, isEnabled: strip.canSwipe)
            Group {
                if let legend = strip.legend(at: live) {
                    legendView(legend)
                } else {
                    ActivityIndicator()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, Self.legendGap)
            .padding(.horizontal, Space.screenMargin)
        }
        .animation(Self.glide, value: focus)
        .sensoryFeedback(.selection, trigger: focus)
        .onChange(of: strip, initial: true) { notes = strip.allNotes }
        .accessibilityElement()
        .accessibilityLabel("Tonight’s forecast")
        .accessibilityValue(strip.spokenTime(live) + ". "
            + (strip.legend(at: live).map { "\($0.title). \($0.note)" } ?? "Checking the sky."))
        .modifier(HourSteps(enabled: strip.canSwipe, step: { settle(hoursAhead + $0) }))
    }

    /// The hours as slots: past hours dimmed, every mark empty and breathing while loading.
    private var slots: [HourTimeline.Slot] {
        let loading = strip.mode == .loading
        return strip.hours.map { hour in
            HourTimeline.Slot(id: hour.id, label: hour.label, sky: loading ? .loading : hour.sky,
                              aurora: !loading && hour.aurora, isPast: !loading && hour.end <= strip.now)
        }
    }

    /// The legend sits 30 pt under the strip at the height of its text. The space below it keeps
    /// the height of the longest note, so the Body doesn't move while swiping.
    private func legendView(_ legend: TonightStrip.Legend) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(notes.isEmpty ? strip.allNotes : notes, id: \.self) { note in
                HourLegend(sky: legend.sky, title: legend.title, note: note).hidden()
            }
            HourLegend(sky: legend.sky, aurora: legend.aurora, title: legend.title, note: legend.note)
        }
    }

    // MARK: Swipe

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, state, _ in state = value.translation.width }
            .onEnded { value in
                let flick = reduceMotion ? 0 : (value.predictedEndTranslation.width - value.translation.width) * Self.momentum
                settle(hoursAhead - Double((value.translation.width + flick) / Self.pitch))
            }
    }

    /// Settle on the step the readout shows, so the glide ends where the readout says.
    private func settle(_ hours: Double) {
        let time = strip.readout(hoursFromNow: clamped(hours))
        withAnimation(Self.glide) { hoursAhead = clamped(time.timeIntervalSince(strip.now) / 3600) }
    }

    private func clamped(_ hours: Double) -> Double {
        min(max(0, hours), max(0, strip.latest.timeIntervalSince(strip.now) / 3600))
    }
}
