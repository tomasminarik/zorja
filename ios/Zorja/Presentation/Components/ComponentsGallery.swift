#if DEBUG
import SwiftUI

/// Development copy of the Figma Components page: every component and variant.
/// Not shown in the app.
struct ComponentsGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s48) {
                ComponentsBasicsSheet()
                ComponentsNavigationSheet()
                ComponentsForecastSheet()
                ComponentsContentSheet()
            }
        }
        .background(.bgBase)
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s24) {
            Text(title).textStyle(.titleL).foregroundStyle(.textPrimary)
            content()
        }
        .padding(Space.screenMargin)
        .frame(width: 402, alignment: .leading)
        .background(.bgBase)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).textStyle(.bodyS).foregroundStyle(.textTertiary) }
}

struct ComponentsBasicsSheet: View {
    @State private var empty = ""
    @State private var typed = "Search A Town Or Area"

    var body: some View {
        GallerySection(title: "Basics, actions and inputs") {
            Caption("Chevron · right, left, down, up")
            HStack(spacing: Space.s16) {
                Chevron(direction: .right)
                Chevron(direction: .left)
                Chevron(direction: .down)
                Chevron(direction: .up)
            }
            Caption("Tag · Best, Skip, Clear sky, Offline · Country badge")
            HStack(spacing: Space.s12) {
                ForEach(ZorjaTag.Kind.allCases, id: \.self) { ZorjaTag(kind: $0) }
                CountryBadge(code: "NO")
            }
            Caption("Button · Primary small, large · Secondary small, large · Outline small, large · disabled")
            HStack(spacing: Space.s12) {
                ZorjaButton("Add", icon: .calendarAdd) {}
                ZorjaButton("Add", icon: .calendarAdd, size: .large) {}
            }
            HStack(spacing: Space.s12) {
                ZorjaButton("Add", icon: .calendarAdd, style: .secondary) {}
                ZorjaButton("Add", icon: .calendarAdd, style: .secondary, size: .large) {}
                ZorjaButton("More Tips", style: .secondary) {}
            }
            HStack(spacing: Space.s12) {
                ZorjaButton("Add", icon: .calendarAdd, style: .outline) {}
                ZorjaButton("Add", icon: .calendarAdd, style: .outline, size: .large) {}
                ZorjaButton("Add", icon: .calendarAdd, size: .large) {}.disabled(true)
            }
            ZorjaButton("Use My Location", icon: .location, size: .large, fillsWidth: true) {}
            Caption("Location chip")
            LocationChip(place: "Tromsø") {}
            Caption("Search field · empty, typing")
            SearchField(placeholder: "Search A Town Or Area", text: $empty)
            SearchField(placeholder: "Search A Town Or Area", text: $typed)
        }
    }
}

struct ComponentsNavigationSheet: View {
    var body: some View {
        GallerySection(title: "Navigation") {
            Caption("Header · location, close, back")
            VStack(spacing: Space.s8) {
                ZorjaHeader(kind: .location(place: "Tromsø", openPlaces: {}, openAbout: {}))
                ZorjaHeader(kind: .close {})
                ZorjaHeader(kind: .back {})
            }
            .padding(.horizontal, -Space.screenMargin)
            Caption("Floating menu · Now, Tonight, Tonight with aurora, 3 Nights, 3 Nights with aurora")
            VStack(spacing: Space.s16) {
                FloatingMenu(selection: .constant(.now))
                FloatingMenu(selection: .constant(.tonight))
                FloatingMenu(selection: .constant(.tonight), auroraActive: true)
                FloatingMenu(selection: .constant(.threeNights))
                FloatingMenu(selection: .constant(.threeNights), auroraActive: true)
            }
        }
    }
}

struct ComponentsForecastSheet: View {
    private let slots: [ForecastSlot.Model] = [
        .init(hour: "17", sky: .cloudy), .init(hour: "21", sky: .partlyCloudy),
        .init(hour: "01", sky: .clear, isClear: true), .init(hour: "05", sky: .clear, isClear: true),
        .init(hour: "09", sky: .unknown),
    ]

    var body: some View {
        GallerySection(title: "Forecast") {
            Caption("Sky · Clear, Partly cloudy, Cloudy, Unknown · Storm on")
            HStack(spacing: Space.s24) {
                ForEach(Sky.Kind.allCases, id: \.self) { Sky(kind: $0) }
            }
            HStack(spacing: Space.s24) {
                ForEach([Sky.Kind.clear, .partlyCloudy, .cloudy], id: \.self) { Sky(kind: $0, storm: true) }
            }
            HStack(spacing: Space.s24) {
                ForEach(Sky.Kind.allCases, id: \.self) { Sky(kind: $0, size: 48) }
            }
            Caption("Forecast slot · not clear, clear")
            HStack(spacing: Space.s24) {
                ForecastSlot(model: .init(hour: "17", sky: .cloudy))
                ForecastSlot(model: .init(hour: "17", sky: .clear, isClear: true))
                ForecastSlot(model: .init(hour: "23", sky: .partlyCloudy, storm: true))
            }
            Caption("Section heading · Place line")
            SectionHeading(title: "Next Three Nights", note: "Clear, dark hours decide here. Aurora itself can only be known about 90 minutes ahead.")
            PlaceLine(text: "In Tromsø, aurora shows most clear nights, so tonight depends on cloud.")
            Caption("Night card · Best with Add To Calendar and 6 slots, Skip with 4, south with a storm, midnight sun, checking, no tag")
            NightCard(
                tag: .best, darkSky: "Dark sky 16:42–06:14", day: "Tuesday", date: "10th November",
                sky: .partlyCloudy,
                slots: [.init(hour: "13", sky: .cloudy)] + slots,
                addToCalendar: {}
            )
            NightCard(
                tag: .skip, darkSky: "Dark sky 16:44–06:11", day: "Wednesday", date: "11th November",
                sky: .cloudy, slots: Array(slots.prefix(2)) + [.init(hour: "01", sky: .cloudy), .init(hour: "05", sky: .cloudy)]
            )
            NightCard(
                tag: .clearSky, darkSky: "Dark sky 17:20–05:40", day: "Thursday", date: "12th November",
                sky: .clear, storm: true,
                slots: [
                    .init(hour: "18", sky: .clear, isClear: true), .init(hour: "21", sky: .clear, storm: true, isClear: true),
                    .init(hour: "00", sky: .cloudy, storm: true), .init(hour: "03", sky: .clear, isClear: true),
                    .init(hour: "06", sky: .partlyCloudy),
                ]
            )
            NightCard(tag: .skip, darkSky: "No dark hours", day: "Sunday", date: "21st June")
            NightCard(darkSky: "Checking", day: "Friday", date: "13th November")
            NightCard(darkSky: "Dark sky 16:47–06:05", day: "Saturday", date: "14th November", sky: .cloudy,
                      slots: Array(slots.prefix(4)))
            Caption("Hour mark · Clear, Partly cloudy, Cloudy, Unknown, Twilight · Aurora off, on · Daylight, Loading")
            HourMarkGrid()
            Caption("Hour legend · Activity indicator")
            HourLegend(sky: .cloudy, aurora: true, title: "Aurora Behind Cloud", note: "Aurora is on, but clouds cover it.")
            ActivityIndicator()
        }
    }
}

/// The Figma Hour mark set: one column per variant, rows Regular, Focus and Legend.
struct HourMarkGrid: View {
    private let columns: [(HourMark.Sky, Bool)] = [
        (.clear, false), (.clear, true), (.partlyCloudy, false), (.partlyCloudy, true),
        (.cloudy, false), (.cloudy, true), (.unknown, false), (.unknown, true),
        (.twilight, false), (.twilight, true), (.daylight, false), (.loading, false),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 16, verticalSpacing: 24) {
                ForEach(HourMark.Size.allCases, id: \.self) { size in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            HourMark(sky: columns[index].0, aurora: columns[index].1, size: size)
                        }
                    }
                }
            }
            .padding(Space.s16)
        }
    }
}

struct ComponentsContentSheet: View {
    @State private var openRow = 0
    @State private var checked = true
    @State private var unchecked = false

    var body: some View {
        GallerySection(title: "Content") {
            InfoCard(
                title: "Guidance, Not A Promise",
                message: "Experimental and not scientifically validated. It isn’t a measured chance of seeing aurora."
            )
            Caption("Action card")
            ActionCard(message: "Give Your Eyes 20\u{00A0}Minutes.", buttonTitle: "More Tips") {}
            HStack(alignment: .top, spacing: 12) {
                TipCard(
                    icon: .phone,
                    title: "Red Screen",
                    message: "Red light keeps your eyes used to the dark. Turn it on in iPhone Settings."
                )
                TipCard(icon: .camera, title: "Camera", message: "A phone camera shows more colour than your eyes.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Caption("Place row · selected, default")
            VStack(spacing: 0) {
                PlaceRow(name: "Tromsø", countryCode: "NO", isSelected: true) {}
                PlaceRow(name: "Abisko", countryCode: "SE", isSelected: false) {}
            }
            Caption("Accordion row · closed, open")
            VStack(spacing: 0) {
                AccordionRow(title: "Data Sources", isOpen: .constant(false)) { EmptyView() }
                AccordionRow(title: "Privacy", isOpen: .constant(true)) {
                    Text("Your location is read once and sent as a rough position.")
                        .textStyle(.bodyM).foregroundStyle(.textSecondary)
                }
            }
            Caption("Checklist item · checked, unchecked")
            ChecklistItem(label: "Warm layers, hat and gloves", isChecked: $checked)
            ChecklistItem(label: "Warm layers, hat and gloves", isChecked: $unchecked)
            Caption("Key row · dark sky, clear sky, aurora")
            KeyRow(kind: .darkSky, message: "From the sun’s position, including polar night.")
            KeyRow(kind: .clearSky, message: "From the weather forecast for your exact spot.")
            KeyRow(kind: .aurora, message: "Live aurora data from NOAA for the next hour.")
            Caption("Search result row")
            SearchResultRow(name: "Tromsø", detail: "Troms, Norway") {}
        }
    }
}

#Preview("All components") {
    ComponentsGallery()
        .onAppear { OutfitFont.register() }
}

#Preview("Forecast") {
    ScrollView { ComponentsForecastSheet() }
        .background(.bgBase)
        .onAppear { OutfitFont.register() }
}

#Preview("Tonight strip") {
    VStack(alignment: .leading, spacing: Space.s24) {
        HourMarkGrid()
        HourLegend(sky: .cloudy, aurora: true, title: "Aurora Behind Cloud", note: "Aurora is on, but clouds cover it.")
            .padding(.horizontal, Space.screenMargin)
        ActivityIndicator()
            .padding(.horizontal, Space.screenMargin)
    }
    .frame(maxHeight: .infinity)
    .background(.bgBase)
    .onAppear { OutfitFont.register() }
}

#Preview("Largest accessibility text") {
    ComponentsGallery()
        .onAppear { OutfitFont.register() }
        .dynamicTypeSize(.accessibility3)
}
#endif
