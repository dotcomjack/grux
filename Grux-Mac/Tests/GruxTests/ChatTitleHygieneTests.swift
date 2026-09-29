import XCTest
@testable import Grux

final class ChatTitleHygieneTests: XCTestCase {

    /// The exact titles measured on the running app on 2026-09-20.
    func test_theTitlesThatActuallyShippedAreRejected() {
        XCTAssertFalse(ChatTitleHygiene.isFitToShow("big teets and http 400"))
        // The other half of this fix is what stops a title like this being
        // generated at all: notices never reach the title generator. The word
        // on its own is not a status code, so the hygiene check allows it
        // rather than guessing at which English words describe a failure.
        XCTAssertTrue(ChatTitleHygiene.isFitToShow("malformed conversation"))
    }

    func test_aStatusCodeIsNeverFitToShow() {
        for bad in ["Malformed conversation (HTTP 400)", "429 rate limited", "Error: 500",
                    "HTTP 401", "status 503", "500 error", "timeout 408"] {
            XCTAssertFalse(ChatTitleHygiene.isFitToShow(bad), "\(bad) was allowed through")
        }
    }

    /// A number is not a status code just because it has three digits.
    func test_anOrdinaryTitleWithANumberSurvives() {
        for good in ["Filament order for the printer", "Plan for the 400 unit run",
                     "Pricing at $400", "The 500 mile drive"] {
            XCTAssertTrue(ChatTitleHygiene.isFitToShow(good), "\(good) was rejected")
        }
    }

    func test_aRejectedTitleFallsBackToWhatThePersonSaid() {
        let out = ChatTitleHygiene.clean(generated: "Malformed conversation (HTTP 400)",
                                         firstUserLine: "can you look at the filament order")
        XCTAssertEqual(out, "Can you look at the filament order")
    }

    func test_withNothingToFallBackOnItStaysTheNeutralDefault() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "HTTP 500", firstUserLine: ""),
                       ChatTitleHygiene.neutralDefault)
    }

    /// A fallback that is itself an error is not an improvement.
    func test_anUnfitFallbackIsNotUsedEither() {
        XCTAssertEqual(ChatTitleHygiene.clean(generated: "HTTP 500", firstUserLine: "why the http 400"),
                       ChatTitleHygiene.neutralDefault)
    }

    func test_aLongFallbackIsTrimmedToSomethingThatFitsARail() {
        let long = String(repeating: "a very long opening line ", count: 8)
        let out = ChatTitleHygiene.clean(generated: "HTTP 500", firstUserLine: long)
        XCTAssertLessThanOrEqual(out.count, ChatTitleHygiene.maxLength)
        XCTAssertTrue(out.hasSuffix("..."))
    }

    func test_cleanNeverReturnsSomethingUnfit() {
        for generated in ["HTTP 400", "429 rate limited", "fine title"] {
            for first in ["", "http 500 again", "an ordinary question"] {
                let out = ChatTitleHygiene.clean(generated: generated, firstUserLine: first)
                XCTAssertTrue(ChatTitleHygiene.isFitToShow(out) || out == ChatTitleHygiene.neutralDefault,
                              "clean(\(generated), \(first)) returned \(out)")
            }
        }
    }
}

/// The other half: notices never reach the title generator, and the result is
/// checked before it is shown. A source contract, because the generator itself
/// makes a model call and a test must not.
final class ChatTitleWiringTests: XCTestCase {
    private func appState() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/AppState.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(t.count, 500, "AppState did not load")
        return t
    }

    func test_theTitleGeneratorIsHandedOnlyWhatThePersonCanSee() throws {
        let t = try appState()
        XCTAssertTrue(t.contains("let visible = thread.messages.filter { !$0.isNotice }"),
                      "notices reach the title generator again")
        XCTAssertFalse(t.contains("messages: thread.messages,"),
                       "the generator is handed the raw thread, notices included")
    }

    func test_whateverComesBackIsCheckedBeforeItIsShown() throws {
        let t = try appState()
        XCTAssertTrue(t.contains("ChatTitleHygiene.clean(generated: title"),
                      "a generated title is shown without being checked")
    }
}
