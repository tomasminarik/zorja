import SwiftUI

/// Settings the developer menu changes. They are plain UserDefaults keys, so they can also be
/// set at launch: `-sample polar-night -unexpired YES -appState loading -source hosted`.
enum DeveloperSettings {
    static let sampleKey = "sample"
    static let unexpiredKey = "unexpired"
    static let appStateKey = "appState"
    static let sourceKey = "source"
    static let localBaseURLKey = "localBaseURL"
    static let defaultSample = "promising-now"
    /// The tab the app opens on. Debug builds read `-tab tonight` at launch, for screenshots.
    static var initialTab: MenuTab {
        #if DEBUG
        UserDefaults.standard.string(forKey: "tab").flatMap(MenuTab.init(rawValue:)) ?? .now
        #else
        .now
        #endif
    }
    /// Debug-only launch strings for Places screenshots; release builds always read nil.
    private static func debugString(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }

    /// `-places sample`: the Figma places (Tromsø selected), in memory only, never saved over
    /// the real ones. `-places none`: no places and nothing selected, also in memory.
    static var placesFixture: String? { debugString("places") }
    /// `-placeSearch sample`: search answers from the Figma frames instead of MapKit.
    static var usesSampleSearch: Bool { debugString("placeSearch") == "sample" }
    /// `-placesScreen places` or `map`: open Places, or Pick On Map, at launch.
    static var initialPlacesScreen: String? { debugString("placesScreen") }
    /// `-searchText Tro`: text already typed in the open screen's search field.
    static var initialSearchText: String? { debugString("searchText") }
    /// `-placesPose swipe` or `drag`: a row held mid-gesture (Figma: Swipe to remove,
    /// Dragging to reorder).
    static var placesPose: String? { debugString("placesPose") }
    #if DEBUG
    /// `-gallery components` or `sky`: open a development gallery instead of the app,
    /// for screenshots.
    @MainActor static var initialGallery: AnyView? {
        switch debugString("gallery") {
        case "components": AnyView(ComponentsGallery())
        case "sky": AnyView(AuroraSkyView())
        default: nil
        }
    }
    #endif
    /// `-firstLaunchPage location` or `places`: open first launch on that page, for screenshots.
    /// Pair it with `-firstLaunchDone NO`.
    static var initialFirstLaunchPage: FirstLaunchView.Page {
        switch debugString("firstLaunchPage") {
        case "location": .location
        case "places": .places
        default: .welcome
        }
    }
    /// `-cover tips` or `about`: open Tips or About at launch, for screenshots.
    static var initialCover: String? { debugString("cover") }
    /// `-aboutOpen sources`, `privacy` or `licences`: About opens with that accordion open.
    static var initialAboutSection: AboutScreen.Section? { debugString("aboutOpen").flatMap(AboutScreen.Section.init(rawValue:)) }
    /// `-tipsTimer running` (14:32 left, as in Figma) or `ready`: the eye timer already started.
    static func initialEyeTimer(now: Date = .now) -> EyeTimer {
        switch debugString("tipsTimer") {
        case "running": EyeTimer(startedAt: now.addingTimeInterval(-(EyeTimer.duration - 14 * 60 - 32)))
        case "ready": EyeTimer(startedAt: now.addingTimeInterval(-EyeTimer.duration))
        default: EyeTimer()
        }
    }
    /// `-locationOff YES`: location reads as turned off, without touching the real setting.
    static var locationOff: Bool { debugString("locationOff") == "YES" }
}

/// An app state forced over the chosen sample, to check each App states frame.
enum ForcedAppState: String, CaseIterable, Identifiable {
    case none, loading, offline, offlineNoForecast, error, rateLimited

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "As the sample says"
        case .loading: "Loading"
        case .offline: "Offline, forecast still current"
        case .offlineNoForecast: "Offline, no current forecast"
        case .error: "Server error"
        case .rateLimited: "Rate limited"
        }
    }

    /// The screen for this state over a sample. `forcedAt` is when the state was chosen and
    /// `lastRequest` when Try Again last ran, so delays stay put across redraws: an error
    /// opens with Try Again on (as in Figma), and after a retry it is off for the request
    /// floor; rate limited stays off until a minute after the last request.
    func input(from payload: FixtureLibrary.Payload?, forcedAt: Date = .now, lastRequest: Date? = nil) -> ScreenInput {
        var forecast: Forecast?
        var problem: ForecastLoader.Problem?
        switch payload {
        case .forecast(let sample): forecast = sample
        case .error(let error): problem = error.code == .rateLimited ? .rateLimited : .unavailable
        case nil: problem = .unreadable
        }
        let place = forecast.map { FixtureLibrary.placeName(for: $0.location) } ?? "Stockholm"
        switch self {
        case .none:
            return ScreenInput(forecast: forecast, problem: problem, place: place)
        case .loading:
            return ScreenInput(place: place)
        case .offline:
            return ScreenInput(forecast: forecast, problem: .offline, place: place)
        case .offlineNoForecast:
            // The old forecast stays, past its refreshAfter (`pinnedNow`): "Last update HH:MM".
            return ScreenInput(forecast: forecast, problem: .offline, place: place)
        case .error:
            let next = lastRequest?.addingTimeInterval(RevalidationSchedule.minimumFloor)
            return ScreenInput(problem: .unavailable, nextCheck: next, place: place)
        case .rateLimited:
            let next = (lastRequest ?? forcedAt).addingTimeInterval(RevalidationSchedule.minimumFloor)
            return ScreenInput(problem: .rateLimited, nextCheck: next, place: place)
        }
    }

    /// The frozen clock for this state, if any. "Show as unexpired" reads the sample at its
    /// own generatedAt; offline without a current forecast reads it at its refreshAfter, so
    /// the old forecast is out of date whatever the sample's dates.
    func pinnedNow(for forecast: Forecast?, unexpired: Bool) -> Date? {
        if self == .offlineNoForecast, let forecast { return forecast.refreshAfter }
        return unexpired ? forecast?.generatedAt : nil
    }
}

extension ForcedAppState {
    /// The forced states that mean the phone is offline, for search and the map too.
    var isOffline: Bool { self == .offline || self == .offlineNoForecast }
}

extension FixtureLibrary {
    /// A name for the samples' synthetic coordinates, shown while My Location has no reading.
    static func placeName(for location: Location) -> String {
        switch (location.latitude, location.longitude) {
        case (59.3...59.4, 18.0...18.1): "Stockholm"
        case (69.6...69.7, 18.9...19.0): "Tromsø"
        case (77.5...78.5, _): "Svalbard"
        case (85..., _): "North Pole"
        default: "Sample place"
        }
    }
}

#if DEBUG
/// Debug builds only. Opened by holding the header.
struct DeveloperMenu: View {
    @AppStorage(DeveloperSettings.sampleKey) private var sample = DeveloperSettings.defaultSample
    @AppStorage(DeveloperSettings.unexpiredKey) private var showsUnexpired = false
    @AppStorage(DeveloperSettings.appStateKey) private var forced = ForcedAppState.none
    @AppStorage(DeveloperSettings.sourceKey) private var source = ForecastSource.samples
    @AppStorage(DeveloperSettings.localBaseURLKey) private var localBaseURL = ForecastEndpoint.localBaseURL
    @AppStorage(FirstLaunchView.doneKey) private var firstLaunchDone = false
    @AppStorage(AuroraSkyStyle.defaultsKey) private var skyStyle = AuroraSkyStyle.appDefault
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Forecast from", selection: $source) {
                        ForEach(ForecastSource.allCases) { Text($0.title).tag($0) }
                    }
                    if source == .local {
                        TextField("Local base URL", text: $localBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section("Samples") {
                    Picker("Sample", selection: $sample) {
                        ForEach(FixtureLibrary.names, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Show as unexpired", isOn: $showsUnexpired)
                    Picker("App state", selection: $forced) {
                        ForEach(ForcedAppState.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Aurora sky") {
                    Picker("Look", selection: $skyStyle) {
                        ForEach(AuroraSkyStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("First launch") {
                    Button("Show first launch again") {
                        firstLaunchDone = false
                        dismiss()
                    }
                }
                Section("Galleries") {
                    NavigationLink("Foundations") { FoundationsGallery() }
                    NavigationLink("Components") { ComponentsGallery() }
                    NavigationLink("Aurora sky") { AuroraSkyGallery() }
                }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

#endif

/// The real POST client for the selected place's rounded coordinates. Release builds always
/// draw this against the hosted service. Nothing is requested until there is a place to check:
/// while My Location is still being read the screen shows Loading, never another place.
struct LiveShell: View {
    /// nil when the developer menu's local address isn't allowed (not HTTPS or loopback).
    let endpoint: ForecastEndpoint?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlacesModel.self) private var places
    @State private var loader: ForecastLoader?

    private struct Run: Equatable {
        let active: Bool
        let online: Bool
        let query: ForecastQuery?
    }

    var body: some View {
        let query = places.query
        AppShell(input: input, onRetry: {
            guard let query else { return }
            Task { await loader?.refresh(query) }
        })
        // Requests run only while the app is in the foreground, and again for a new place or
        // when the phone is back online ("It tries again when you're back online"). The
        // loader's request floor still applies.
        .task(id: Run(active: scenePhase == .active, online: places.connectivity.isOnline, query: query)) {
            if loader == nil, let endpoint {
                loader = ForecastLoader(client: ForecastClient(endpoint: endpoint))
            }
            if scenePhase == .active, let loader, let query { await loader.keepFresh(query) }
        }
    }

    private var input: ScreenInput {
        let place = places.placeName(fallback: PlacesModel.myLocationTitle)
        var input: ScreenInput
        if let loader {
            // Each place has its own forecast and problem: another place's is never shown.
            let query = places.query
            input = ScreenInput(
                forecast: query.flatMap(loader.forecast(for:)),
                problem: query.flatMap(loader.problem(for:)),
                nextCheck: query.map(loader.earliestStart(for:)) ?? loader.floorEnd, place: place)
            input.refreshing = query.map(loader.isLoading(_:)) ?? false
        } else {
            input = ScreenInput(problem: .rejectedRequest, place: place)
        }
        input.location = places.locationProblem
        return input
    }
}
