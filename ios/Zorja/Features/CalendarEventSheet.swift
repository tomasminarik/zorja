import EventKit
import EventKitUI
import SwiftUI

/// Add To Calendar: the system's own event sheet, filled in from the draft. The person
/// chooses the calendar and saves or cancels there.
///
/// Since iOS 17 this sheet runs outside the app and needs no calendar permission, so Zorja
/// never asks for calendar access and never reads the calendar. Nothing happens until Add is
/// tapped (decision of 2026-11-06).
struct CalendarEventSheet: UIViewControllerRepresentable {
    let draft: CalendarEventDraft
    let dismiss: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = draft.event(in: store)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}

extension CalendarEventDraft: Identifiable {
    var id: Date { start }

    /// The event as App copy describes it: title, the clear dark window, the place and the note.
    func event(in store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = Self.title
        event.startDate = start
        event.endDate = end
        event.timeZone = timeZone
        event.location = location
        event.notes = Self.notes
        return event
    }
}
