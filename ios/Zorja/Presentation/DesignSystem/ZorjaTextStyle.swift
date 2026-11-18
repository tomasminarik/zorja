import SwiftUI
import UIKit

/// The Figma text styles (Foundations → Type), all in Outfit. Size, line height and
/// letter spacing match Figma at the default text size and scale together with Dynamic Type.
/// Apply with `.textStyle(.titleL)`.
enum ZorjaTextStyle: String, CaseIterable, Sendable {
    case displayXL = "Display/XL"
    case displayL = "Display/L"
    case titleL = "Title/L"
    case titleM = "Title/M"
    case titleS = "Title/S"
    case lead = "Lead"
    case bodyL = "Body/L"
    case bodyM = "Body/M"
    case bodyS = "Body/S"
    case bodyXS = "Body/XS"
    case labelM = "Label/M"
    case labelS = "Label/S"
    case tag = "Tag"

    var font: OutfitFont {
        switch self {
        case .displayXL, .displayL, .titleL, .titleM, .titleS, .tag: .semiBold
        case .lead, .bodyL, .bodyM, .bodyS, .bodyXS: .regular
        case .labelM, .labelS: .medium
        }
    }

    /// Font size in points at the default text size.
    var size: CGFloat {
        switch self {
        case .displayXL: 60
        case .displayL: 44
        case .titleL: 24
        case .titleM: 20
        case .titleS, .lead: 18
        case .bodyL: 16
        case .bodyM, .labelM: 15
        case .bodyS: 13
        case .labelS: 12
        case .tag, .bodyXS: 11
        }
    }

    /// Line height in points at the default text size.
    var lineHeight: CGFloat {
        switch self {
        case .displayXL: 60
        case .displayL: 48
        case .titleL: 28
        case .titleM, .lead: 24
        case .titleS, .bodyL: 22
        case .bodyM, .labelM: 20
        case .bodyS: 18
        case .labelS, .tag, .bodyXS: 14
        }
    }

    /// Letter spacing as a percentage of the font size, as Figma states it.
    var trackingPercent: CGFloat {
        switch self {
        case .displayXL, .displayL: -4
        case .titleL: -3
        case .titleM: -2
        case .titleS: -1
        case .labelS: 1
        case .lead, .bodyL, .bodyM, .bodyS, .bodyXS, .labelM, .tag: 0
        }
    }

    /// The system style whose Dynamic Type curve this style follows.
    var scalesLike: UIFont.TextStyle {
        switch self {
        case .displayXL, .displayL: .largeTitle
        case .titleL: .title1
        case .titleM: .title2
        case .titleS, .lead: .title3
        case .bodyL, .bodyM: .body
        case .labelM: .callout
        case .bodyS: .footnote
        case .labelS: .caption1
        case .tag, .bodyXS: .caption2
        }
    }

    /// Size, line height and tracking for a Dynamic Type size, scaled by the same factor.
    /// `size` replaces the font size and keeps the line height, as on the small iPhone frames
    /// (Display/L at 40 on 48). `scale` then shrinks all three together, for a headline whose
    /// longest word would not fit the width at very large text sizes.
    func metrics(for dynamicTypeSize: DynamicTypeSize, size override: CGFloat? = nil, scale: CGFloat = 1) -> Metrics {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let base = override ?? size
        let scaled = UIFontMetrics(forTextStyle: scalesLike).scaledValue(for: base, compatibleWith: traits)
        let factor = scaled / base
        return Metrics(
            size: scaled * scale,
            lineHeight: lineHeight * factor * scale,
            tracking: scaled * scale * trackingPercent / 100
        )
    }

    /// The UIKit font for measuring text in this style.
    func uiFont(_ metrics: Metrics) -> UIFont {
        UIFont(name: font.name, size: metrics.size) ?? .systemFont(ofSize: metrics.size)
    }

    struct Metrics: Equatable, Sendable {
        var size: CGFloat
        var lineHeight: CGFloat
        var tracking: CGFloat
    }
}

private struct ZorjaTextStyleModifier: ViewModifier {
    let style: ZorjaTextStyle
    var size: CGFloat?
    var scale: CGFloat = 1
    var capCentered = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let metrics = style.metrics(for: dynamicTypeSize, size: size, scale: scale)
        content
            .font(.custom(style.font.name, fixedSize: metrics.size))
            .tracking(metrics.tracking)
            .lineHeight(.exact(points: metrics.lineHeight))
            // An exact line height clips glyphs to the line box on screen, cutting the
            // descenders of Display/XL (60 on 60). Drawing through a renderer with padding
            // lets them reach past it, as they do in Figma. The renderer also centres each
            // line in its line box, as Figma does.
            .textRenderer(OverflowTextRenderer(overflow: metrics.size * 0.4, lineBox: .init(style: style, metrics: metrics, capCentered: capCentered)))
    }
}

/// Draws each line centred in its line box, as Figma does, and may draw `overflow` points
/// above and below its frame.
///
/// With an exact line height smaller than the font's own (Display/XL is 60 on 60, Outfit's
/// ascent and descent add up to about 76), SwiftUI takes the whole difference from below the
/// line, so the glyphs sat about 8 pt lower than in Figma. Figma splits it above and below.
struct OverflowTextRenderer: TextRenderer {
    let overflow: CGFloat
    var lineBox: LineBox?

    /// The line height and the font's own ascent and descent. (A line's `typographicBounds`
    /// already report the exact line height, so they can't tell where Figma's baseline is.)
    struct LineBox: Equatable {
        var height: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var capHeight: CGFloat = 0
        /// Centre the capitals in the line box instead of the whole font.
        var capCentered = false

        init(style: ZorjaTextStyle, metrics: ZorjaTextStyle.Metrics, capCentered: Bool = false) {
            let font = style.uiFont(metrics)
            height = metrics.lineHeight
            ascent = font.ascender
            descent = -font.descender
            capHeight = font.capHeight
            self.capCentered = capCentered
        }

        /// Baseline of a line, from the top of its line box. Figma centres the font (ascent
        /// plus descent) in the line box. Outfit's ascent leaves more room above its capitals
        /// than its descent leaves below, so the capitals then sit 0.2–0.3 pt low: right for
        /// running text, visibly off-centre in a pill. Labels in pills centre the capitals.
        var baseline: CGFloat {
            capCentered ? (height + capHeight) / 2 : (height - ascent - descent) / 2 + ascent
        }
    }

    var displayPadding: EdgeInsets { EdgeInsets(top: overflow, leading: 0, bottom: overflow, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Where the text's frame starts in the layout's space: 0 on iOS 26, but iOS 27 starts
        // the first line lower (3 pt for Label/M), which drew every line that much too high.
        let top = layout.first?.typographicBounds.rect.minY ?? 0
        for (index, line) in layout.enumerated() {
            guard let lineBox else {
                context.draw(line)
                continue
            }
            let baseline = top + CGFloat(index) * lineBox.height + lineBox.baseline
            var lineContext = context
            lineContext.translateBy(x: 0, y: baseline - line.typographicBounds.origin.y)
            lineContext.draw(line)
        }
    }
}

extension View {
    /// Applies a Figma text style: Outfit weight, size, line height and letter spacing.
    /// `size` replaces the font size at the default text size and keeps the line height.
    /// `capCentered` centres the capitals in the line box, for one-line labels inside
    /// buttons, tags and chips. `scale` shrinks size, line height and tracking together.
    func textStyle(_ style: ZorjaTextStyle, size: CGFloat? = nil, scale: CGFloat = 1, capCentered: Bool = false) -> some View {
        modifier(ZorjaTextStyleModifier(style: style, size: size, scale: scale, capCentered: capCentered))
    }
}
