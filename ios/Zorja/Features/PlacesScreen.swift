import SwiftUI

/// Places (Figma: Places, Search while typing). Opened from the header's location chip, closed
/// with Close. Search suggestions replace the actions and the list while typing; offline the
/// saved places stay, under the Offline tag and its message.
struct PlacesScreen: View {
    /// Standard: from the location chip, with Close. First launch: from "Choose A Place
    /// Instead", with Back, its own title and only Pick On Map (Figma: Places · First launch).
    enum Mode {
        case standard
        case firstLaunch(back: () -> Void)
    }

    let places: PlacesModel
    var mode: Mode = .standard
    /// Called when Close is tapped or a place is chosen.
    let close: () -> Void

    @State private var search: PlaceSearchModel
    @State private var showsMap = DeveloperSettings.initialPlacesScreen == "map"
    @State private var isReadingLocation = false
    @State private var isReordering = false
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(places: PlacesModel, mode: Mode = .standard, close: @escaping () -> Void) {
        self.places = places
        self.mode = mode
        self.close = close
        let search = PlaceSearchModel(kind: .towns, service: places.search) { [places] in places.isOffline }
        if DeveloperSettings.initialPlacesScreen != "map", let text = DeveloperSettings.initialSearchText {
            search.text = text
        }
        _search = State(initialValue: search)
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack {
                list(insets: insets)
                    // Covered by the map: VoiceOver must not reach the rows underneath.
                    .accessibilityHidden(showsMap)
                if showsMap {
                    PickOnMapScreen(places: places, back: closeMap, done: close)
                        .transition(.screenPush(reduceMotion: reduceMotion))
                        .zIndex(1)
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .background(Color.bgBase)
        .preferredColorScheme(.dark)
        .onChange(of: places.isOffline, initial: true) { search.refresh() }
        .task {
            // Screenshots open with the text typed and the keyboard up.
            if !search.text.isEmpty { searchFocused = true }
        }
    }

    private func list(insets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            header
                .riseIn(1)
                .padding(.top, ShellLayout.headerTop(safeAreaTop: insets.top))
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s20) {
                    Text(isFirstLaunch ? "Choose A Place." : "Places.")
                        .textStyle(.displayL)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .riseIn(0)
                    SearchField(placeholder: "Search A Town Or Area", text: $search.text, isFocused: $searchFocused)
                    content
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.s16)
                .padding(.bottom, Space.s32)
            }
            .scrollDisabled(isReordering)
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var content: some View {
        switch search.phase {
        case .idle:
            actions
                .riseIn(2)
            PlaceList(store: places.store, select: select, isReordering: $isReordering)
                .riseIn(3)
        case .searching:
            EmptyView()
        case .results(let suggestions):
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    SearchResultRow(name: suggestion.name, detail: suggestion.detail) { choose(suggestion) }
                }
            }
        case .noMatch(let text):
            Text(PlacesCopy.noMatch(text))
                .textStyle(.bodyM)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZorjaButton("Pick On Map", icon: .pin, style: .outline, action: openMap)
        case .offline:
            ZorjaTag(kind: .offline)
            Text(PlacesCopy.searchOffline)
                .textStyle(.bodyM)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlaceList(store: places.store, select: select, isReordering: $isReordering)
        }
    }

    private var isFirstLaunch: Bool {
        if case .firstLaunch = mode { true } else { false }
    }

    private var header: ZorjaHeader {
        switch mode {
        case .standard: ZorjaHeader(kind: .close(close))
        case .firstLaunch(let back): ZorjaHeader(kind: .back(back))
        }
    }

    private var actions: some View {
        AdaptiveStack(verticalAlignment: .top, spacing: Space.s8) {
            if isFirstLaunch {
                // Location is offered on the screen before; here only the map.
            } else if places.location.access == .off {
                ZorjaButton("Turn On Location", icon: .location) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else {
                ZorjaButton("Use My Location", icon: .location, action: useMyLocation)
                    .disabled(isReadingLocation)
            }
            ZorjaButton("Pick On Map", icon: .pin, style: .outline, action: openMap)
        }
    }

    private func select(_ place: SavedPlace) {
        places.store.select(.saved(place.id))
        close()
    }

    private func choose(_ suggestion: PlaceSuggestion) {
        Task {
            guard let candidate = try? await places.search.resolve(suggestion) else {
                search.refresh()
                return
            }
            places.store.add(candidate)
            close()
        }
    }

    private func useMyLocation() {
        isReadingLocation = true
        Task {
            let reading = await places.useMyLocation()
            isReadingLocation = false
            if reading != .off { close() }
        }
    }

    private func openMap() {
        searchFocused = false
        withAnimation(.snappy) { showsMap = true }
    }

    private func closeMap() {
        withAnimation(.snappy) { showsMap = false }
    }
}

/// Words on Places and Pick On Map, from App copy (Location and places).
enum PlacesCopy {
    static func noMatch(_ text: String) -> String {
        "No places match “\(text)”. Try a nearby town, or pick the spot on the map."
    }

    static let searchOffline = "You’re offline, so search can’t look up places. Your saved places still work."
    static let mapOffline = "You’re offline, so the map may not load and search can’t look up places. You can still save this spot."
    static let moveTheMap = "Move the map to place the pin."
    static let pinnedSpot = "Pinned Spot"

    /// "Near Tromsø" for a pinned spot in or by a town.
    static func near(_ town: String) -> String { "Near \(town)" }

    /// No match on Pick On Map, where the map itself is the way out (proposed copy).
    static func noMatchOnMap(_ text: String) -> String { "No places match “\(text)”." }
}

// MARK: - The list

/// Saved places: tap to switch, swipe from the right to remove (red Remove), long-press and
/// drag to reorder. No edit mode (decision of 2026-11-05).
struct PlaceList: View {
    let store: PlaceStore
    let select: (SavedPlace) -> Void
    /// True while a row is lifted; the screen turns scrolling off meanwhile.
    @Binding var isReordering: Bool

    /// Width of the red Remove action (Figma: Swipe to remove).
    static let removeWidth: CGFloat = 88

    struct Drag: Equatable {
        let id: UUID
        let from: Int
        var dy: CGFloat
        var target: Int
    }

    /// The row being swiped and how far (0 closed, -88 open).
    @State private var swipe: (id: UUID, x: CGFloat)?
    @State private var drag: Drag?
    @State private var rowHeight: CGFloat = 61
    @State private var posed = false
    @State private var dragEnded = Date.distantPast
    /// Resets when a reorder ends or is cancelled, so a row is never left lifted.
    @GestureState private var isPressing = false

    var body: some View {
        let order = displayOrder
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(order) { place in
                    row(place)
                        .opacity(drag?.id == place.id ? 0 : 1)
                }
            }
            if let drag, let place = store.places.first(where: { $0.id == drag.id }) {
                lifted(place)
                    .offset(y: CGFloat(drag.from) * rowHeight + drag.dy)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.25), value: order.map(\.id))
        .sensoryFeedback(.impact(weight: .medium), trigger: drag?.id) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: drag?.target)
        .onAppear(perform: pose)
        .onChange(of: isPressing) { if !isPressing { endDrag() } }
        .onChange(of: drag == nil) { isReordering = drag != nil }
    }

    /// The list as it will be after the drag ends; the dragged row keeps its place in the
    /// hierarchy (so its gesture lives on) and is drawn as the gap.
    private var displayOrder: [SavedPlace] {
        var places = store.places
        guard let drag, let index = places.firstIndex(where: { $0.id == drag.id }) else { return places }
        let place = places.remove(at: index)
        places.insert(place, at: min(drag.target, places.count))
        return places
    }

    private func row(_ place: SavedPlace) -> some View {
        let x = swipe?.id == place.id ? swipe?.x ?? 0 : 0
        let isSelected = store.selection == .saved(place.id)
        return ZStack(alignment: .trailing) {
            PlaceRow(name: place.name, countryCode: place.countryCode, isSelected: isSelected) {
                if swipe != nil {
                    withAnimation(.snappy) { swipe = nil }
                } else if drag == nil, Date.now.timeIntervalSince(dragEnded) > 0.4 {
                    // Lifting a dragged row is not a tap.
                    select(place)
                }
            }
            .offset(x: x)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
            removeAction(place, x: x)
        }
        .gesture(HorizontalSwipe(
            changed: { translation in
                let base: CGFloat = isOpen(place) ? -Self.removeWidth : 0
                if swipe?.id != place.id { swipe = (place.id, base) }
                swipe = (place.id, min(0, base + translation))
            },
            ended: { translation, velocity in endSwipe(place, translation: translation, velocity: velocity) }))
        .simultaneousGesture(reorder(place))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove") { remove(place) }
        .accessibilityAction(named: "Move Up") { store.move(place.id, to: index(of: place) - 1) }
        .accessibilityAction(named: "Move Down") { store.move(place.id, to: index(of: place) + 1) }
    }

    /// Red Remove, sliding in from the screen edge 24 pt beyond the list (Figma).
    private func removeAction(_ place: SavedPlace, x: CGFloat) -> some View {
        Button { remove(place) } label: {
            Text("Remove")
                .textStyle(.labelM)
                .foregroundStyle(.actionOnPrimary)
                .frame(width: max(Self.removeWidth, -x), height: rowHeight)
                .background(.statusOffline)
        }
        .buttonStyle(.plain)
        .offset(x: Space.screenMargin + max(0, Self.removeWidth + x))
        .opacity(x < 0 ? 1 : 0)
        .accessibilityHidden(true)
    }

    /// Long-press a row, then drag. Simultaneous, or the row's button would keep the touch.
    /// The drag only starts after the long press, so a quick swipe up or down still scrolls;
    /// once a row is lifted the screen stops scrolling (`isReordering`), which would otherwise
    /// take the touch and cancel the drag.
    private func reorder(_ place: SavedPlace) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($isPressing) { value, pressing, _ in
                if case .second(true, _) = value { pressing = true }
            }
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                if drag == nil { beginDrag(place) }
                moveDrag(dragValue?.translation.height ?? 0)
            }
            .onEnded { _ in endDrag() }
    }

    private func lifted(_ place: SavedPlace) -> some View {
        PlaceRowContent(name: place.name, countryCode: place.countryCode,
                        isSelected: store.selection == .saved(place.id))
            .padding(.vertical, Space.s16)
            .padding(.horizontal, Space.s16)
            .background(.surfaceCard)
            .shadow(color: .black.opacity(0.6), radius: 14, y: 12)
            .padding(.horizontal, -Space.s16)
    }

    private func isOpen(_ place: SavedPlace) -> Bool {
        swipe?.id == place.id && (swipe?.x ?? 0) <= -Self.removeWidth
    }

    private func index(of place: SavedPlace) -> Int {
        store.places.firstIndex(of: place) ?? 0
    }

    private func endSwipe(_ place: SavedPlace, translation: CGFloat, velocity: CGFloat) {
        let x = swipe?.x ?? 0
        if x < -Self.removeWidth * 2.5 || (velocity < -1500 && x < -Self.removeWidth) {
            remove(place)
        } else if x < -Self.removeWidth / 2 || velocity < -400 {
            withAnimation(.snappy) { swipe = (place.id, -Self.removeWidth) }
        } else {
            withAnimation(.snappy) { swipe = nil }
        }
    }

    private func remove(_ place: SavedPlace) {
        withAnimation(.snappy) {
            swipe = nil
            store.remove(place.id)
        }
    }

    private func beginDrag(_ place: SavedPlace) {
        let from = index(of: place)
        withAnimation(.snappy(duration: 0.2)) {
            swipe = nil
            drag = Drag(id: place.id, from: from, dy: 0, target: from)
        }
    }

    private func moveDrag(_ dy: CGFloat) {
        guard var current = drag, rowHeight > 0 else { return }
        let lastIndex = store.places.count - 1
        // Keep the lifted row within the list.
        current.dy = min(max(dy, -CGFloat(current.from) * rowHeight),
                         CGFloat(lastIndex - current.from) * rowHeight)
        current.target = min(max(Int(((CGFloat(current.from) * rowHeight + current.dy) / rowHeight).rounded()), 0), lastIndex)
        drag = current
    }

    private func endDrag() {
        guard let current = drag else { return }
        dragEnded = .now
        withAnimation(.snappy(duration: 0.25)) {
            store.move(current.id, to: current.target)
            drag = nil
        }
    }

    /// Screenshot poses (debug builds): Figma's Swipe to remove and Dragging to reorder.
    private func pose() {
        guard !posed, store.places.count >= 3 else { return }
        posed = true
        switch DeveloperSettings.placesPose {
        case "swipe":
            swipe = (store.places[1].id, -Self.removeWidth)
        case "drag":
            // Rovaniemi lifted 6 pt below the gap it will drop into, as in Figma.
            drag = Drag(id: store.places[2].id, from: 2, dy: -55, target: 1)
        default:
            break
        }
    }
}

// MARK: - Gestures

/// A horizontal pan that only starts when the finger moves sideways, so the list still
/// scrolls vertically. UIKit, because a SwiftUI drag inside a scroll view blocks scrolling.
struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            changed(translation)
        case .ended:
            ended(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            ended(translation, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
