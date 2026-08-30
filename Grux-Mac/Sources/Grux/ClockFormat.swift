import Foundation

/// Clock times rendered the way a US reader expects them: `11 PM`, never `23:00`.
///
/// This exists as ONE function rather than as string interpolation at the call
/// site, because the bug it fixes is the kind that spreads. The Settings
/// "Active hours" rows shipped `Text("End: \(Int(activeEnd)):00")`, which put
/// `End: 23:00` on screen for every user. Nothing caught it: it is not a dash,
/// not a name, not a brand, so no guard in this repo was looking, and a
/// reviewer reading `\(hour):00` sees a correct interpolation rather than a
/// convention violation.
///
/// The storage stays a 24-hour `Int`, which is correct. Only the display
/// converts, and it converts in exactly one place.
enum ClockFormat {

    /// Whole-hour label for an hour in `0...24`.
    ///
    /// `24` is deliberately accepted rather than clamped: the "Active hours"
    /// end slider ranges `1...24`, where 24 means midnight at the end of the
    /// day, and it has to render as `12 AM` rather than as a broken value.
    /// Anything outside the range wraps rather than trapping, because a label
    /// is never worth a crash.
    static func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let period = h < 12 ? "AM" : "PM"
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display) \(period)"
    }
}
