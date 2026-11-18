import SwiftUI

/// Motion shared by the screens: one spring family, and a staggered rise-in for content that
/// appears. Reduce Motion keeps only the fades.
enum ZorjaMotion {
    /// Selection, swipes and presses: quick, with a little bounce.
    static let snap = Animation.spring(duration: 0.4, bounce: 0.2)
    /// Content arriving on screen.
    static let rise = Animation.spring(duration: 0.7, bounce: 0.12)
    /// A tab's content handing over to the next one.
    static let tabChange = Animation.easeOut(duration: 0.22)
    /// Delay between the steps of a staggered rise-in.
    static let stagger: Double = 0.07
    /// How far content rises while it fades in.
    static let riseDistance: CGFloat = 18
}

/// Content that fades in and rises into place when it appears, `order` steps after the first.
private struct RiseIn: ViewModifier {
    let order: Int
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : ZorjaMotion.riseDistance)
            .blur(radius: isShown || reduceMotion ? 0 : 6)
            .onAppear {
                guard !isShown else { return }
                let animation = reduceMotion ? Animation.easeOut(duration: 0.25) : ZorjaMotion.rise
                withAnimation(animation.delay(Double(order) * ZorjaMotion.stagger)) { isShown = true }
            }
    }
}

extension View {
    /// Fades in and rises into place when it appears, `order` stagger steps after the first.
    func riseIn(_ order: Int = 0) -> some View {
        modifier(RiseIn(order: order))
    }
}

/// Buttons sink a little while pressed and spring back.
struct PressScale: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .animation(ZorjaMotion.snap, value: isPressed)
    }
}

// MARK: Covers

extension EnvironmentValues {
    /// Shared by the shell's full-screen covers (Places, About, Tips) and the buttons that open
    /// them, so each cover zooms out of its button and back into it.
    @Entry var coverTransition: Namespace.ID?
}

/// Marks the button a cover zooms out of. Without a shell (previews, first launch) it does nothing.
private struct CoverSource: ViewModifier {
    let id: String
    let cornerRadius: CGFloat
    @Environment(\.coverTransition) private var namespace
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        if let namespace {
            // The corner is held to half the source's height: a 999 pt corner (a pill) on a smaller
            // rect clips the whole source away, which hid Tonight's tips card.
            let radius = min(cornerRadius, height / 2)
            content
                .onGeometryChange(for: CGFloat.self, of: { min($0.size.height, $0.size.width) }) { height = $0 }
                .matchedTransitionSource(id: id, in: namespace) { $0.clipShape(.rect(cornerRadius: radius)) }
        } else {
            content
        }
    }
}

extension View {
    /// The button the cover `id` zooms out of, rounded by `cornerRadius` while it does.
    func coverSource(_ id: String, cornerRadius: CGFloat = 0) -> some View {
        modifier(CoverSource(id: id, cornerRadius: cornerRadius))
    }
}
