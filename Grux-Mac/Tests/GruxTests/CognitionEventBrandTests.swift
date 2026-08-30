import XCTest
@testable import Grux

// Covers the brand + correlationId fields added for the Cognition Map brand
// filter and the Jax HQ "Why this draft?" deep-link (approved UI/UX decision 4):
// they must round-trip and older logs (without the fields) must still decode.
final class CognitionEventBrandTests: XCTestCase {

    func testBrandAndCorrelationRoundTrip() throws {
        let event = CognitionEvent(
            kind: .task,
            trigger: "support email: order status",
            mode: "simulate",
            outcome: "Drafted an acme reply",
            brand: "acme",
            correlationId: "acme:abc123"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CognitionEvent.self, from: data)
        XCTAssertEqual(decoded.brand, "acme")
        XCTAssertEqual(decoded.correlationId, "acme:abc123")
        XCTAssertEqual(decoded.id, event.id)
    }

    func testDefaultsAreNil() {
        let event = CognitionEvent(kind: .prompt, trigger: "hi", mode: "simulate", outcome: "ok")
        XCTAssertNil(event.brand)
        XCTAssertNil(event.correlationId)
    }

    // A log written by the pre-decision-4 build has neither key. It must decode
    // to nil rather than throwing and wiping the whole log.
    func testLegacyEventDecodesWithoutBrandKeys() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "timestamp": 760000000,
          "kind": "prompt",
          "trigger": "old decision",
          "heuristicsFired": [],
          "memoriesRetrieved": [],
          "gateVerdict": "",
          "gateReason": "",
          "mode": "simulate",
          "outcome": "did a thing",
          "durationSeconds": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CognitionEvent.self, from: legacy)
        XCTAssertEqual(decoded.trigger, "old decision")
        XCTAssertNil(decoded.brand)
        XCTAssertNil(decoded.correlationId)
    }
}
