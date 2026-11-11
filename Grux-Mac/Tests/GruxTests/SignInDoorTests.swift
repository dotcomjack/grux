import XCTest
@testable import Grux
import GruxSetupCore

/// Wave 28: `grux next` sends a person with an expired Claude sign-in to
/// `grux open agents`. The name must open a real surface, or the answer is a dead end.
@MainActor
final class SignInDoorTests: XCTestCase {
    func test_theCommandNextPrintsOpensARealSurface() throws {
        let command = ClaudeSignIn.nextAnswer(blocking: ["Agents"], list: { $0.joined() }).command
        let surface = try XCTUnwrap(command.split(separator: " ").last.map(String.init))
        XCTAssertTrue(command.hasPrefix("grux open "))
        XCTAssertEqual(GruxControlTools.resolveSurface(surface)?.key, "agents")
    }
}
