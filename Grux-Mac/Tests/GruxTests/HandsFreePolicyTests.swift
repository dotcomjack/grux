import XCTest
@testable import Grux

final class HandsFreePolicyTests: XCTestCase {
    func test_shellStepsAreNever() {
        XCTAssertEqual(HandsFreePolicy.classify(action: .runShell(command: "ls")), .never)
        XCTAssertEqual(HandsFreePolicy.classify(action: .runInTerminalCell(row: 0, col: 0, command: "ls")), .never)
        XCTAssertEqual(HandsFreePolicy.classify(action: .runAppleScript(source: "tell app \"Finder\" to quit")), .never)
        XCTAssertEqual(HandsFreePolicy.classify(action: .speakShellOutput(setup: "date", template: "$out")), .never)
    }

    func test_reversibleStepsAreOnTheSpot() {
        XCTAssertEqual(HandsFreePolicy.classify(action: .launchApp(name: "Calendar")), .onTheSpot)
        XCTAssertEqual(HandsFreePolicy.classify(action: .playMusic(song: "x", artist: "y")), .onTheSpot)
        XCTAssertEqual(HandsFreePolicy.classify(action: .speak(text: "hi")), .onTheSpot)
        XCTAssertEqual(HandsFreePolicy.classify(action: .openURL(url: "https://example.com")), .onTheSpot)
    }

    func test_macroInheritsItsStrictestStep() {
        let m = Macro(name: "m", triggers: ["do it"], description: "", rawActions: [.launchApp(name: "Notes"), .runShell(command: "rm x")])
        XCTAssertEqual(HandsFreePolicy.classify(macro: m), .never)
    }
}
