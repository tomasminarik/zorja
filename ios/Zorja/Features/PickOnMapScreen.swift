import MapKit
import SwiftUI

/// Pick On Map (Figma: Pick on map, Pick on map · No place yet, Pick on map · Typing,
/// Pick on map · Offline). The pin stays put while the map moves; the spot under its tip,
/// rounded to two decimals, is what "Use This Place" saves.
///
/// Opens on the selected place, or on the phone's Region country until the map is moved
/// (decision of 2026-11-05). Offline the map stays (it may not load), the spot is named
/// "Pinned Spot" by its coordinates and can still be saved.
struct PickOnMapScreen: View {
    let places: PlacesModel
    let back: () -> Void
    /// A place was saved and selected: close Places.
    let done: () -> Void

    @State private var search: PlaceSearchModel
    @State private var position: MapCameraPosition
    /// The spot under the pin's tip, once there is one.
    @State private var spot: RoundedCoordinate?
    /// Moved by the person (pan, zoom, search, Locate me) since the screen opened.
    @State private var moved = false
    /// The reverse lookup's answer and the spot it is for, so a moved pin never shows or
    /// saves the previous spot's name, country or time zone.
    @State private var named: (spot: RoundedCoordinate, name: SpotName?)?
    /// A search result's own name and details, which win over the reverse lookup.
    @State private var chosen: PlaceCandidate?
    @State private var panelHeight: CGFloat = 0
    /// No place and a Region country outside the built-in list: look it up once.
    private let looksUpCountry: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.openURL) private var openURL

    /// The pin's tip sits this far below the header's top (Figma: 380 − 54 on the 874 pt frame).
    static let pinTipBelowHeader: CGFloat = 326
    static let pinSize = CGSize(width: 36, height: 48)
    /// The tip is 2 pt above the image's bottom edge.
    static let pinTipInset: CGFloat = 2

    init(places: PlacesModel, back: @escaping () -> Void, done: @escaping () -> Void) {
        self.places = places
        self.back = back
        self.done = done
        let search = PlaceSearchModel(kind: .placesAndAddresses, service: places.search) { [places] in places.isOffline }
        if DeveloperSettings.initialPlacesScreen == "map", let text = DeveloperSettings.initialSearchText {
            search.text = text
        }
        _search = State(initialValue: search)
        let start = places.store.selectedPlace?.coordinate ?? places.location.coordinate
        _spot = State(initialValue: start)
        let country = MapRegions.country(Locale.current.region?.identifier)
        looksUpCountry = start == nil && country == nil
        if let start {
            _position = State(initialValue: .region(Self.placeRegion(start)))
        } else if let country {
            _position = State(initialValue: .region(country))
        } else {
            _position = State(initialValue: .region(MapRegions.world))
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let headerTop = ShellLayout.headerTop(safeAreaTop: insets.top)
            let tipY = headerTop + Self.pinTipBelowHeader
            let mapHeight = max(0, proxy.size.height + insets.top + insets.bottom - panelHeight)
            ZStack(alignment: .top) {
                map(tipY: tipY, width: proxy.size.width, height: mapHeight)
                    .frame(height: mapHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                LinearGradient(colors: [.bgBase, .bgBase.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                    .allowsHitTesting(false)
                Image("Map/pin")
                    .frame(width: Self.pinSize.width, height: Self.pinSize.height)
                    // Suggestions cover the map while typing (Figma: Pick on map · Typing).
                    .opacity(showsSuggestions ? 0 : 1)
                    .offset(y: tipY + Self.pinTipInset - Self.pinSize.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(spacing: Space.s12) {
                    ZorjaHeader(kind: .back(back))
                    VStack(spacing: Space.s8) {
                        SearchField(placeholder: "Search A Place Or Address", text: $search.text, isFocused: $searchFocused)
                        results
                    }
                    .padding(.horizontal, Space.screenMargin)
                }
                .padding(.top, headerTop)
                VStack(spacing: Space.s16) {
                    Spacer(minLength: 0)
                    locateMe
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, Space.screenMargin)
                    panel(bottomInset: insets.bottom)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { panelHeight = $0 }
                }
            }
            .ignoresSafeArea(.container)
        }
        .ignoresSafeArea(.keyboard)
        .background(.bgBase)
        .onChange(of: places.isOffline, initial: true) { search.refresh() }
        .task { await openOnCountryIfNeeded() }
        // Again on coming back online, so a spot pinned offline gets its name.
        .task(id: SpotLookup(spot: spot, offline: places.isOffline)) { await nameSpot() }
        .task {
            if !search.text.isEmpty { searchFocused = true }
        }
    }

    // MARK: Map

    private func map(tipY: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) {}
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls {}
                // Grey, as in Figma: MapKit's dark map colours land cover green, which would
                // compete with the aurora green that marks the one standout action.
                .saturation(0)
                // Centre the camera on the pin's tip, so a place opens under the pin.
                .safeAreaPadding(.top, max(0, 2 * tipY - height))
                .safeAreaPadding(.bottom, max(0, height - 2 * tipY))
                .onMapCameraChange(frequency: .onEnd) { _ in
                    guard position.positionedByUser,
                          let point = proxy.convert(CGPoint(x: width / 2, y: tipY), from: .local)
                    else { return }
                    chosen = nil
                    moved = true
                    spot = RoundedCoordinate(latitude: point.latitude, longitude: point.longitude)
                }
                .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        }
    }

    private func move(to coordinate: RoundedCoordinate) {
        withAnimation(.snappy) { position = .region(Self.placeRegion(coordinate)) }
    }

    /// About 20 km across: town scale, as in Figma.
    static func placeRegion(_ coordinate: RoundedCoordinate) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }

    /// Countries outside the built-in list are looked up once with MapKit.
    private func openOnCountryIfNeeded() async {
        guard looksUpCountry, spot == nil, !places.isOffline,
              let code = Locale.current.region?.identifier,
              let region = await places.search.region(ofCountry: code),
              !moved
        else { return }
        position = .region(region)
    }

    /// Names the spot with a reverse lookup of its rounded coordinate, when online.
    private func nameSpot() async {
        guard let spot, chosen == nil, !places.isOffline else { return }
        let name = await places.search.name(at: spot)
        guard !Task.isCancelled else { return }
        named = (spot, name)
    }

    /// The lookup's name for the current spot; nil while it runs or when it found none.
    private var spotName: SpotName? {
        guard let named, named.spot == spot else { return nil }
        return named.name
    }

    /// Online, a pinned spot waits for its name, so it isn't saved with the wrong time zone.
    private var naming: Bool {
        guard let spot, chosen == nil, !places.isOffline else { return false }
        return named?.spot != spot
    }

    // MARK: Search

    private var showsSuggestions: Bool {
        switch search.phase {
        case .results, .noMatch: true
        case .idle, .searching, .offline: false
        }
    }

    @ViewBuilder private var results: some View {
        switch search.phase {
        case .results(let suggestions):
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SearchResultRow(name: suggestion.name, detail: suggestion.detail,
                                    showsHairline: index < suggestions.count - 1) { choose(suggestion) }
                }
            }
            .padding(.horizontal, Space.s16)
            .background(.surfaceCard)
        case .noMatch(let text):
            Text(PlacesCopy.noMatchOnMap(text))
                .textStyle(.bodyM)
                .foregroundStyle(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s16)
                .padding(.vertical, Space.s16)
                .background(.surfaceCard)
        case .idle, .searching, .offline:
            EmptyView()
        }
    }

    private func choose(_ suggestion: PlaceSuggestion) {
        Task {
            guard let candidate = try? await places.search.resolve(suggestion) else {
                search.refresh()
                return
            }
            searchFocused = false
            search.text = ""
            chosen = candidate
            moved = true
            spot = candidate.coordinate
            move(to: candidate.coordinate)
        }
    }

    // MARK: Locate me and the panel

    private var locateMe: some View {
        Button(action: locate) {
            ZorjaIcon.location.sized(IconSize.button)
                .foregroundStyle(.iconPrimary)
                .frame(width: 48, height: 48)
                .background(.surfaceControl, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(places.location.access == .off ? "Turn On Location" : "Go to my location")
    }

    private func locate() {
        if places.location.access == .off {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        Task {
            guard case .found(let coordinate) = await places.location.readOnce() else { return }
            chosen = nil
            moved = true
            spot = coordinate
            move(to: coordinate)
        }
    }

    private func panel(bottomInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if places.isOffline {
                ZorjaTag(kind: .offline)
                Color.clear.frame(height: Space.s8)
            }
            if let spot {
                Text(title)
                    .textStyle(.titleL)
                    .foregroundStyle(.textPrimary)
                Text(detail(spot))
                    .textStyle(.bodyM)
                    .foregroundStyle(.textSecondary)
            } else {
                Text(PlacesCopy.moveTheMap)
                    .textStyle(.titleL)
                    .foregroundStyle(.textPrimary)
            }
            Color.clear.frame(height: Space.s16)
            ZorjaButton("Use This Place", size: .large, fillsWidth: true, action: use)
                .disabled(spot == nil || naming)
            if let footnote {
                Text(footnote)
                    .textStyle(.bodyS)
                    .foregroundStyle(.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.screenMargin)
        .padding(.top, Space.s24)
        // Figma: 48 pt below the button area on a phone with a home indicator (34 pt).
        .padding(.bottom, max(Space.s24, bottomInset + 14))
        .background(.bgBase)
    }

    /// Offline: the offline message. Opened on a place and not moved yet: how to move the pin.
    private var footnote: String? {
        if places.isOffline { return PlacesCopy.mapOffline }
        if spot != nil, !moved { return PlacesCopy.moveTheMap }
        return nil
    }

    private var title: String {
        if let chosen { return chosen.name }
        if !places.isOffline, let town = spotName?.locality { return PlacesCopy.near(town) }
        return PlacesCopy.pinnedSpot
    }

    private func detail(_ spot: RoundedCoordinate) -> String {
        let country: String? = if let chosen {
            Locale(identifier: "en_US_POSIX").localizedString(forRegionCode: chosen.countryCode)
        } else if !places.isOffline {
            spotName?.country
        } else {
            nil
        }
        guard let country, !country.isEmpty else { return spot.displayText }
        return "\(country), \(spot.displayText)"
    }

    /// Saves what the panel shows: the search result, "Near <town>", or "Pinned Spot".
    private func use() {
        guard let spot else { return }
        let candidate = chosen ?? PlaceCandidate(
            name: title,
            countryCode: places.isOffline ? "" : spotName?.countryCode ?? "",
            coordinate: spot,
            timeZone: (places.isOffline ? nil : spotName?.timeZone)
                ?? TimeZone.fallbackIdentifier(for: spot))
        places.store.add(candidate)
        done()
    }
}

private struct SpotLookup: Equatable {
    let spot: RoundedCoordinate?
    let offline: Bool
}

/// Where the map opens for the phone's Region country, for the launch regions and their
/// neighbours, so the map can open without a lookup (and offline).
enum MapRegions {
    static func country(_ code: String?) -> MKCoordinateRegion? {
        guard let code, let box = boxes[code.uppercased()] else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: box.0, longitude: box.1),
            span: MKCoordinateSpan(latitudeDelta: box.2, longitudeDelta: box.3))
    }

    /// The whole world, when the Region country is unknown and can't be looked up.
    static let world = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 180))

    /// Centre latitude, centre longitude, latitude span, longitude span.
    private static let boxes: [String: (Double, Double, Double, Double)] = [
        "NO": (65.0, 14.0, 15, 30), "SE": (62.5, 16.5, 14, 20), "FI": (64.5, 26.0, 11, 16),
        "IS": (64.9, -18.6, 4, 10), "DK": (56.0, 10.5, 3.5, 8), "FO": (62.0, -6.9, 1, 2),
        "PL": (52.0, 19.4, 6, 11), "CA": (60.0, -96.0, 40, 90), "GB": (54.5, -3.0, 11, 12),
        "IE": (53.4, -8.0, 4, 6), "EE": (58.7, 25.0, 2.5, 6), "LV": (56.9, 24.6, 2.5, 6),
        "LT": (55.2, 23.9, 2.5, 6), "DE": (51.2, 10.4, 8, 10),
    ]
}
