import SwiftUI

/// The one place a `Link` gets its colour.
///
/// ## The bug
///
/// SwiftUI's `Link` paints its label with `NSColor.linkColor`, which is the
/// SYSTEM BLUE, and it does not follow `.tint`. Grux is violet on near black, so
/// every unstyled `Link` in the app rendered as the only blue pixels on the
/// screen.
///
/// Re-measured 2026-08-23, because the first count in this comment was wrong in
/// every number it gave. `Sources/` holds 3 real `Link` uses. Two of them set no
/// foreground style at all: the onboarding model key step, which is the single
/// screen where a stranger is asked to paste a credential and therefore the
/// worst possible place to look like a different application, and the Brave key
/// row in Settings, which is the same errand one screen further on.
///
/// The original sentence claimed nine of ten, and attributed most of those to
/// `HomeView`. `HomeView`'s six are `CardLink`, an ordinary local type whose name merely
/// ends in Link, and `LinkStylingTests.unstyledLinks` excludes it deliberately:
/// a naive substring search reports nine offenders where there are two. A wrong
/// measurement in a doc comment is not cosmetic, because it is the entire
/// justification for the modifier below, and the next reader reconciling it
/// against the test file (whose header says two) goes hunting for seven links
/// that do not exist. `LinkStylingTests` now checks this paragraph against the
/// same detector it sweeps with, so the sentence cannot drift again.
///
/// It survived because it is invisible to every check that existed. It is not a
/// crash, not a layout break, not a failing assertion, and a reader of the
/// source sees `Link("Get a key", destination:)` and nothing looks wrong. Only a
/// rendered screenshot shows it, and the three onboarding steps that carry it
/// were `private`, so the render harness could not reach them.
///
/// ## Why a modifier rather than a wrapper view
///
/// `Link` has behaviour worth keeping: it opens with the user's default handler
/// and carries the right accessibility traits. Wrapping it in a `Button` to
/// restyle it would trade that away for a colour. This changes only the colour.
///
/// `accentPrimaryLight` rather than `accentPrimary`, and the numbers are the
/// reason: on the canonical base `#0A0A0C`, `#7B61FF` measures 4.71:1 and
/// `#C8B6FF` measures 10.92:1. Both pass AA for body text, but a link is the
/// element a reader has to pick out of a paragraph, so it takes the higher one.
extension View {
    /// Paints a `Link` in the Grux accent instead of the system link blue.
    func gruxLink() -> some View {
        foregroundStyle(GruxTheme.accentPrimaryLight)
    }
}
