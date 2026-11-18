import SwiftUI

/// The sky for an hour or a night (Figma: Sky). 24 pt in arc hours and forecast slots, 48 pt for
/// a whole night on a Night card. The icons keep their Figma colours: a yellow moon only when
/// clear and dark, grey otherwise.
struct Sky: View {
    enum Kind: Sendable, CaseIterable {
        /// Clear and dark.
        case clear
        /// 30–70 % cloud.
        case partlyCloudy
        /// No clear time.
        case cloudy
        /// Weather not known yet, or out of date: a dashed cloud.
        case unknown

        var label: String {
            switch self {
            case .clear: "Clear"
            case .partlyCloudy: "Partly cloudy"
            case .cloudy: "Cloudy"
            case .unknown: "Weather not known yet"
            }
        }
    }

    let kind: Kind
    /// Adds the aurora mark for a storm forecast to reach the place (southern places only):
    /// magenta when the sky lets you see it, grey behind full cloud. Unknown has no storm mark.
    var storm = false
    var size: CGFloat = IconSize.regular

    var body: some View {
        Image(assetName)
            .resizable()
            // The grey storm mark over a full cloud reaches 1 pt past the 24 pt frame, as in Figma.
            .frame(width: size * assetWidth / IconSize.regular, height: size)
            .frame(width: size, height: size, alignment: .leading)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    var showsStorm: Bool { storm && kind != .unknown }

    var assetName: String {
        let base = switch kind {
        case .clear: "sky-clear"
        case .partlyCloudy: "sky-partly-cloudy"
        case .cloudy: "sky-cloudy"
        case .unknown: "sky-unknown"
        }
        return "Sky/" + base + (showsStorm ? "-storm" : "")
    }

    private var assetWidth: CGFloat { showsStorm && kind == .cloudy ? 25 : 24 }

    private var accessibilityText: String {
        showsStorm ? "\(kind.label), aurora storm forecast" : kind.label
    }
}

/// One forecast slot on a Night card (Figma: Forecast slot): the Sky at that hour over the hour.
/// The hour is yellow only when the slot is fully clear and dark. No Sky in a bright sky; its
/// space is kept so the hours line up.
struct ForecastSlot: View {
    struct Model: Hashable, Sendable {
        var hour: String
        var sky: Sky.Kind?
        var storm = false
        var isClear = false
    }

    let model: Model

    var body: some View {
        VStack(spacing: 5) {
            if let sky = model.sky {
                Sky(kind: sky, storm: model.storm)
            } else {
                Color.clear.frame(width: IconSize.regular, height: IconSize.regular)
            }
            Text(model.hour)
                .textStyle(.labelM)
                .foregroundStyle(model.isClear ? Color.dataClearSky : .textSecondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One night on 3 Nights (Figma: Night card). A `surface/card` card with `radius/card` corners, not tappable. Leave out the
/// night Sky and the slots for nights with no darkness and while checking.
///
/// The top row holds the tag on the left and, on the Best night, Add To Calendar on the right;
/// a card with neither has no top row. "Dark sky" sits under the date.
struct NightCard: View {
    var tag: ZorjaTag.Kind?
    /// "Dark sky HH:MM–HH:MM", or the words for a night without one.
    let darkSky: String
    /// The full weekday.
    let day: String
    /// As "10th November".
    let date: String
    var sky: Sky.Kind?
    var storm = false
    /// 4 to 6 slots from sunset to sunrise; none hides the row.
    var slots: [ForecastSlot.Model] = []
    /// The Best night's Add To Calendar; nil hides the button.
    var addToCalendar: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            if tag != nil || addToCalendar != nil {
                HStack(spacing: Space.s8) {
                    if let tag {
                        ZorjaTag(kind: tag)
                    }
                    Spacer(minLength: 0)
                }
                // The button is laid over the card (below), so it stays its own element for
                // VoiceOver; the row keeps its height.
                .frame(minHeight: addToCalendar == nil ? 18 : AddToCalendarButton.size)
            }
            HStack(alignment: .center, spacing: Space.s8) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(day).textStyle(.titleL).foregroundStyle(.textPrimary)
                    Text(date).textStyle(.labelS).foregroundStyle(.textSecondary)
                    Text(darkSky).textStyle(.bodyXS).foregroundStyle(.textSecondary)
                }
                Spacer(minLength: 0)
                if let sky {
                    Sky(kind: sky, storm: storm, size: 48)
                }
            }
            if !slots.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                        if index > 0 { Spacer(minLength: Space.s4) }
                        ForecastSlot(model: slot)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .padding(Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if let addToCalendar {
                AddToCalendarButton(action: addToCalendar)
                    .padding(Space.s16)
            }
        }
        .zorjaCard()
    }
}

/// The green icon-only Add To Calendar button in the Best night's card (Figma: Night card →
/// Add): 32 pt visible, 44 pt to tap, "Add To Calendar" to VoiceOver.
struct AddToCalendarButton: View {
    static let size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        ZorjaIconButton(icon: .calendarAdd, label: "Add To Calendar", size: Self.size, action: action)
    }
}

/// Heading for the dark part of Tonight and 3 Nights (Figma: Section heading), with the note
/// under it.
struct SectionHeading: View {
    let title: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(title)
                .textStyle(.titleS)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let note {
                Text(note).textStyle(.bodyS).foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// First line of the grey top on Tonight and 3 Nights (Figma: Place line): what decides the
/// night at this place.
struct PlaceLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ZorjaIcon.pin.sized(IconSize.regular)
                .foregroundStyle(.iconPrimary)
                .accessibilityHidden(true)
            Text(text)
                .textStyle(.bodyS)
                .foregroundStyle(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 36)
    }
}
