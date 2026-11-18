import SwiftUI

/// The app's root: picks where the forecast comes from, then draws the shell.
/// Release builds always use the hosted service; debug builds follow the developer menu's
/// source (bundled samples by default, so screenshots stay fixed).
struct AppRoot: View {
    @State private var places = PlacesModel.makeDefault()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FirstLaunchView.doneKey) private var firstLaunchDone = false
    #if DEBUG
    @AppStorage(DeveloperSettings.sampleKey) private var sample = DeveloperSettings.defaultSample
    @AppStorage(DeveloperSettings.unexpiredKey) private var showsUnexpired = false
    @AppStorage(DeveloperSettings.appStateKey) private var forced = ForcedAppState.none
    /// When the forced app state was chosen, and when the samples' Try Again last ran.
    @State private var forcedAt = Date.now
    @State private var lastRequest: Date?
    /// Try Again on the samples shows Loading for a moment, then the forced state again.
    @State private var retrying = false
    @AppStorage(DeveloperSettings.sourceKey) private var source = ForecastSource.samples
    @AppStorage(DeveloperSettings.localBaseURLKey) private var localBaseURL = ForecastEndpoint.localBaseURL
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let gallery = DeveloperSettings.initialGallery {
                gallery
            } else if !firstLaunchDone {
                firstLaunch
            } else if source == .samples {
                sampleShell
            } else {
                let endpoint = source.endpoint(localBaseURL: localBaseURL)
                LiveShell(endpoint: endpoint).id(endpoint?.url)
            }
            #else
            if firstLaunchDone { LiveShell(endpoint: .hosted) } else { firstLaunch }
            #endif
        }
        .environment(places)
        #if DEBUG
        // Forced app states are a developer-menu tool; release builds have none.
        .onChange(of: forced, initial: true) {
            places.forcedOffline = forced.isOffline
            forcedAt = .now
            lastRequest = nil
        }
        #endif
        // My Location is read once at launch, only if permission was already given.
        .task { await places.refreshMyLocationIfAllowed() }
        // And again on return to the foreground when that reading is over 30 minutes old.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await places.refreshMyLocationIfOld() } }
        }
        // Location turned on in Settings: read it, if My Location is the choice.
        .onChange(of: places.location.access) { _, access in
            if access == .allowed, places.location.coordinate == nil {
                Task { await places.refreshMyLocationIfAllowed() }
            }
        }
    }

    private var firstLaunch: some View {
        FirstLaunchView(places: places) {
            withAnimation(.easeInOut(duration: 0.3)) { firstLaunchDone = true }
        }
    }

    #if DEBUG
    private var sampleShell: some View {
        let payload = try? FixtureLibrary.load(sample)
        let state = retrying ? ForcedAppState.loading : forced
        var input = state.input(from: payload, forcedAt: forcedAt, lastRequest: lastRequest)
        input.place = places.placeName(fallback: input.place)
        input.location = places.locationProblem
        let pinned = state.pinnedNow(for: input.forecast, unexpired: showsUnexpired)
        return AppShell(input: input, pinnedNow: pinned, onRetry: retrySample)
    }

    /// The samples have no request to repeat: Try Again shows Loading for a moment, as a
    /// real request would, then the same state with the request floor counted from now.
    private func retrySample() {
        guard !retrying else { return }
        lastRequest = .now
        withAnimation(.easeInOut(duration: 0.3)) { retrying = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.3)) { retrying = false }
        }
    }
    #endif
}

/// Header, the three menu screens and the sky behind Now. `pinnedNow` freezes the clock
/// (developer menu); otherwise the screen is redrawn at `refreshAfter` and every minute.
struct AppShell: View {
    let input: ScreenInput
    var pinnedNow: Date?
    var onRetry: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @State private var tab: MenuTab = DeveloperSettings.initialTab
    @State private var cover: Cover? = DeveloperSettings.initialCover.flatMap(Cover.init(rawValue:))
        ?? (DeveloperSettings.initialPlacesScreen == nil ? nil : .places)
    /// Kept here, not in Tips, so the eye timer keeps running while Tips is closed.
    @State private var eyeTimer = DeveloperSettings.initialEyeTimer()
    @Environment(PlacesModel.self) private var places
    @State private var calendarDraft: CalendarEventDraft?
    /// About and Tips zoom out of the button that opens them (`coverSource`).
    @Namespace private var coverZoom
    /// The floating menu's height, which 3 Nights scrolls under.
    @State private var menuHeight: CGFloat = 0
    #if DEBUG
    @State private var showsDeveloperMenu = false
    #endif

    enum Cover: String, Identifiable {
        case about, places, tips
        var id: Self { self }
    }

    var body: some View {
        TimelineView(ScreenSchedule(boundaries: pinnedNow == nil ? [input.forecast?.refreshAfter, input.nextCheck].compactMap { $0 } : [])) { context in
            let state = ScreenState.make(input, now: pinnedNow ?? context.date)
            content(state, now: pinnedNow ?? context.date)
        }
        .environment(\.coverTransition, coverZoom)
        .sheet(item: $calendarDraft) { draft in
            CalendarEventSheet(draft: draft) { calendarDraft = nil }
                .ignoresSafeArea()
        }
        // Places, About and Tips each zoom out of the control that opens them.
        .fullScreenCover(item: $cover) { cover in
            Group {
                switch cover {
                case .places: PlacesScreen(places: places) { self.cover = nil }
                case .about: AboutScreen(open: DeveloperSettings.initialAboutSection) { self.cover = nil }
                case .tips: TipsScreen(timer: $eyeTimer) { self.cover = nil }
                }
            }
            .navigationTransition(.zoom(sourceID: cover.rawValue, in: coverZoom))
        }
        #if DEBUG
        .sheet(isPresented: $showsDeveloperMenu) { DeveloperMenu() }
        #endif
    }

    private func openPlaces() {
        cover = .places
    }

    private func select(_ next: MenuTab) {
        withAnimation(ZorjaMotion.snap) { tab = next }
    }

    private func content(_ state: ScreenState, now: Date) -> some View {
        ZStack {
            AuroraSkyView(level: tab == .now ? state.sky : .off)
                // A new state (loading to forecast, Try Again) fades the sky; a tab change doesn't.
                .animation(.easeInOut(duration: 1.2), value: state.sky)
                .transaction(value: tab) { $0.animation = nil }
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                // Every screen scrolls under the menu; Tonight and 3 Nights also under the header,
                // so their scroll edge effect reaches the top.
                let headerSpace = ShellLayout.headerTop(safeAreaTop: insets.top) + ShellLayout.headerHeight
                let menuSpace = menuHeight + ShellLayout.menuBottom(safeAreaBottom: insets.bottom)
                let underHeader = switch tab {
                case .now: false
                case .tonight: state.tonight != nil
                case .threeNights: state.threeNights != nil
                }
                VStack(spacing: 0) {
                    ZorjaHeader(kind: .location(place: state.showsPlace ? input.place : nil, openPlaces: openPlaces, openAbout: { cover = .about }))
                    #if DEBUG
                        // The whole header, including the empty space between its buttons.
                        // Holding the place name opens Places instead.
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.8) { showsDeveloperMenu = true }
                    #endif
                        .padding(.top, ShellLayout.headerTop(safeAreaTop: insets.top))
                        .zIndex(1)
                    Group {
                        switch tab {
                        case .now:
                            NowScreen(state: state, now: now, onRetry: onRetry, onAction: perform, actionsEnabled: !places.isLocating,
                                      openTonight: { select(.tonight) })
                        case .tonight:
                            if let tonight = state.tonight {
                                TonightScreen(tonight: tonight, status: state.status,
                                              openTips: { cover = .tips },
                                              openThreeNights: { select(.threeNights) })
                            } else {
                                // Offline without a forecast and errors read the same on every tab.
                                NowScreen(state: state, now: now, onRetry: onRetry, onAction: perform, actionsEnabled: !places.isLocating)
                            }
                        case .threeNights:
                            if let threeNights = state.threeNights {
                                ThreeNightsScreen(state: threeNights, status: state.status,
                                                  addToCalendar: { calendarDraft = $0 })
                            } else {
                                // Offline without a forecast and errors read the same on every tab.
                                NowScreen(state: state, now: now, onRetry: onRetry, onAction: perform, actionsEnabled: !places.isLocating)
                            }
                        }
                    }
                    // Each tab's content fades over the last one, then rises in (`riseIn`).
                    .id(tab)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, underHeader ? -headerSpace : 0)
                    .environment(\.headerSpace, headerSpace)
                    .padding(.bottom, -menuSpace)
                    .environment(\.menuSpace, menuSpace)
                    FloatingMenu(selection: $tab, auroraActive: state.auroraActive)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { menuHeight = $0 }
                        .padding(.bottom, ShellLayout.menuBottom(safeAreaBottom: insets.bottom))
                }
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                // The reader keeps the safe area so `insets` are the screen's; the stack
                // then places header and menu itself (`ShellLayout`).
                .ignoresSafeArea(.container)
            }
        }
        .preferredColorScheme(.dark)
    }
}

extension AppShell {
    private func perform(_ action: NowAction) {
        switch action {
        case .choosePlace:
            openPlaces()
        case .turnOnLocation:
            if places.location.access == .notAsked {
                Task { await places.useMyLocation() }
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        case .findMeAgain:
            Task { await places.useMyLocation() }
        }
    }
}

/// Where the header and menu sit, from the Figma frames.
enum ShellLayout {
    /// The 402 pt frames draw a 54 pt status bar; the 375 pt frames start the header at the
    /// 20 pt status bar. So the header starts at the safe area, but no lower than 54 pt: on
    /// phones whose status bar area is taller (62 pt on iPhone 17 Pro) it sits where Figma
    /// puts it, still below the Dynamic Island and the status bar's contents.
    static let figmaStatusBar: CGFloat = 54

    static func headerTop(safeAreaTop: CGFloat) -> CGFloat { min(safeAreaTop, figmaStatusBar) }

    /// Figma: Header.
    static let headerHeight: CGFloat = 44

    /// The menu ends on the home indicator's safe area (34 pt), or 8 pt above the bottom
    /// edge on phones without one (Small iPhone frames).
    static let menuMinimumBottom: CGFloat = 8

    static func menuBottom(safeAreaBottom: CGFloat) -> CGFloat { max(safeAreaBottom, menuMinimumBottom) }
}

/// The Now screen (Figma: Now, the Now frames of Forecast and App states, and Small iPhone).
///
/// The top is anchored to the header: status line 24 pt below it, headline 16 pt below that,
/// lead 24 pt below the headline. The bottom line ends 48 pt above the menu, Try Again 32 pt.
/// Headline, lead and bottom line are set on balanced lines (`BalancedText`). Where the
/// content is narrower than on the 402 pt frame (375 pt iPhones), the bottom line drops from
/// 44 to 40 pt so it stays on two lines (decision of 2026-11-05).
struct NowScreen: View {
    let state: ScreenState
    let now: Date
    var onRetry: () -> Void = {}
    var onAction: (NowAction) -> Void = { _ in }
    /// Off while a location read runs, so Try Again isn't tapped twice.
    var actionsEnabled = true
    var openTonight: () -> Void = {}
    /// The menu NowScreen scrolls under; its content still ends above it.
    @Environment(\.menuSpace) private var menuSpace

    /// Text width on the 402 pt Figma frame.
    nonisolated static let figmaContentWidth: CGFloat = 354
    /// Display/L size on the Small iPhone frames.
    nonisolated static let smallBottomLineSize: CGFloat = 40

    var body: some View {
        // At large text sizes the content may not fit above the menu; then it scrolls, under
        // the menu like the other screens.
        GeometryReader { proxy in
            ScrollView {
                content.frame(minHeight: max(0, proxy.size.height - menuSpace))
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollsUnderMenu()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The status line keeps its place when there is none (Loading, Error).
            // It grows only when large text needs more room.
            ZStack {
                Color.clear.frame(height: 18)
                status
            }
            .riseIn(0)
            .padding(.top, Space.s24)
            BalancedText(state.headline, style: .displayXL)
                .riseIn(1)
                .padding(.top, Space.s16)
            Group {
                if state.balancesLead {
                    BalancedText(state.lead, style: .lead)
                } else {
                    PlainLead(text: state.lead)
                }
            }
            .riseIn(2)
            .padding(.top, Space.s24)
            Spacer(minLength: Space.s48)
            if let bottom = state.bottomLine {
                bottomLine(bottom)
                    .riseIn(3)
                    .padding(.bottom, Space.s48)
            }
            if !state.actions.isEmpty {
                // Figma: Actions, 12 pt apart, 32 pt above the menu.
                VStack(spacing: Space.s12) {
                    ForEach(Array(state.actions.enumerated()), id: \.offset) { index, action in
                        ZorjaButton(action.title, icon: action.icon, style: index == 0 ? .primary : .outline,
                                    size: .large, fillsWidth: true) { onAction(action) }
                    }
                }
                .disabled(!actionsEnabled)
                .riseIn(4)
                .padding(.bottom, Space.s32)
            }
            if let retry = state.retry {
                ZorjaButton("Try Again", size: .large, fillsWidth: true, action: onRetry)
                    .disabled(!retry.isEnabled(at: now))
                    .padding(.bottom, Space.s32)
            }
        }
        .padding(.horizontal, Space.screenMargin)
        .frame(maxWidth: .infinity)
    }

    private func bottomLine(_ bottom: Phrase) -> some View {
        NowBottomLine(phrase: bottom, openTonight: openTonight)
    }

    @ViewBuilder private var status: some View {
        if let status = state.status {
            AdaptiveStack(horizontalAlignment: .center, spacing: Space.s8) {
                if case .offline = status { ZorjaTag(kind: .offline) }
                Text(status.text).textStyle(.bodyS).foregroundStyle(.textTertiary)
                    .multilineTextAlignment(.center)
                    // A faint dark pill, so the line stays readable over a bright sky. It is
                    // drawn outside the text's frame, so the layout doesn't move.
                    .background {
                        Capsule()
                            .fill(.bgBase.opacity(0.2))
                            .padding(.horizontal, -Space.s12)
                            .padding(.vertical, -6)
                    }
            }
        }
    }
}

/// A centred lead that wraps as Figma wraps it (first launch and location states).
struct PlainLead: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.lead)
            .foregroundStyle(.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

/// The bottom line, at 40 pt where the content is narrower than on the 402 pt frame.
private struct NowBottomLine: View {
    let phrase: Phrase
    let openTonight: () -> Void

    @State private var width = NowScreen.figmaContentWidth

    var body: some View {
        let size: CGFloat? = width < NowScreen.figmaContentWidth ? NowScreen.smallBottomLineSize : nil
        let text = BalancedText(phrase, style: .displayL, size: size)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        if phrase.linksToTonight {
            Button(action: openTonight) { text }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Tonight")
        } else {
            text
        }
    }
}

extension Phrase {
    /// Lines that name tonight's window open Tonight.
    var linksToTonight: Bool { text.hasPrefix("Tonight") || text.hasPrefix("Today") }
}

/// Redraws at the forecast's `refreshAfter`, so a recommendation is withdrawn on time, at the
/// next allowed request, so Try Again turns on when its delay ends, and every minute for the
/// times on screen.
struct ScreenSchedule: TimelineSchedule {
    let boundaries: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            let minute = current.addingTimeInterval(60)
            next = boundaries.filter { $0 > current && $0 < minute }.min() ?? minute
            return current
        }
    }
}

#Preview("Shell · Go") {
    let forecast = try? FixtureLibrary.load("promising-now")
    let input = ForcedAppState.none.input(from: forecast)
    AppShell(input: input, pinnedNow: input.forecast?.generatedAt)
        .environment(PlacesModel.preview())
}
