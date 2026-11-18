import SwiftUI

/// The 3 Nights screen (Figma: Screens → Tonight and 3 Nights, and the 3 Nights frames of
/// Forecast and App states).
///
/// A top under the header with the place line (and the Offline tag when offline), which stays
/// put on the background while the rest scrolls under it, then "Next Three Nights" with its
/// note 24 pt below it, and the Night cards 20 pt under the heading, 12 pt apart. Cards aren't
/// tappable; the Best night's card holds Add To Calendar.
struct ThreeNightsScreen: View {
    let state: ThreeNightsState
    let status: StatusLine?
    var addToCalendar: (CalendarEventDraft) -> Void = { _ in }

    static func showsTop(_ state: ThreeNightsState, status: StatusLine?) -> Bool {
        if case .offline = status { return true }
        return state.placeLine != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    if let note = state.note {
                        SectionHeading(title: ThreeNightsState.title, note: note)
                    } else {
                        SectionHeading(title: ThreeNightsState.title)
                    }
                }
                .riseIn(1)
                VStack(spacing: 12) {
                    ForEach(Array(state.nights.enumerated()), id: \.element.id) { index, night in
                        NightCard(tag: night.tag, darkSky: night.darkSky, day: night.day, date: night.date,
                                  sky: night.sky, storm: night.storm, slots: night.slots,
                                  addToCalendar: night.calendar.map { draft in { addToCalendar(draft) } })
                            .riseIn(2 + index)
                    }
                }
            }
            .padding(.horizontal, Space.screenMargin)
            .padding(.top, Space.s24)
            .padding(.bottom, Space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The top stays put on the background and the cards scroll under it and the header.
        .scrollsUnderHeader {
            if Self.showsTop(state, status: status) {
                top
            }
        }
        .scrollsUnderMenu()
    }

    /// Figma: Hero. 16 pt under the header, 30 pt between the Offline line and the place line,
    /// 28 pt at the bottom.
    private var top: some View {
        VStack(alignment: .leading, spacing: 30) {
            if case .offline = status, let status {
                OfflineStatus(status: status)
            }
            if let placeLine = state.placeLine {
                PlaceLine(text: placeLine)
            }
        }
        .riseIn(0)
        .padding(.horizontal, Space.screenMargin)
        .padding(.top, Space.s16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The red Offline tag and "Updated HH:MM" above a headline.
struct OfflineStatus: View {
    let status: StatusLine

    var body: some View {
        HStack(spacing: Space.s8) {
            ZorjaTag(kind: .offline)
            Text(status.text).textStyle(.bodyS).foregroundStyle(.textTertiary)
        }
        .frame(height: 18)
    }
}
