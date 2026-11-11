import XCTest
@testable import Grux

private func macSource(_ rel: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}

/// D199 (sense pass 28, `approvals-page1.png`): Settings, Persistent memory read
/// "No data leaves your Mac." with chat able to run on a Claude key, while each
/// chat turn sends the memories that best match the message to the chat model.
final class MemoryPrivacyCaptionTests: XCTestCase {

    private let kept = "Grux keeps memories on this Mac and finds them with Apple's on-device embeddings."

    func testOnThisMacTheMemoriesStayHere() {
        XCTAssertEqual(MemoryPrivacyCaption.line(route: .thisMac(model: "Grux Local 2B"), memoryMirrorHost: nil, memoryOn: true),
                       kept + " Each chat turn gives the few that best match your message to Grux Local 2B on this Mac, so they stay here.")
    }

    func testACloudOrOtherMachineRouteSaysTheyLeave() {
        XCTAssertEqual(MemoryPrivacyCaption.line(route: .anthropic, memoryMirrorHost: nil, memoryOn: true),
                       kept + " Each chat turn sends the few that best match your message to Anthropic with it, so those leave this Mac.")
        XCTAssertEqual(MemoryPrivacyCaption.line(route: .custom(name: "OpenRouter", host: "openrouter.ai"), memoryMirrorHost: nil, memoryOn: true),
                       kept + " Each chat turn sends the few that best match your message to OpenRouter (openrouter.ai) with it, so those leave this Mac.")
        XCTAssertEqual(MemoryPrivacyCaption.line(route: .otherMachine(model: "Qwen 3.5 4B", host: "studio.local"), memoryMirrorHost: nil, memoryOn: true),
                       kept + " Each chat turn sends the few that best match your message to Qwen 3.5 4B on studio.local, so those leave this Mac for that machine.")
    }

    func testNoModelSaysWhatHappensOnceThereIsOne() {
        XCTAssertEqual(MemoryPrivacyCaption.line(route: .none(step: "Connect a model."), memoryMirrorHost: nil, memoryOn: true),
                       kept + " Chat has no model yet; once it has one, each turn gives that model the few that best match your message.")
    }

    /// A mirror is named on every route, the local one included.
    func testAMirrorIsNamed() {
        let mirror = " Grux also copies memories to mini.example.net, where memory searches go too."
        for route: PrivacyAsk.Route in [.anthropic, .none(step: nil)] {
            let line = MemoryPrivacyCaption.line(route: route, memoryMirrorHost: "mini.example.net", memoryOn: true)
            XCTAssertTrue(line.hasSuffix(mirror), line)
            XCTAssertEqual(line, MemoryPrivacyCaption.line(route: route, memoryMirrorHost: nil, memoryOn: true) + mirror)
        }
    }

    /// W69-FIX round 1: with a mirror the memories do not "stay here", even when
    /// chat runs on this Mac.
    func testAMirrorOnThisMacDoesNotSayTheyStay() {
        let line = MemoryPrivacyCaption.line(route: .thisMac(model: "Grux Local 2B"), memoryMirrorHost: "mini.example.net", memoryOn: true)
        XCTAssertEqual(line, kept + " Each chat turn gives the few that best match your message to Grux Local 2B on this Mac."
                       + " Grux also copies memories to mini.example.net, where memory searches go too.")
        XCTAssertFalse(line.contains("stay here"), line)
    }

    /// W69-FIX rounds 2 and 3: memory off stops only RELEVANT_MEMORIES. Long
    /// term facts and slang, the remember-this inbox, recent ambient memories,
    /// person cards, Focus lines and the memory tools still reach the chat
    /// model (`ChatService`), so the line says what stops, names examples of
    /// the rest as examples, and never claims chat looks nothing up.
    func testMemoryOffSaysWhatStopsAndWhatStillGoes() {
        let off = " Memory is off, so chat stops adding the memories that best match your message. Other things Grux keeps about you, such as facts you told it to remember and what Ambient heard lately, can still go with a turn"
        let cases: [(PrivacyAsk.Route, String)] = [
            (.thisMac(model: "M"), ", to M on this Mac."),
            (.otherMachine(model: "M", host: "h"), ", to M on h, off this Mac."),
            (.anthropic, ", to Anthropic, off this Mac."),
            (.custom(name: "N", host: "h"), ", to N (h), off this Mac."),
            (.none(step: nil), "."),
        ]
        for (route, tail) in cases {
            let line = MemoryPrivacyCaption.line(route: route, memoryMirrorHost: nil, memoryOn: false)
            XCTAssertEqual(line, kept + off + tail)
            XCTAssertEqual(MemoryPrivacyCaption.line(route: route, memoryMirrorHost: "m.example", memoryOn: false),
                           kept + off + tail + " Grux also copies memories to m.example, where memory searches go too.")
            XCTAssertFalse(line.contains("no chat turn carries"), line)
            XCTAssertFalse(line.contains("does not look up"), line)
        }
    }

    /// No setup reads as nothing leaving the Mac unless the route is this Mac
    /// with no mirror.
    func testNoLineClaimsNothingLeaves() {
        for route: PrivacyAsk.Route in [.thisMac(model: "M"), .otherMachine(model: "M", host: "h"), .anthropic,
                                        .custom(name: "N", host: "h"), .none(step: nil)] {
            for host in [nil, "h.example"] {
                let line = MemoryPrivacyCaption.line(route: route, memoryMirrorHost: host, memoryOn: true)
                XCTAssertFalse(line.contains("No data leaves"), line)
                XCTAssertFalse(line.contains("NLEmbedding"), line)
            }
        }
    }

    /// The Settings section reads the caption from the live route, not a string.
    func testSettingsReadsTheCaption() throws {
        let s = try macSource("Sources/Grux/SettingsView.swift")
        XCTAssertFalse(s.contains("No data leaves your Mac"))
        XCTAssertTrue(s.contains("MemoryPrivacyCaption.line(route: PrivacyAsk.routes(state: state).route, memoryMirrorHost: PrivacyAsk.mirrorHost(), memoryOn: state.config.memoryEnabled)"))
    }
}
