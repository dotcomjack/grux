import XCTest
import Foundation
@testable import GruxAgentCore

// Canned-fixture coverage for every adapter's stream parser: the mapped event
// types, chunk-boundary residual handling, and the limit-signal fold (Claude).
// No processes; the parsers are driven directly with fixture text.
final class AdapterParserTests: XCTestCase {

    // Drive a parser with the whole input at once (fixtures end in "\n" so the
    // last line is consumed).
    private func parseAll(_ parser: any AdapterStreamParsing, _ input: String) -> [AdapterEvent] {
        parser.parseChunk(input).events
    }

    // Drive a parser in two chunks split at a byte offset, carrying the residual
    // forward exactly as AgentBridgeRunner's read loop does.
    private func parseSplit(_ parser: any AdapterStreamParsing, _ input: String, at offset: Int) -> [AdapterEvent] {
        let idx = input.index(input.startIndex, offsetBy: offset)
        let (e1, r1) = parser.parseChunk(String(input[..<idx]))
        let (e2, _) = parser.parseChunk(r1 + String(input[idx...]))
        return e1 + e2
    }

    // MARK: - Claude

    func testClaudeParserMapsAllEventTypes() {
        let fixture = [
            #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude-opus-4-8"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"result","subtype":"success","result":"done!","total_cost_usd":0.0123}"#
        ].joined(separator: "\n") + "\n"

        let events = parseAll(ClaudeStreamAdapterParser(), fixture)
        XCTAssertEqual(events.count, 4)
        guard case .systemInit(let sid, let model, _) = events[0] else { return XCTFail("systemInit") }
        XCTAssertEqual(sid, "abc-123")
        XCTAssertEqual(model, "claude-opus-4-8")
        guard case .assistantText(let text, _) = events[1] else { return XCTFail("assistantText") }
        XCTAssertEqual(text, "hello world")
        guard case .toolUse(let name, _, _) = events[2] else { return XCTFail("toolUse") }
        XCTAssertEqual(name, "Bash")
        guard case .finalResult(let rtext, let cost, let ok, _) = events[3] else { return XCTFail("finalResult") }
        XCTAssertEqual(rtext, "done!")
        XCTAssertEqual(cost ?? 0, 0.0123, accuracy: 1e-6)
        XCTAssertTrue(ok)
    }

    func testClaudeParserFoldsLimitSignal() {
        // The real captured 429 limit result line. Parser must emit a
        // .limitSignal alongside the mapped .finalResult.
        let limitLine = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your org's monthly usage limit","total_cost_usd":5.61}"#
        let events = parseAll(ClaudeStreamAdapterParser(), limitLine + "\n")
        XCTAssertEqual(events.count, 2)
        guard case .limitSignal = events[0] else { return XCTFail("expected limitSignal first, got \(events[0])") }
        guard case .finalResult = events[1] else { return XCTFail("expected finalResult second") }
    }

    func testClaudeParserHandlesChunkBoundarySplit() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"chunked text"}]}}"# + "\n"
        // Split in the middle of the JSON line; the event must only surface once
        // the newline arrives, via the residual buffer.
        let parser = ClaudeStreamAdapterParser()
        let idx = line.index(line.startIndex, offsetBy: 30)
        let (e1, r1) = parser.parseChunk(String(line[..<idx]))
        XCTAssertTrue(e1.isEmpty, "no complete line yet")
        let (e2, _) = parser.parseChunk(r1 + String(line[idx...]))
        XCTAssertEqual(e2.count, 1)
        guard case .assistantText(let t, _) = e2[0] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "chunked text")
    }

    // MARK: - Codex

    func testCodexParserMapsDocumentedEvents() {
        let fixture = [
            #"{"type":"session.created","session_id":"s-1","model":"gpt-codex"}"#,
            #"{"type":"agent_message","message":"Here is the plan"}"#,
            #"{"type":"exec_command","command":"ls -la"}"#,
            #"{"type":"command_output","output":"file1\nfile2"}"#,
            #"{"type":"token_count","input_tokens":100,"output_tokens":50}"#,
            #"{"type":"task_complete","last_agent_message":"All done","cost_usd":0.02}"#,
            #"{"weird":"unrecognized"}"#
        ].joined(separator: "\n") + "\n"

        let events = parseAll(CodexStreamAdapterParser(), fixture)
        XCTAssertEqual(events.count, 7)
        guard case .systemInit(let sid, _, _) = events[0] else { return XCTFail("systemInit") }
        XCTAssertEqual(sid, "s-1")
        guard case .assistantText(let t, _) = events[1] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "Here is the plan")
        guard case .toolUse(let name, _, _) = events[2] else { return XCTFail("toolUse") }
        XCTAssertEqual(name, "ls -la")
        guard case .toolResult(let out, _) = events[3] else { return XCTFail("toolResult") }
        XCTAssertTrue(out.contains("file1"))
        guard case .usage(_, let inT, let outT, _) = events[4] else { return XCTFail("usage") }
        XCTAssertEqual(inT, 100)
        XCTAssertEqual(outT, 50)
        guard case .finalResult(let ftext, let cost, let ok, _) = events[5] else { return XCTFail("finalResult") }
        XCTAssertEqual(ftext, "All done")
        XCTAssertEqual(cost ?? 0, 0.02, accuracy: 1e-6)
        XCTAssertTrue(ok)
        guard case .unknown = events[6] else { return XCTFail("unknown") }
    }

    func testCodexParserMapsWrappedItemEvent() {
        let line = #"{"type":"item.completed","item":{"type":"assistant_message","text":"wrapped answer"}}"# + "\n"
        let events = parseAll(CodexStreamAdapterParser(), line)
        XCTAssertEqual(events.count, 1)
        guard case .assistantText(let t, _) = events[0] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "wrapped answer")
    }

    func testCodexParserChunkSplit() {
        let fixture = #"{"type":"agent_message","message":"split me"}"# + "\n"
        let events = parseSplit(CodexStreamAdapterParser(), fixture, at: 20)
        XCTAssertEqual(events.count, 1)
        guard case .assistantText(let t, _) = events[0] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "split me")
    }

    // MARK: - Gemini

    func testGeminiParserMapsDocumentedEvents() {
        let fixture = [
            #"{"type":"content","text":"thinking about it"}"#,
            #"{"type":"tool_call","name":"read_file","args":{"path":"x.txt"}}"#,
            #"{"type":"tool_result","name":"read_file","result":"file contents"}"#,
            #"{"type":"usage","input_tokens":12,"output_tokens":34}"#,
            #"{"type":"result","response":"final answer"}"#
        ].joined(separator: "\n") + "\n"

        let events = parseAll(GeminiStreamAdapterParser(), fixture)
        XCTAssertEqual(events.count, 5)
        guard case .assistantText(let t, _) = events[0] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "thinking about it")
        guard case .toolUse(let name, _, _) = events[1] else { return XCTFail("toolUse") }
        XCTAssertEqual(name, "read_file")
        guard case .toolResult(let out, _) = events[2] else { return XCTFail("toolResult") }
        XCTAssertEqual(out, "file contents")
        guard case .usage(_, let inT, let outT, _) = events[3] else { return XCTFail("usage") }
        XCTAssertEqual(inT, 12)
        XCTAssertEqual(outT, 34)
        guard case .finalResult(let ftext, _, let ok, _) = events[4] else { return XCTFail("finalResult") }
        XCTAssertEqual(ftext, "final answer")
        XCTAssertTrue(ok)
    }

    func testGeminiParserHandlesTerminalSingleObject() {
        // Some versions emit one terminal object with no "type".
        let line = #"{"response":"terminal answer","stats":{"totalTokens":30}}"# + "\n"
        let events = parseAll(GeminiStreamAdapterParser(), line)
        XCTAssertEqual(events.count, 1)
        guard case .finalResult(let text, _, let ok, _) = events[0] else { return XCTFail("finalResult") }
        XCTAssertEqual(text, "terminal answer")
        XCTAssertTrue(ok)
    }

    func testGeminiParserChunkSplit() {
        let fixture = #"{"type":"content","text":"gemini split"}"# + "\n"
        let events = parseSplit(GeminiStreamAdapterParser(), fixture, at: 15)
        XCTAssertEqual(events.count, 1)
        guard case .assistantText(let t, _) = events[0] else { return XCTFail("assistantText") }
        XCTAssertEqual(t, "gemini split")
    }

    // MARK: - Aider (plain text)

    func testAiderParserExtractsSearchReplaceArtifact() {
        let fixture = """
        Here is the change.
        mathweb/flask/app.py
        ```python
        <<<<<<< SEARCH
            return "Hello"
        =======
            return "Hello, World"
        >>>>>>> REPLACE
        ```
        Done.
        """ + "\n"

        let events = parseAll(AiderStreamAdapterParser(), fixture)
        let artifacts = events.compactMap { ev -> (String, String)? in
            if case .fileArtifact(let path, let content, _) = ev { return (path, content) }
            return nil
        }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].0, "mathweb/flask/app.py")
        XCTAssertEqual(artifacts[0].1, "    return \"Hello, World\"")
        // Surrounding prose is preserved as assistant text.
        XCTAssertTrue(events.contains { if case .assistantText(let t, _) = $0 { return t == "Here is the change." }; return false })
    }

    func testAiderParserExtractsUnifiedDiffArtifact() {
        let fixture = """
        Applying edit:
        --- a/src/main.py
        +++ b/src/main.py
        @@ -1,3 +1,3 @@
        -print("old")
        +print("new")
         unchanged line
        End.
        """ + "\n"

        let events = parseAll(AiderStreamAdapterParser(), fixture)
        let artifacts = events.compactMap { ev -> (String, String)? in
            if case .fileArtifact(let path, let content, _) = ev { return (path, content) }
            return nil
        }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].0, "src/main.py")
        XCTAssertEqual(artifacts[0].1, "print(\"new\")")
    }

    func testAiderParserPlainTextIsAssistant() {
        let fixture = "Just a normal sentence.\nAnother line.\n"
        let events = parseAll(AiderStreamAdapterParser(), fixture)
        let texts = events.compactMap { ev -> String? in
            if case .assistantText(let t, _) = ev { return t }
            return nil
        }
        XCTAssertEqual(texts, ["Just a normal sentence.", "Another line."])
        XCTAssertFalse(events.contains { if case .fileArtifact = $0 { return true }; return false })
    }

    func testAiderParserSearchReplaceAcrossChunkBoundary() {
        let fixture = """
        edit incoming
        pkg/util.go
        <<<<<<< SEARCH
        old body
        =======
        new body line 1
        new body line 2
        >>>>>>> REPLACE
        """ + "\n"
        // Split mid-block so the state machine must survive across parseChunk
        // calls (residual carried forward).
        let events = parseSplit(AiderStreamAdapterParser(), fixture, at: 45)
        let artifacts = events.compactMap { ev -> (String, String)? in
            if case .fileArtifact(let path, let content, _) = ev { return (path, content) }
            return nil
        }
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts[0].0, "pkg/util.go")
        XCTAssertEqual(artifacts[0].1, "new body line 1\nnew body line 2")
    }

    // MARK: - AgentBridgeRunner byte splitter (bugs #4 UTF-8 split, #5 residual)

    // The runner buffers raw bytes and only decodes complete newline-terminated
    // blocks, so a chunk boundary that lands in the middle of a multi-byte UTF-8
    // character must NOT drop the chunk (the old String(data:encoding:)-per-chunk
    // path returned nil and dropped it). The character must reassemble exactly.
    func testBridgeSplitterSurvivesUTF8CharSplitAcrossChunks() {
        let line = "héllo→\n"                       // é = 2 bytes, → = 3 bytes
        let bytes = Array(line.utf8)
        // Split at byte offset 2: after 'h' and the first byte of 'é', so the
        // codepoint straddles the boundary.
        let first = Data(bytes[0..<2])
        let second = Data(bytes[2...])

        var buffer = Data()
        let r1 = AgentBridgeRunner.splitCompleteLines(byteBuffer: &buffer, chunk: first)
        XCTAssertNil(r1, "no newline yet, nothing to emit")
        let r2 = AgentBridgeRunner.splitCompleteLines(byteBuffer: &buffer, chunk: second)
        XCTAssertEqual(r2, "héllo→\n", "the multi-byte char must reassemble exactly")
        XCTAssertFalse(r2?.contains("\u{FFFD}") ?? true, "no replacement character, no dropped bytes")
        XCTAssertTrue(buffer.isEmpty, "buffer drained through the trailing newline")
    }

    // A partial line with no newline is carried in the buffer, not emitted, then
    // completed when its newline arrives.
    func testBridgeSplitterCarriesPartialLineUntilNewline() {
        var buffer = Data()
        let r1 = AgentBridgeRunner.splitCompleteLines(byteBuffer: &buffer, chunk: Data("abc".utf8))
        XCTAssertNil(r1)
        XCTAssertEqual(buffer.count, 3)
        let r2 = AgentBridgeRunner.splitCompleteLines(byteBuffer: &buffer, chunk: Data("def\n".utf8))
        XCTAssertEqual(r2, "abcdef\n")
        XCTAssertTrue(buffer.isEmpty)
    }

    // Only bytes through the LAST newline are emitted; the trailing partial line
    // stays buffered (and, being newline-free, is all the next scan inspects).
    func testBridgeSplitterEmitsOnlyThroughLastNewline() {
        var buffer = Data()
        let r = AgentBridgeRunner.splitCompleteLines(byteBuffer: &buffer, chunk: Data("line1\nline2\npart".utf8))
        XCTAssertEqual(r, "line1\nline2\n")
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "part")
    }
}
