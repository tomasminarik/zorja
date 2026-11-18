import SwiftUI

/// First launch (Figma: First launch and location): Welcome, then the location ask, from which
/// "Choose A Place Instead" opens Places with Back. It ends when the location has been asked
/// for (whatever the answer: Now then shows the forecast, "Can't Find You." or "Where Are You?")
/// or a place has been chosen. Back from Places returns to the location ask.
struct FirstLaunchView: View {
    let places: PlacesModel
    let finish: () -> Void

    enum Page { case welcome, location, places }

    @State private var page: Page = DeveloperSettings.initialFirstLaunchPage
    @State private var isReading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch page {
            case .welcome:
                WelcomeScreen { show(.location) }
                    .transition(.opacity)
            case .location:
                LocationAskScreen(isReading: isReading, useMyLocation: useMyLocation,
                                  choosePlace: { show(.places) })
                    .transition(.opacity)
            case .places:
                PlacesScreen(places: places, mode: .firstLaunch(back: { show(.location) }), close: finish)
                    .transition(.screenPush(reduceMotion: reduceMotion))
                    .zIndex(1)
            }
        }
        .background(.bgBase)
        .preferredColorScheme(.dark)
    }

    private func show(_ next: Page) {
        withAnimation(.easeInOut(duration: 0.3)) { page = next }
    }

    private func useMyLocation() {
        isReading = true
        Task {
            await places.useMyLocation()
            isReading = false
            finish()
        }
    }
}

extension FirstLaunchView {
    /// Whether first launch has been finished on this phone.
    static let doneKey = "firstLaunchDone"
}

/// Shared frame of the two first-launch screens: headline 64 pt below the status bar, lead
/// 24 pt under it, and the actions ending 16 pt above the home indicator. No header, no menu.
private struct FirstLaunchPage<Middle: View, Actions: View>: View {
    let headline: Phrase
    let lead: String
    @ViewBuilder let middle: Middle
    @ViewBuilder let actions: Actions

    /// Figma: the headline starts 64 pt below the 54 pt status bar.
    static var headlineGap: CGFloat { 64 }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ScrollView {
                VStack(spacing: 0) {
                    BalancedText(headline, style: .displayXL)
                        .accessibilityAddTraits(.isHeader)
                        .riseIn(0)
                    PlainLead(text: lead)
                        .riseIn(1)
                        .padding(.top, Space.s24)
                    middle
                        .riseIn(2)
                    Spacer(minLength: Space.s32)
                    VStack(spacing: Space.s12) { actions }
                        .riseIn(3)
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, ShellLayout.headerTop(safeAreaTop: insets.top) + Self.headlineGap)
                .padding(.bottom, ShellLayout.menuBottom(safeAreaBottom: insets.bottom) + Space.s16)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .frame(minHeight: proxy.size.height + insets.top + insets.bottom)
            }
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(.container)
        }
    }
}

/// Figma: Welcome. The only first-launch screen with the aurora sky.
struct WelcomeScreen: View {
    let getStarted: () -> Void

    var body: some View {
        ZStack {
            AuroraSkyView(level: .full)
            FirstLaunchPage(
                headline: Phrase("Know When To Look Up.", emphasis: "Look Up"),
                lead: "Zorja checks darkness, clouds and aurora above you, and tells you whether to go out, wait or skip."
            ) {
                EmptyView()
            } actions: {
                ZorjaButton("Get Started", size: .large, fillsWidth: true, action: getStarted)
                Text("Free. No account, no ads, no tracking.")
                    .textStyle(.bodyS)
                    .foregroundStyle(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Figma: Location ask. Names what Zorja does not do, each with a crossed-out icon.
struct LocationAskScreen: View {
    let isReading: Bool
    let useMyLocation: () -> Void
    let choosePlace: () -> Void

    var body: some View {
        FirstLaunchPage(
            headline: Phrase("The Sky Above You.", emphasis: "Above You"),
            lead: "Zorja checks the sky where you are."
        ) {
            PrivacyCard()
                .padding(.top, Space.s48)
        } actions: {
            ZorjaButton("Use My Location", icon: .location, size: .large, fillsWidth: true, action: useMyLocation)
                .disabled(isReading)
            ZorjaButton("Choose A Place Instead", style: .outline, size: .large, fillsWidth: true, action: choosePlace)
                .disabled(isReading)
        }
    }
}

/// Figma: Privacy, the card on the location ask. 300 pt wide, centred, 20 pt corners, with a
/// Title/M heading over the three points.
private struct PrivacyCard: View {
    static let rows: [(ZorjaIcon, String)] = [
        (.locationOff, "Your location is read once when needed, never tracked."),
        (.pinOff, "Zorja sends only a rough area, just to get your forecast."),
        (.accountOff, "No account, no history of where you’ve been."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s24) {
            Text("Location permissions")
                .textStyle(.titleM)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.rows.indices, id: \.self) { index in
                let (icon, text) = Self.rows[index]
                HStack(spacing: Space.s12) {
                    icon.sized(IconSize.regular)
                        .foregroundStyle(.iconSecondary)
                        .accessibilityHidden(true)
                    Text(text)
                        .textStyle(.bodyM)
                        .foregroundStyle(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.s24)
        .frame(maxWidth: 300)
        .zorjaCard()
    }
}

#Preview("Welcome") {
    WelcomeScreen {}
        .background(.bgBase)
        .preferredColorScheme(.dark)
}

#Preview("Location ask") {
    LocationAskScreen(isReading: false, useMyLocation: {}, choosePlace: {})
        .background(.bgBase)
        .preferredColorScheme(.dark)
}
