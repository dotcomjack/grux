import XCTest
@testable import Grux

/// D170 item 3 (sense pass 21, `focus-1.png`): Focus log's card offered a live
/// Review on "Review the first capture" while Screen Recording, listed above
/// it, was not allowed. The step cannot run before that permission
/// (`SetupOrder.prerequisites`), so pressing it opened a sheet that could only
/// say to grant Screen Recording first.
@MainActor
final class SetupCardWaitsOnPrerequisiteTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func test_aStepWaitsWhileItsPrerequisiteIsMissing() {
        XCTAssertEqual(CapabilitySetupCard.waitsOn(.stepFirstFrameReviewed,
                                                   missing: [.permScreenRecording, .stepFirstFrameReviewed]),
                       .permScreenRecording)
        let line = CapabilitySetupCard.waitingLine(.permScreenRecording)
        XCTAssertEqual(line, "Comes after \(SetupRequirement.permScreenRecording.label) above.")
    }

    /// Granted: the step is live again, and a requirement with no prerequisite never waits.
    func test_nothingWaitsOnceThePrerequisiteIsDone() {
        XCTAssertNil(CapabilitySetupCard.waitsOn(.stepFirstFrameReviewed, missing: [.stepFirstFrameReviewed]))
        XCTAssertNil(CapabilitySetupCard.waitsOn(.stepFirstFrameReviewed, missing: []))
        XCTAssertNil(CapabilitySetupCard.waitsOn(.stepCaptureExclusionsConfirmed,
                                                 missing: [.permScreenRecording, .stepCaptureExclusionsConfirmed]))
        XCTAssertNil(CapabilitySetupCard.waitsOn(.keyAnthropic, missing: [.permScreenRecording, .keyAnthropic]))
    }

    /// The button on screen goes through the rule: disabled, and the line says why.
    func test_theCardButtonReadsTheRule() throws {
        let card = try source("Sources/Grux/Onboarding/CapabilitySetupCard.swift")
        guard let at = card.range(of: "private func requirementButton(") else {
            return XCTFail("requirementButton moved; point this test at it")
        }
        let body = String(card[at.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains(".disabled(Self.waitsOn(requirement, missing: missing) != nil)"), body)
        guard let b = card.range(of: "private func requirementBody(") else {
            return XCTFail("requirementBody moved; point this test at it")
        }
        let rowBody = String(card[b.lowerBound...].prefix(2400))
        XCTAssertTrue(rowBody.contains("Self.waitingLine("), "no line says what the step waits on")
    }
}
