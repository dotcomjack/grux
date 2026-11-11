import Foundation

/// D192 (4): how long ago (or how soon), said one way in every pane. Notes read
/// "1mo ago" beside Jax HQ's "1 mo. ago" for the same age, because each pane built
/// its own RelativeDateTimeFormatter in its own style. The abbreviated style is the
/// one the hand-written labels already use ("5m ago", "3d ago"), so it is this one.
/// `RelativeStampOneStyleTests` fails if a pane builds its own formatter again.
enum RelativeStamp {
    static func string(for date: Date, relativeTo now: Date = Date(), calendar: Calendar? = nil) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        if let calendar {
            f.calendar = calendar
            f.locale = calendar.locale ?? .current
        }
        return f.localizedString(for: date, relativeTo: now)
    }
}
