import SwiftUI

/// Card with a heading and a short explanation (Figma: Info card).
struct InfoCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            Text(title).textStyle(.titleS).foregroundStyle(.textPrimary)
            Text(message).textStyle(.bodyM).foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s20)
        .padding(.vertical, Space.s16)
        .zorjaCard()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The card background: `surface/card` with `radius/card` corners.
    func zorjaCard() -> some View {
        background(.surfaceCard, in: .rect(cornerRadius: Radius.card))
    }
}

/// A short message with one action on a glass pill (Figma: Action card): the Secondary button
/// for More Tips and See 3 Nights. At the accessibility text sizes the button goes under the
/// message and the pill becomes a rounded card.
struct ActionCard: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveStack(spacing: Space.s16) {
            Text(message)
                .textStyle(.titleS)
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZorjaButton(buttonTitle, style: .secondary, action: action)
        }
        .padding(.leading, Space.s24)
        .padding(.trailing, Space.s16)
        .padding(.vertical, Space.s16)
        .zorjaGlass(in: .rect(cornerRadius: dynamicTypeSize.isAccessibilitySize ? Radius.card : Radius.full),
                    interactive: false)
    }
}

/// Half-width tip card (Figma: Tip card).
struct TipCard: View {
    let icon: ZorjaIcon
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            icon.sized(IconSize.regular)
                .foregroundStyle(.iconPrimary)
                .accessibilityHidden(true)
            Text(title).textStyle(.titleM).foregroundStyle(.textPrimary)
            Text(message).textStyle(.bodyM).foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Space.s20)
        .zorjaCard()
        .accessibilityElement(children: .combine)
    }
}

/// A saved place: names only, tap to switch (Figma: Place row). 61 pt with its hairline.
/// Swipe to remove and drag to reorder are added by the Places list, which also draws the
/// lifted row without a hairline.
struct PlaceRow: View {
    let name: String
    let countryCode: String
    let isSelected: Bool
    var showsHairline = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                PlaceRowContent(name: name, countryCode: countryCode, isSelected: isSelected)
                    .padding(.vertical, Space.s16)
                if showsHairline { Hairline() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Name, country badge and the check of the selected place.
struct PlaceRowContent: View {
    let name: String
    let countryCode: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.s8) {
            Text(name)
                .textStyle(.titleL)
                .foregroundStyle(isSelected ? Color.textPrimary : .textSecondary)
                .lineLimit(1)
            if !countryCode.isEmpty { CountryBadge(code: countryCode) }
            Spacer(minLength: Space.s8)
            if isSelected {
                ZorjaIcon.check.sized(IconSize.button)
                    .foregroundStyle(.iconPrimary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Opens short content in place; the parent keeps one open at a time (Figma: Accordion row).
struct AccordionRow<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack {
                    Text(title).textStyle(.titleM).foregroundStyle(.textPrimary)
                    Spacer(minLength: Space.s8)
                    Chevron(direction: isOpen ? .up : .down, size: IconSize.button)
                }
                .padding(.vertical, Space.s16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Open" : "Closed")
            if isOpen {
                content()
                    .padding(.bottom, Space.s16)
            }
        }
        // Figma's 1 pt top border adds to the row's height (57 pt closed).
        .padding(.top, 1)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// A tick box with a label, kept on this phone only (Figma: Checklist item).
struct ChecklistItem: View {
    let label: String
    @Binding var isChecked: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts checks, to send one ring out of the circle each time.
    @State private var ripples = 0

    var body: some View {
        Button {
            if !isChecked { ripples += 1 }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.45)) {
                isChecked.toggle()
            }
        } label: {
            HStack(spacing: Space.s12) {
                ZStack {
                    Circle().strokeBorder(.textTertiary, lineWidth: 1.75)
                        .opacity(isChecked ? 0 : 1)
                    if isChecked {
                        // The fill pops out of the centre and the tick turns in after it.
                        Circle().fill(.controlSelected)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                        ZorjaIcon.check.sized(IconSize.small)
                            .foregroundStyle(.controlOnSelected)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .scale(scale: 0.3).combined(with: .opacity)
                                    .animation(.spring(duration: 0.4, bounce: 0.5).delay(0.08)),
                                removal: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
                .background { CheckRipple(trigger: ripples) }
                .accessibilityHidden(true)
                Text(label)
                    .textStyle(.bodyL)
                    .foregroundStyle(isChecked ? Color.textSecondary : .textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: ripples)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// A ring that grows out of a checked circle and fades. Reduce Motion leaves it out.
private struct CheckRipple: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            Circle()
                .stroke(.controlSelected, lineWidth: 2)
                .keyframeAnimator(initialValue: Wave(), trigger: trigger) { ring, wave in
                    ring.scaleEffect(wave.scale).opacity(wave.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(1)
                        CubicKeyframe(2.4, duration: 0.55)
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0.8)
                        CubicKeyframe(0, duration: 0.55)
                    }
                }
                .allowsHitTesting(false)
        }
    }

    private struct Wave {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }
}

/// Explains one of the three inputs, with its data colour (Figma: Key row).
struct KeyRow: View {
    enum Kind: Sendable {
        case darkSky, clearSky, aurora

        var title: String {
            switch self {
            case .darkSky: "Dark Sky"
            case .clearSky: "Clear Sky"
            case .aurora: "Aurora"
            }
        }

        var color: Color {
            switch self {
            case .darkSky: .dataTrack
            case .clearSky: .dataClearSky
            case .aurora: .dataAurora
            }
        }
    }

    let kind: Kind
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s12) {
            // A 10 pt dot centred on the first line of the 22 pt title.
            Circle()
                .fill(kind.color)
                .frame(width: 10, height: 10)
                .frame(height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(kind.title).textStyle(.titleS).foregroundStyle(.textPrimary)
                Text(message).textStyle(.bodyM).foregroundStyle(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One place or address suggestion from MapKit search (Figma: Search result row). Figma fixes
/// the row at 60 pt with the text 12 pt from the top, so the hairline sits 6 pt below the detail.
/// At larger text sizes the row grows.
struct SearchResultRow: View {
    let name: String
    let detail: String
    var showsHairline = true
    let action: () -> Void

    static let height: CGFloat = 60

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(name).textStyle(.titleS).foregroundStyle(.textPrimary).lineLimit(2)
                if !detail.isEmpty {
                    Text(detail).textStyle(.bodyS).foregroundStyle(.textSecondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Space.s12)
            .padding(.bottom, Space.s4)
            .frame(minHeight: Self.height - 1, alignment: .top)
            // The hairline is the row's last point, inside its 60 pt.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsHairline { Hairline() } else { Color.clear.frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// 1 pt divider in line/hairline.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.lineHairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
