import SwiftUI

/// The semantic colours of the Figma `Color` collection (Foundations → Colour), dark mode only.
/// Raw values are the Figma variable names. Use the `ShapeStyle` shortcuts below in views,
/// for example `.foregroundStyle(.textSecondary)`.
enum ZorjaColor: String, CaseIterable, Sendable {
    /// Screen background behind the sky.
    case bgBase = "bg/base"
    /// Cards: guidance, calendar, tip cards.
    case surfaceCard = "surface/card"
    /// Floating menu, search field, map buttons.
    case surfaceControl = "surface/control"
    /// The sticky top of Tonight and 3 Nights: the system's hard scroll edge effect over
    /// `bg/base`, as measured on the phone.
    case surfaceTop = "surface/top"
    /// Row dividers and list separators.
    case lineHairline = "line/hairline"
    /// Outline pill buttons and number circles.
    case lineOutline = "line/outline"
    /// Headlines and main text.
    case textPrimary = "text/primary"
    /// Supporting text, times, unselected items.
    case textSecondary = "text/secondary"
    /// Hints, axis labels, quiet notes.
    case textTertiary = "text/tertiary"
    /// Icons on dark.
    case iconPrimary = "icon/primary"
    /// Chevrons, unselected menu icons.
    case iconSecondary = "icon/secondary"
    /// Selected menu item.
    case controlSelected = "control/selected"
    /// Text and icon on a selected control.
    case controlOnSelected = "control/on-selected"
    /// The one standout action on a screen, and the eye timer's ring.
    case actionPrimary = "action/primary"
    /// Text and icon on an action.
    case actionOnPrimary = "action/on-primary"
    /// Quieter actions next to the content: More Tips, See 3 Nights.
    case actionSecondary = "action/secondary"
    /// Text and icon on a secondary action.
    case actionOnSecondary = "action/on-secondary"
    /// Clear hours and the good window; the Best tag.
    case dataClearSky = "data/clear-sky"
    /// Aurora, including the Now icon when the verdict is Go.
    case dataAurora = "data/aurora"
    /// Not known yet (drawn as a dashed outline).
    case dataUnknown = "data/unknown"
    /// The Tonight arc's track, and the Dark Sky key.
    case dataTrack = "data/track"
    /// The Offline tag and the Remove action only.
    case statusOffline = "status/offline"

    /// sRGB value as 0xRRGGBB.
    var hex: UInt32 {
        switch self {
        case .bgBase: 0x05070D
        case .surfaceCard, .dataTrack: 0x202020
        case .surfaceControl: 0x151515
        case .surfaceTop: 0x0C0E15
        case .lineHairline: 0x2A2A2A
        case .lineOutline, .textPrimary, .iconPrimary, .controlSelected, .actionOnSecondary: 0xFFFFFF
        case .textSecondary, .iconSecondary, .dataUnknown: 0x9E9E9E
        case .textTertiary: 0x7A8698
        case .controlOnSelected, .actionOnPrimary: 0x000000
        case .actionPrimary: 0x0AFF74
        case .actionSecondary: 0x434343
        case .dataClearSky: 0xFFD60A
        case .dataAurora: 0xE742FD
        case .statusOffline: 0xFF5F5F
        }
    }

    var opacity: Double {
        self == .lineOutline ? 0.4 : 1
    }

    var color: Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension ShapeStyle where Self == Color {
    static var bgBase: Color { ZorjaColor.bgBase.color }
    static var surfaceCard: Color { ZorjaColor.surfaceCard.color }
    static var surfaceControl: Color { ZorjaColor.surfaceControl.color }
    static var surfaceTop: Color { ZorjaColor.surfaceTop.color }
    static var lineHairline: Color { ZorjaColor.lineHairline.color }
    static var lineOutline: Color { ZorjaColor.lineOutline.color }
    static var textPrimary: Color { ZorjaColor.textPrimary.color }
    static var textSecondary: Color { ZorjaColor.textSecondary.color }
    static var textTertiary: Color { ZorjaColor.textTertiary.color }
    static var iconPrimary: Color { ZorjaColor.iconPrimary.color }
    static var iconSecondary: Color { ZorjaColor.iconSecondary.color }
    static var controlSelected: Color { ZorjaColor.controlSelected.color }
    static var controlOnSelected: Color { ZorjaColor.controlOnSelected.color }
    static var actionPrimary: Color { ZorjaColor.actionPrimary.color }
    static var actionOnPrimary: Color { ZorjaColor.actionOnPrimary.color }
    static var actionSecondary: Color { ZorjaColor.actionSecondary.color }
    static var actionOnSecondary: Color { ZorjaColor.actionOnSecondary.color }
    static var dataClearSky: Color { ZorjaColor.dataClearSky.color }
    static var dataAurora: Color { ZorjaColor.dataAurora.color }
    static var dataUnknown: Color { ZorjaColor.dataUnknown.color }
    static var dataTrack: Color { ZorjaColor.dataTrack.color }
    static var statusOffline: Color { ZorjaColor.statusOffline.color }
}
