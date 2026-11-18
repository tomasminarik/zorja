import SwiftUI

/// Top bar (Figma: Header). Location: Now, Tonight and 3 Nights, with the location chip on the
/// left and About on the right. Close: sheets. Back: a screen pushed inside a sheet or menu item.
struct ZorjaHeader: View {
    enum Kind {
        /// `place` is nil when there is none (Now · No place): only About shows.
        case location(place: String?, openPlaces: () -> Void, openAbout: () -> Void)
        case close(() -> Void)
        case back(() -> Void)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 0) {
            switch kind {
            case let .location(place, openPlaces, openAbout):
                if let place { LocationChip(place: place, action: openPlaces) }
                Spacer(minLength: Space.s16)
                // A glass circle, the same height as the location chip.
                Button(action: openAbout) {
                    ZorjaIcon.about.sized(IconSize.regular)
                        .foregroundStyle(.iconPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .zorjaGlass(in: .circle)
                .coverSource("about", cornerRadius: 22)
                .accessibilityLabel("About")
            case let .close(close):
                Spacer(minLength: 0)
                GlassCircleButton(label: "Close", action: close) {
                    ZorjaIcon.close.sized(IconSize.regular).foregroundStyle(.iconPrimary)
                }
            case let .back(back):
                GlassCircleButton(label: "Back", action: back) {
                    Chevron(direction: .left, size: IconSize.regular)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Space.screenMargin)
        .frame(height: 44)
    }
}

/// A 44 pt glass circle with only its icon: Close and Back, like the system's in iOS 26.
private struct GlassCircleButton<Icon: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            icon
                .accessibilityHidden(true)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .zorjaGlass(in: .circle)
        .accessibilityLabel(label)
    }
}

/// The three items of the floating menu.
enum MenuTab: String, CaseIterable, Identifiable, Sendable {
    case now, tonight, threeNights

    var id: Self { self }

    var title: String {
        switch self {
        case .now: "Now"
        case .tonight: "Tonight"
        case .threeNights: "3 Nights"
        }
    }

    func icon(selected: Bool) -> ZorjaIcon {
        switch self {
        case .now: selected ? .nowBold : .now
        case .tonight: selected ? .tonightFilled : .tonight
        case .threeNights: selected ? .threeNightsFilled : .threeNights
        }
    }
}

/// Bottom menu on Now, Tonight and 3 Nights (Figma: Floating menu), on Liquid Glass with a
/// solid pill for the selected item. `auroraActive` turns the
/// Now icon magenta when the verdict is Go; it only shows while another item is selected.
struct FloatingMenu: View {
    @Binding var selection: MenuTab
    var auroraActive = false

    /// The selected pill slides between items.
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.s4) {
            ForEach(MenuTab.allCases) { tab in
                MenuItem(
                    tab: tab,
                    isSelected: tab == selection,
                    showsAurora: tab == .now && auroraActive && selection != .now,
                    pill: pill
                ) {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : ZorjaMotion.snap) { selection = tab }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .padding(Space.s4)
        .zorjaGlass(in: .capsule)
        // Like the system tab bar, the menu stops growing at the largest standard text size;
        // at the accessibility sizes a long press shows the item large (Large Content Viewer).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// One item of the floating menu (Figma: Menu item).
struct MenuItem: View {
    let tab: MenuTab
    let isSelected: Bool
    var showsAurora = false
    /// Shared by the items of one menu, so the selected pill slides from item to item.
    var pill: Namespace.ID?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s4) {
                icon
                Text(tab.title)
                    .textStyle(.labelS)
                    .foregroundStyle(isSelected ? Color.controlOnSelected : .textSecondary)
            }
            .frame(width: 112, height: 60)
            .background { selectedPill }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer {
            tab.icon(selected: isSelected).image
            Text(tab.title)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(showsAurora ? "Aurora active" : "")
    }

    @ViewBuilder private var selectedPill: some View {
        if isSelected {
            let capsule = Capsule().fill(Color.controlSelected)
            if let pill {
                capsule.matchedGeometryEffect(id: "selected", in: pill)
            } else {
                capsule
            }
        }
    }

    @ViewBuilder private var icon: some View {
        let image = tab.icon(selected: isSelected).image
            .resizable()
            .frame(width: IconSize.regular, height: IconSize.regular)
            .accessibilityHidden(true)
        if showsAurora {
            // A slow glow. Reduce Motion keeps only the colour.
            image
                .foregroundStyle(.dataAurora)
                .phaseAnimator([1.0, 0.55]) { view, phase in
                    view.opacity(reduceMotion ? 1 : phase)
                } animation: { _ in
                    reduceMotion ? nil : .easeInOut(duration: 1.6)
                }
        } else {
            image.foregroundStyle(isSelected ? Color.controlOnSelected : .iconSecondary)
        }
    }
}

// MARK: Glass

/// Zorja's Liquid Glass: the system's regular glass, which blurs what passes under it, with a
/// dark tint that takes the edge off its frost and keeps yellow content under the menu quiet.
/// The menu, the location chip, About, Close, Back and the Action card use it.
enum ZorjaGlass {
    /// How dark the tint is. Raise it if content under the menu shows too much or the glass
    /// looks too frosted; lower it if the glass looks flat.
    static let tintOpacity: Double = 0.35

    static var style: Glass { style(interactive: true) }

    /// Controls react to a touch; a card that only holds a button does not.
    static func style(interactive: Bool) -> Glass {
        let glass = Glass.regular.tint(Color.bgBase.opacity(tintOpacity))
        return interactive ? glass.interactive() : glass
    }
}

extension View {
    func zorjaGlass(in shape: some Shape, interactive: Bool = true) -> some View {
        glassEffect(ZorjaGlass.style(interactive: interactive), in: shape)
    }
}

// MARK: Scrolling under the menu

extension EnvironmentValues {
    /// The floating menu and the space under it, set by the shell. Screens scroll under it.
    @Entry var menuSpace: CGFloat = 0
}

/// A screen's scroll view runs under the floating menu: room at the bottom so its last item
/// scrolls clear of the menu, and the system's soft scroll edge effect under the glass.
private struct ScrollsUnderMenu: ViewModifier {
    @Environment(\.menuSpace) private var menuSpace

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: menuSpace)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

extension View {
    /// Put on a scroll view inside the shell; see `ScrollsUnderMenu`.
    func scrollsUnderMenu() -> some View {
        modifier(ScrollsUnderMenu())
    }
}

// MARK: Scrolling under the header

extension EnvironmentValues {
    /// The header and the status bar above it, set by the shell for screens that scroll under it.
    @Entry var headerSpace: CGFloat = 0
}

/// A screen's scroll view runs under the header to the top of the screen. `pinned` stays put
/// under the header while the content scrolls under both, and the system's hard scroll edge
/// effect dims and blurs the content there, all the way to the top.
private struct ScrollsUnderHeader<Pinned: View>: ViewModifier {
    let pinned: Pinned
    /// Fills the bar from the top of the screen to under `pinned` (Tonight: `surface/top`).
    var background: Color?
    @Environment(\.headerSpace) private var headerSpace

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // Not clear: the system skips the edge effect when its bar shows nothing
                    // (Tonight pins nothing). At 1 % it is invisible.
                    Color.bgBase.opacity(0.01).frame(height: headerSpace)
                    pinned
                }
                .background(background ?? .clear)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

extension View {
    /// Put on a scroll view inside the shell; see `ScrollsUnderHeader`.
    func scrollsUnderHeader(background: Color? = nil, @ViewBuilder pinned: () -> some View = { EmptyView() }) -> some View {
        modifier(ScrollsUnderHeader(pinned: pinned(), background: background))
    }
}
