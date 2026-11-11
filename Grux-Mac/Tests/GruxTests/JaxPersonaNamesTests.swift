import XCTest
@testable import Grux

// D118: Jax Command's guardrails told every person "Outbound mail is signed as
// Sarah for business" and "The empire's edge stays inside", and every business
// approval card read "AS SARAH" and "Sends as Sarah (assistant)": the owner's
// persona, hard-coded, shown to a stranger whose mail would go out as
// "Assistant" (CommsIdentity.business with an empty roster). Every name these
// surfaces show now comes from the roster the person configured, the same one
// the send path signs with.
final class JaxPersonaNamesTests: XCTestCase {

    private let named = CommsRoster(personalName: "Alex Rivera", assistantName: "Robin")

    // MARK: - The guardrails

    func testAStrangersGuardrailsNameNobody() {
        let text = JaxGuardrailsSection.rules(roster: .empty, canSendMail: true)
            .map { "\($0.title) \($0.detail)" }.joined(separator: "\n")
        XCTAssertFalse(text.contains("Sarah"), text)
        XCTAssertFalse(text.lowercased().contains("empire"), text)
        XCTAssertTrue(text.contains("Business mail is signed by your assistant, personal mail by you."), text)
    }

    func testTheGuardrailsNameTheAssistantThePersonConfigured() {
        let text = JaxGuardrailsSection.rules(roster: named, canSendMail: true).map(\.detail).joined(separator: "\n")
        XCTAssertTrue(text.contains("Business mail is signed as Robin, your assistant, personal mail as you."), text)
        XCTAssertFalse(text.contains("Sarah"), text)
    }

    // D187 item 3 (sense pass 24, `jaxCommand-page1.png`): on a Mac with no Resend
    // key, the one way Grux sends mail (ResendClient refuses without it), the rule
    // said "Business mail is signed by your assistant" as if mail went out. It now
    // says no mail goes out until a key is added, and who signs it then.
    func testTheDisclosureRuleSaysNoMailGoesOutWithoutAMailService() {
        for roster in [CommsRoster.empty, named] {
            let rule = JaxGuardrailsSection.rules(roster: roster, canSendMail: false)
                .first { $0.title == "Always discloses correctly" }
            let who = roster.namesAssistant
                ? "business mail is signed as Robin, your assistant, personal mail as you."
                : "business mail is signed by your assistant, personal mail by you."
            XCTAssertEqual(rule?.detail,
                           "Grux sends no mail until a Resend API key is added in Settings. Then " + who + " It never blurs that line.")
        }
        let withKey = JaxGuardrailsSection.rules(roster: .empty, canSendMail: true)
            .first { $0.title == "Always discloses correctly" }
        XCTAssertEqual(withKey?.detail, "Business mail is signed by your assistant, personal mail by you. It never blurs that line.")
    }

    /// The pane reads the key's presence by attributes only, which raises no
    /// Keychain prompt (D56), and the send path's own gate is that key.
    func testThePaneReadsTheKeyTheSendPathNeeds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Jax/JaxCommandView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("Self.rules(roster: CommsRosterStore.current, canSendMail: KeychainStore.exists(.resendApiKey))"), "the guardrails no longer read the mail key")
        let send = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Email/ResendClient.swift"), encoding: .utf8)
        XCTAssertTrue(send.contains("let key = KeychainStore.get(.resendApiKey)\n        guard !key.isEmpty else { throw ResendError.missingKey }"),
                      "the send path's gate moved; the rule's no-key line may no longer be true")
    }

    // The leak rule says what the gate does: it refuses, it does not queue.
    func testTheLeakRuleSaysItIsRefused() {
        let leak = JaxGuardrailsSection.rules(roster: .empty, canSendMail: false).first { $0.title == "Never leaks the edge" }
        XCTAssertEqual(leak?.detail,
                       "Your documents, files, insights, and trade secrets never go to anyone outside. A send like that is refused, not queued for your OK.")
    }

    // MARK: - The approval cards

    func testABusinessCardForAStrangerNamesTheAssistantItSignsAs() {
        let p = GatePersona.assistant
        XCTAssertEqual(p.displayName(roster: .empty), "Assistant")
        XCTAssertEqual(p.signature(roster: .empty), "Assistant")
        XCTAssertEqual(p.chipLabel(roster: .empty), "AS ASSISTANT")
        // The same name the send path would sign with.
        XCTAssertEqual(CommsRoster.empty.businessName, "Assistant")
    }

    func testABusinessCardNamesTheConfiguredAssistant() {
        let p = GatePersona.assistant
        XCTAssertEqual(p.displayName(roster: named), "Robin (assistant)")
        XCTAssertEqual(p.signature(roster: named), "Robin, assistant")
        XCTAssertEqual(p.chipLabel(roster: named), "AS ROBIN")
        XCTAssertEqual(named.businessName, "Robin")
    }

    func testTheOwnerCardStillSaysYou() {
        XCTAssertEqual(GatePersona.owner.displayName(roster: named), "you")
        XCTAssertEqual(GatePersona.owner.chipLabel(roster: named), "AS YOU")
    }

    // A card queued before the rename (persisted as "sarah") still reads as the
    // assistant, and only the new spelling is written.
    func testTheOldAssistantSpellingStillDecodes() throws {
        let old = try JSONDecoder().decode(GatePersona.self, from: Data("\"sarah\"".utf8))
        XCTAssertEqual(old, .assistant)
        let out = String(data: try JSONEncoder().encode(GatePersona.assistant), encoding: .utf8)
        XCTAssertEqual(out, "\"assistant\"")
    }

    // MARK: - The class guard

    // No string literal in the Jax folder names the owner's persona again.
    // Comments may cite the history; code may not show it.
    func testNoJaxStringLiteralNamesSarahOrTheEmpire() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Jax")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        let literal = try NSRegularExpression(pattern: #""[^"\n]*\b(Sarah|SARAH|[Ee]mpire)\b[^"\n]*""#)
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("*") || code.hasPrefix("///") { continue }
                let r = NSRange(line.startIndex..., in: line)
                if literal.firstMatch(in: line, range: r) != nil {
                    hits.append("\(file.lastPathComponent):\(i + 1): \(code)")
                }
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    // MARK: - Wave 35: what the card's reason says

    // The reason was text baked at queue time ("Sends as Sarah (assistant)"), so a
    // card queued before D118 kept the owner's name beside a chip that no longer
    // did, and a card queued before the person named an assistant kept "Assistant"
    // beside a chip that said the new name. The reason names nobody; the chip and
    // signature lines, drawn from the roster, say who.
    @MainActor func testAnOutboundReasonNamesNobody() throws {
        let mail = ProposedAction(kind: .externalComms, summary: "Email Sam.", target: "sam@example.com",
                                  isExternalComms: true)
        guard case .queueForApproval(let item) = DecisionGate.shared.evaluate(mail) else {
            return XCTFail("an outbound message must queue")
        }
        XCTAssertEqual(item.reason, DecisionGate.outboundReason)
        XCTAssertEqual(DecisionGate.outboundReason, "Outbound message. It goes out only after your approval.")
    }

    func testACardQueuedBeforeTheRenameLosesTheOldName() throws {
        let mail = ProposedAction(kind: .externalComms, summary: "Email Sam.", target: "sam@example.com",
                                  isExternalComms: true)
        for old in ["Outbound message. Sends as Sarah (assistant) only after your approval.",
                    "Outbound message. Sends as Assistant only after your approval.",
                    "Outbound message. Sends as you only after your approval."] {
            let fresh = PendingApproval(action: mail, urgent: true, persona: .assistant, reason: "x")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
            json["reason"] = old
            json["persona"] = "sarah"
            let decoded = try JSONDecoder().decode(PendingApproval.self,
                                                   from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.reason, DecisionGate.outboundReason, old)
            XCTAssertEqual(decoded.persona, .assistant)
        }
        // Any other reason stays as written.
        XCTAssertEqual(DecisionGate.rewordedReason("Spends $50, so it waits."), "Spends $50, so it waits.")
    }

    // The deterministic briefing every keyless stranger hears on a quiet day.
    func testTheQuietFallbackNamesNoEmpire() {
        let line = BriefingEngine.quietFallbackLine
        XCTAssertFalse(line.lowercased().contains("empire"), line)
        XCTAssertEqual(line, "Nothing urgent needs you right now.")
    }
}
