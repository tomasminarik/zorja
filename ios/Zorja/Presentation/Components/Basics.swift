import SwiftUI

/// The only arrow in Zorja (Figma: Chevron). Right: rows that open something. Left: Back.
/// Down: location chip and closed accordion. Up: open accordion.
struct Chevron: View {
    enum Direction: Sendable {
        case right, left, down, up

        var angle: Angle {
            switch self {
            case .right: .zero
            case .down: .degrees(90)
            case .left: .degrees(180)
            case .up: .degrees(-90)
            }
        }
    }

    var direction: Direction = .right
    var size: CGFloat = IconSize.regular

    var body: some View {
        ZorjaIcon.chevron.sized(size)
            .rotationEffect(direction.angle)
            .foregroundStyle(.iconSecondary)
            .accessibilityHidden(true)
    }
}

/// Pill button (Figma: Button). Primary is the one standout action on a screen; Outline is for
/// secondary actions next to it; Secondary is a quiet filled action inside content (More Tips,
/// See 3 Nights). Disabled (Primary only in Figma) follows `.disabled(_:)`.
struct ZorjaButton: View {
    enum Style: Sendable { case primary, secondary, outline }
    enum Size: Sendable { case small, large }

    let title: String
    var icon: ZorjaIcon?
    var style: Style = .primary
    var size: Size = .small
    /// Large buttons at the bottom of a screen fill the width.
    var fillsWidth = false
    let action: () -> Void

    init(
        _ title: String,
        icon: ZorjaIcon? = nil,
        style: Style = .primary,
        size: Size = .small,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.size = size
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s8) {
                if let icon {
                    icon.sized(iconSize)
                        .accessibilityHidden(true)
                }
                Text(title).textStyle(.labelM, capCentered: true)
            }
            .offset(x: -opticalShift)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, size == .large ? Space.s24 : Space.s16)
            .padding(.vertical, size == .large ? Space.s12 : Space.s8)
            // Figma counts the Outline stroke in the layout: Outline Small is 86 × 38 where
            // Primary Small is 84 × 36.
            .padding(style == .outline ? 1 : 0)
            .frame(minHeight: size == .large ? 48 : nil)
        }
        .buttonStyle(PillButtonStyle(style: style))
    }

    private var iconSize: CGFloat {
        size == .large ? IconSize.button : IconSize.small
    }

    /// An icon's glyph sits inside its frame, so equal padding leaves more space on the icon's
    /// side than after the label. Shifting the content by half the difference centres it by
    /// eye; the button keeps Figma's size.
    private var opticalShift: CGFloat {
        guard let icon else { return 0 }
        return (icon.glyphInsets(size: iconSize).leading - Optical.labelSideBearing) / 2
    }
}

/// A round Primary button with only an icon (Figma: Night card → Add). The tap area reaches
/// 44 pt around a smaller circle without changing its layout; the label is for VoiceOver.
struct ZorjaIconButton: View {
    let icon: ZorjaIcon
    let label: String
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.sized(IconSize.small)
                .frame(width: size, height: size)
        }
        .buttonStyle(PillButtonStyle(style: .primary))
        .contentShape(.interaction, Circle().inset(by: -max(0, (44 - size) / 2)))
        .accessibilityLabel(label)
    }
}

private enum Optical {
    /// Typical space Outfit leaves beside the first or last letter of a Label/M word
    /// (about 0.06 em), measured on the simulator.
    static let labelSideBearing: CGFloat = 0.9
}

private struct PillButtonStyle: ButtonStyle {
    let style: ZorjaButton.Style
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                if style == .outline {
                    Capsule().strokeBorder(.lineOutline, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .modifier(PressScale(isPressed: configuration.isPressed))
    }

    private var foreground: Color {
        if !isEnabled { return .textTertiary }
        switch style {
        case .primary: return .actionOnPrimary
        case .secondary: return .actionOnSecondary
        case .outline: return .textPrimary
        }
    }

    private var background: Color {
        guard isEnabled else { return style == .outline ? .clear : .surfaceControl }
        switch style {
        case .primary: return .actionPrimary
        case .secondary: return .actionSecondary
        case .outline: return .clear
        }
    }
}

/// Small label (Figma: Tag). Best marks the night to plan for; Skip a night with no clear dark
/// window; Clear sky a clear night no storm reaches (southern places only); Offline shows the
/// phone has no connection.
struct ZorjaTag: View {
    enum Kind: Sendable, CaseIterable {
        case best, skip, clearSky, offline

        var title: String {
            switch self {
            case .best: "Best"
            case .skip: "Skip"
            case .clearSky: "Clear sky"
            case .offline: "Offline"
            }
        }

        var fill: Color {
            switch self {
            case .best: .dataClearSky
            case .skip, .clearSky: .controlSelected
            case .offline: .statusOffline
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.title)
            .textStyle(.tag, capCentered: true)
            .foregroundStyle(.controlOnSelected)
            .padding(.horizontal, Space.s8)
            .padding(.vertical, Space.s2)
            .background(kind.fill, in: Capsule())
    }
}

/// ISO country code after a place name (Figma: Country badge).
struct CountryBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .textStyle(.tag, capCentered: true)
            .foregroundStyle(.textSecondary)
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(.lineOutline, lineWidth: 1))
            .accessibilityLabel(Locale.current.localizedString(forRegionCode: code) ?? code)
    }
}

/// The selected place in the header; opens Places, which zooms out of it (Figma: Location chip).
/// A Liquid Glass pill, 44 pt tall like the About button, Label/M with a 16 pt Chevron down.
struct LocationChip: View {
    let place: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s4) {
                Text(place)
                    .textStyle(.labelM, capCentered: true)
                    .foregroundStyle(.textPrimary)
                    .lineLimit(1)
                Chevron(direction: .down, size: IconSize.small)
            }
            // The chevron's glyph sits well inside its frame; balance the chip by eye.
            .offset(x: (chevronTrailingInset - Optical.labelSideBearing) / 2)
            .padding(.horizontal, Space.s16)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .zorjaGlass(in: .capsule)
        .coverSource("places", cornerRadius: 22)
        .accessibilityHint("Opens your places")
    }

    /// Pointing down, the chevron's top inset faces the trailing edge.
    private var chevronTrailingInset: CGFloat {
        ZorjaIcon.chevron.glyphInsets(size: IconSize.small).top
    }
}

/// Search field for places (Figma: Search field). Shows the placeholder when empty, and a
/// clear button while typing.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding?

    init(placeholder: String, text: Binding<String>, isFocused: FocusState<Bool>.Binding? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.isFocused = isFocused
    }

    var body: some View {
        HStack(spacing: Space.s12) {
            ZorjaIcon.search.sized(IconSize.button)
                .foregroundStyle(.iconSecondary)
                .accessibilityHidden(true)
            TextField(
                placeholder,
                text: $text,
                prompt: Text(placeholder).foregroundStyle(.textSecondary)
            )
            .textStyle(.bodyM)
            .foregroundStyle(.textPrimary)
            .tint(.textPrimary)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .modifier(OptionalFocus(binding: isFocused))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    ZorjaIcon.close.sized(IconSize.button)
                        .foregroundStyle(.iconSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .riseIn(1)
        .padding(.horizontal, Space.s16)
        // Grows with large text instead of clipping it.
        .padding(.vertical, Space.s12)
        .frame(minHeight: 48)
        .background(.surfaceControl, in: Capsule())
    }
}

private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}
