import CoreGraphics

/// Spacing from the Figma `Layout` collection (Foundations → Spacing and radius).
/// Stacks use 4, 8, 12, 16, 24 and 32; cards pad 20 by 16.
enum Space {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s48: CGFloat = 48

    /// Left and right screen margin.
    static let screenMargin: CGFloat = 24
}

/// Corner radii from the Figma `Layout` collection.
enum Radius {
    /// Square corners.
    static let none: CGFloat = 0
    /// Cards: Night, Tip and Info cards, the Timer and Before You Go cards, the privacy card.
    static let card: CGFloat = 16
    /// Pills: buttons, menu, search, tags. In SwiftUI prefer `Capsule()`.
    static let full: CGFloat = 999
}

/// Icon sizes: a 24 pt grid with a 1.75 stroke; inside buttons icons shrink to 16 or 20.
enum IconSize {
    static let regular: CGFloat = 24
    static let button: CGFloat = 20
    static let small: CGFloat = 16

}

/// The Tonight strip of hour circles, from the `hour/*` variables in the Figma `Layout` collection.
enum ZorjaHour {
    /// An Hour mark in the strip (Regular).
    static let size: CGFloat = 58
    /// The selected hour's mark (Focus).
    static let focus: CGFloat = 88
    /// The Hour mark in the legend.
    static let legend: CGFloat = 48
    /// Between Hour slots.
    static let gap: CGFloat = 8
}

