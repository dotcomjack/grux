import XCTest
@testable import Grux

/// A tab is opened by the words, not by the punctuation Whisper chose for them.
///
/// Measured 2026-09-27 on the loop Mini, audio path (`say -o`, `grux transcribe`,
/// inject): "open Self-Upgrade" came back "Open self upgrade." and "open Jax HQ" came
/// back "Open JaxHQ.", and both were judged not_a_command, because the on-device matcher
/// compared raw substrings and "self-upgrade" is not inside "self upgrade". A spoken
/// label has no hyphen and no fixed spacing, so neither may decide the match.
@MainActor
final class VoiceHeardSpellingTests: XCTestCase {

    private func router() -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [] })
        r.recentReply = { nil }
        return r
    }

    /// Every sidebar tab, written three ways Whisper writes a label.
    func test_everyTabOpensHoweverWhisperSpelledIt() async {
        var misses: [String] = []
        for item in SidebarIA.groups.flatMap(\.items) {
            let label = item.label
            let variants = Set([
                "Open \(label).",
                "Open \(label.replacingOccurrences(of: "-", with: " ").lowercased()).",
                "Open \(label.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")).",
            ])
            for heard in variants {
                let r = router()
                var opened: String?
                r.navigate = { opened = $0 }
                let e = await r.consider(chunk: heard)
                if e?.outcome != .executed || opened != item.key {
                    misses.append("'\(heard)' -> \(e?.commandId ?? "nil") \(e.map { "\($0.outcome)" } ?? "")")
                }
            }
        }
        XCTAssertEqual(misses, [], "tabs Whisper's spelling kept from opening")
    }

    /// Loosening punctuation must not loosen what counts as a command.
    func test_labelsInConversationStillDoNothing() async {
        for heard in ["we opened the self upgrade door at the office",
                      "yeah Sam said the jaxhq thing from last week was kind of a mess honestly",
                      "I will reopen chattering later"] {
            let r = router()
            var opened: String?
            r.navigate = { opened = $0 }
            let e = await r.consider(chunk: heard)
            XCTAssertNotEqual(e?.outcome, .executed, heard)
            XCTAssertNil(opened, heard)
        }
    }
}
