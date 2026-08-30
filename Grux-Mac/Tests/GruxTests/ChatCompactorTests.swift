import XCTest
@testable import Grux

// Pure-helper coverage for ChatCompactor. The summarize() / generateTitle()
// network paths are deliberately not exercised here: those round-trip Haiku and
// aren't safe to run from a unit suite. Everything below stays offline.
//
// The speaker LABELS are owned by ChatCompactor, so these tests pin the shape
// ("<label>: <text>", one distinct label per role, blank-line separated) rather
// than the label text. A test that hardcoded the words would break on a rename
// while telling you nothing about whether rendering still works.
final class ChatCompactorTests: XCTestCase {

    private func msg(_ role: ChatRole, _ content: String) -> ChatMessage {
        ChatMessage(role: role, content: content)
    }

    // "Grux: yo" -> "Grux"
    private func speaker(_ line: String) -> String {
        String(line.prefix(while: { $0 != ":" }))
    }

    // MARK: - renderTranscript

    func test_renderTranscript_labelsBySpeaker() {
        let messages = [
            msg(.user, "hey"),
            msg(.assistant, "yo"),
            msg(.system, "context")
        ]
        let lines = ChatCompactor.renderTranscript(messages: messages)
            .components(separatedBy: "\n\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix(": hey"))
        XCTAssertTrue(lines[1].hasSuffix(": yo"))
        XCTAssertTrue(lines[2].hasSuffix(": context"))

        let labels = lines.map(speaker)
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })      // every role is labeled
        XCTAssertEqual(Set(labels).count, 3)                  // and each role differently
    }

    func test_renderTranscript_separatesWithBlankLines() {
        let messages = [msg(.user, "one"), msg(.assistant, "two")]
        let parts = ChatCompactor.renderTranscript(messages: messages)
            .components(separatedBy: "\n\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasSuffix(": one"))
        XCTAssertTrue(parts[1].hasSuffix(": two"))
        XCTAssertNotEqual(speaker(parts[0]), speaker(parts[1]))
    }

    func test_renderTranscript_emptyInputProducesEmptyString() {
        XCTAssertEqual(ChatCompactor.renderTranscript(messages: []), "")
    }

    // MARK: - buildUserPayload

    func test_buildUserPayload_freshSummaryHasNoPriorBlock() {
        let messages = [msg(.user, "kickoff")]
        let payload = ChatCompactor.buildUserPayload(
            messages: messages,
            priorSummary: nil
        )
        XCTAssertTrue(payload.contains("CHAT TRANSCRIPT"))
        XCTAssertFalse(payload.contains("EXISTING SUMMARY"))
        // The rendered transcript is embedded verbatim.
        XCTAssertTrue(payload.contains(ChatCompactor.renderTranscript(messages: messages)))
    }

    func test_buildUserPayload_emptyPriorSummaryIsTreatedAsAbsent() {
        let payload = ChatCompactor.buildUserPayload(
            messages: [msg(.user, "x")],
            priorSummary: ""
        )
        XCTAssertFalse(payload.contains("EXISTING SUMMARY"))
        XCTAssertTrue(payload.contains("CHAT TRANSCRIPT"))
    }

    func test_buildUserPayload_foldsPriorSummaryWhenPresent() {
        let messages = [msg(.assistant, "next turn")]
        let payload = ChatCompactor.buildUserPayload(
            messages: messages,
            priorSummary: "Agreed to ship X by Friday."
        )
        XCTAssertTrue(payload.contains("EXISTING SUMMARY OF EARLIER TURNS"))
        XCTAssertTrue(payload.contains("Agreed to ship X by Friday."))
        XCTAssertTrue(payload.contains("NEW MESSAGES TO FOLD IN"))
        XCTAssertTrue(payload.contains(ChatCompactor.renderTranscript(messages: messages)))
    }

    // MARK: - buildTitlePayload

    func test_buildTitlePayload_capsAtSixTurns() {
        let messages = (0..<10).map { msg($0.isMultiple(of: 2) ? .user : .assistant, "msg\($0)") }
        let payload = ChatCompactor.buildTitlePayload(messages: messages)
        XCTAssertTrue(payload.contains("msg0"))
        XCTAssertTrue(payload.contains("msg5"))
        XCTAssertFalse(payload.contains("msg6"))
        XCTAssertFalse(payload.contains("msg9"))
    }

    func test_buildTitlePayload_singleNewlineSeparated() {
        let payload = ChatCompactor.buildTitlePayload(messages: [
            msg(.user, "a"),
            msg(.assistant, "b")
        ])
        let lines = payload
            .replacingOccurrences(of: "CHAT:\n", with: "")
            .replacingOccurrences(of: "\n\nTitle:", with: "")
            .components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)          // single newline between turns, not a blank line
        XCTAssertTrue(lines[0].hasSuffix(": a"))
        XCTAssertTrue(lines[1].hasSuffix(": b"))
        XCTAssertNotEqual(speaker(lines[0]), speaker(lines[1]))
    }

    // MARK: - cleanTitle

    func test_cleanTitle_trimsWhitespace() {
        XCTAssertEqual(ChatCompactor.cleanTitle("   shipping plan   "), "shipping plan")
    }

    func test_cleanTitle_stripsDoubleAndSingleQuotes() {
        XCTAssertEqual(ChatCompactor.cleanTitle("\"shipping plan\""), "shipping plan")
        XCTAssertEqual(ChatCompactor.cleanTitle("'shipping plan'"), "shipping plan")
    }

    func test_cleanTitle_dropsTrailingPeriod() {
        XCTAssertEqual(ChatCompactor.cleanTitle("shipping plan."), "shipping plan")
    }

    func test_cleanTitle_capsAtSixtyChars() {
        let long = String(repeating: "a", count: 200)
        let cleaned = ChatCompactor.cleanTitle(long)
        XCTAssertNotNil(cleaned)
        XCTAssertEqual(cleaned!.count, 60)
    }

    func test_cleanTitle_returnsNilForEmpty() {
        XCTAssertNil(ChatCompactor.cleanTitle(""))
        XCTAssertNil(ChatCompactor.cleanTitle("   "))
        XCTAssertNil(ChatCompactor.cleanTitle("\"\""))
    }

    // MARK: - preferredSummarizerModel

    func test_preferredSummarizerModel_keepsHaikuVariants() {
        XCTAssertEqual(
            ChatCompactor.preferredSummarizerModel(default: "claude-haiku-4-5-20251001"),
            "claude-haiku-4-5-20251001"
        )
        XCTAssertEqual(
            ChatCompactor.preferredSummarizerModel(default: "claude-haiku-3-5-20250101"),
            "claude-haiku-3-5-20250101"
        )
    }

    func test_preferredSummarizerModel_downshiftsSonnetAndOpus() {
        XCTAssertEqual(
            ChatCompactor.preferredSummarizerModel(default: "claude-sonnet-4-5"),
            "claude-haiku-4-5-20251001"
        )
        XCTAssertEqual(
            ChatCompactor.preferredSummarizerModel(default: "claude-opus-4-7"),
            "claude-haiku-4-5-20251001"
        )
    }
}
