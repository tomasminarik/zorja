import SwiftUI

/// About (Figma: Screens → About), opened from the header's About icon, with Close.
/// Intro, How It Decides, "Guidance, Not A Promise", then accordions for Data Sources,
/// Privacy and Licences, one open at a time.
struct AboutScreen: View {
    enum Section: String, CaseIterable, Sendable {
        case sources, privacy, licences

        var title: String {
            switch self {
            case .sources: "Data Sources"
            case .privacy: "Privacy"
            case .licences: "Licences"
            }
        }
    }

    let close: () -> Void
    @State private var open: Section?

    init(open: Section? = nil, close: @escaping () -> Void) {
        _open = State(initialValue: open)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            ZorjaHeader(kind: .close(close))
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s24) {
                    VStack(alignment: .leading, spacing: Space.s16) {
                        Text("About Zorja.")
                            .textStyle(.displayL)
                            .foregroundStyle(.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Whether it’s worth going out to see the northern lights, and when. Free, with no ads and no account.")
                            .textStyle(.lead)
                            .foregroundStyle(.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: Space.s12) {
                        Text("How It Decides").textStyle(.titleL).foregroundStyle(.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        KeyRow(kind: .darkSky, message: "From the sun’s position, including polar night.")
                        KeyRow(kind: .clearSky, message: "From the weather forecast for your spot.")
                        KeyRow(kind: .aurora, message: "About 90 minutes ahead, then a general outlook.")
                    }
                    InfoCard(title: "Guidance, Not A Promise",
                             message: "Experimental and not scientifically validated. It isn’t a measured chance of seeing aurora.")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Section.allCases, id: \.self) { section in
                            AccordionRow(title: section.title, isOpen: binding(section)) {
                                content(section)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.screenMargin)
                .padding(.top, Space.s16)
                .padding(.bottom, Space.s32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(.bgBase)
        .tint(.textPrimary)
        .preferredColorScheme(.dark)
    }

    /// One accordion open at a time.
    private func binding(_ section: Section) -> Binding<Bool> {
        Binding(get: { open == section }, set: { open = $0 ? section : nil })
    }

    @ViewBuilder
    private func content(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ForEach(Self.entries(section), id: \.title) { entry in
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(entry.title).textStyle(.titleS).foregroundStyle(.textPrimary)
                    Text(entry.body).textStyle(.bodyM).foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if section == .licences, let licence = Self.fontLicence {
                Text(licence)
                    .textStyle(.bodyS)
                    .foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension AboutScreen {
    struct Entry {
        let title: String
        /// Markdown, for the links.
        let body: AttributedString
    }

    static func entries(_ section: Section) -> [Entry] {
        switch section {
        case .sources: [
            Entry(title: "NOAA Space Weather Prediction Center",
                  body: markdown("Aurora activity and the 3-day outlook.")),
            Entry(title: "MET Norway",
                  body: markdown("Weather forecast, the same source as Yr. Licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)."))
        ]
        case .privacy: [
            Entry(title: "Location",
                  body: markdown("Read once when needed, never in the background. Only a rough position, within about 1 km, is sent to get your forecast.")),
            Entry(title: "What’s Kept",
                  body: markdown("Your saved places stay on your phone. Weather for an area is deleted from Zorja’s server within 6 hours.")),
            Entry(title: "No Tracking",
                  body: markdown("No account, no ads and no analytics."))
        ]
        case .licences: [
            Entry(title: "Outfit",
                  body: markdown("The typeface, by the Outfit Project Authors. Licensed under the [SIL Open Font License 1.1](https://openfontlicense.org), copied in full below."))
        ]
        }
    }

    /// The bundled `OFL.txt`, shipped with the fonts.
    static var fontLicence: String? {
        guard let url = Bundle.main.url(forResource: "OFL", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func markdown(_ text: String) -> AttributedString {
        var string = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        for run in string.runs where run.link != nil {
            string[run.range].underlineStyle = .single
        }
        return string
    }
}

#Preview("About") { AboutScreen {} }
#Preview("About · Data Sources open") { AboutScreen(open: .sources) {} }
#Preview("About · Privacy open") { AboutScreen(open: .privacy) {} }
