import CoreText
import SwiftUI

/// The bundled Outfit font (SIL Open Font License, see `Resources/Fonts/OFL.txt`).
/// Only the three weights the design uses are bundled.
enum OutfitFont: String, CaseIterable, Sendable {
    case regular = "Outfit-Regular"
    case medium = "Outfit-Medium"
    case semiBold = "Outfit-SemiBold"

    /// PostScript name, which is also the file name in the bundle.
    var name: String { rawValue }

    /// Registers the fonts for this process. Safe to call more than once.
    /// Registering at runtime avoids an Info.plist file next to the generated one.
    static func register() {
        _ = registration
    }

    /// Fonts that could not be registered; empty when all loaded.
    static var failures: [OutfitFont] { registration }

    private static let registration: [OutfitFont] = allCases.filter { font in
        guard let url = Bundle.main.url(forResource: font.name, withExtension: "ttf") else { return true }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return false }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        return code != CTFontManagerError.alreadyRegistered.rawValue
    }
}

/// The icons from the Figma Icons section (24 pt grid, 1.75 stroke). They are template
/// images, so they take the colour of the surrounding `foregroundStyle`.
enum ZorjaIcon: String, CaseIterable, Sendable {
    case now
    case nowBold = "now-bold"
    case tonight
    case tonightFilled = "tonight-filled"
    case threeNights = "3-nights"
    case threeNightsFilled = "3-nights-filled"
    case about
    case close
    case search
    case location
    case locationOff = "location-off"
    case pin
    case pinOff = "pin-off"
    case accountOff = "account-off"
    case calendarAdd = "calendar-add"
    case check
    case chevron
    case phone
    case camera

    /// Asset catalog name, matching the Figma component name `Icon/<name>`.
    var assetName: String { "Icon/\(rawValue)" }

    var image: Image { Image(assetName) }

    /// Icons drawn from outlines (the crossed-out ones) have no stroke to keep, so they
    /// have no 16 and 20 pt variants.
    var hasSizedVariants: Bool { ![.locationOff, .pinOff, .accountOff].contains(self) }

    /// The icon at a size, with the 1.75 stroke Figma keeps when it shrinks an icon to 16
    /// or 20 pt (tools/make_icon_sizes.py). Other sizes scale the 24 pt icon.
    func image(size: CGFloat) -> Image {
        hasVariant(at: size) ? Image("\(assetName)-\(Int(size))") : image
    }

    private func hasVariant(at size: CGFloat) -> Bool {
        hasSizedVariants && (size == IconSize.small || size == IconSize.button)
    }

    /// How far the glyph's ink sits inside a frame of `size`. Sized variants keep the 1.75
    /// stroke, so only the path's geometry scales.
    func glyphInsets(size: CGFloat) -> EdgeInsets {
        let i = glyphInsets24
        let halfStroke: CGFloat = hasVariant(at: size) ? 0.875 : 0
        func scaled(_ inset: CGFloat) -> CGFloat {
            (inset + halfStroke) * size / IconSize.regular - halfStroke
        }
        return EdgeInsets(top: scaled(i.top), leading: scaled(i.leading), bottom: scaled(i.bottom), trailing: scaled(i.trailing))
    }

    /// The icon in a square frame of `size`.
    func sized(_ size: CGFloat) -> some View {
        image(size: size).resizable().frame(width: size, height: size)
    }
}
