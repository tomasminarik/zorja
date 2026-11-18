import SwiftUI

/// Side by side at the usual text sizes, one above the other at the accessibility text sizes,
/// where two columns leave too little width for words (Apple's pattern for Dynamic Type).
struct AdaptiveStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}

extension AnyTransition {
    /// A screen pushed in from the trailing edge, or faded in with Reduce Motion on, as the
    /// system navigation push does.
    static func screenPush(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing)
    }
}
