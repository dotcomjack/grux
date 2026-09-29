import XCTest
@testable import Grux

final class ChatContextDumpTests: XCTestCase {
    func test_rows_sizeEveryBlockMessagesAndTools() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "abcdef", "cache_control": ["type": "ephemeral"]],
            ["type": "text", "text": "xyz"],
        ]
        let msgs: [[String: Any]] = [["role": "user", "content": "hello"], ["role": "assistant", "content": "hi"]]
        let rows = ChatContextDump.rows(systemBlocks: blocks, messages: msgs, toolsJSONBytes: 100)
        XCTAssertEqual(rows.map(\.name), ["system[0] (cached)", "system[1]", "messages[2]", "tools (json)"])
        XCTAssertEqual(rows.map(\.chars), [6, 3, 7, 100])
    }

    func test_sections_splitOnCapsHeadings() {
        let text = "intro line\nCURRENT STATE\n- a\n- b\nKNOWN PROJECTS\nproj\n"
        let s = ChatContextDump.sections(of: text)
        XCTAssertEqual(s.map(\.name), ["(preamble)", "CURRENT STATE", "KNOWN PROJECTS"])
        XCTAssertEqual(s[1].chars, "- a\n- b\n".count)
    }
}
