import XCTest
import AppKit
@testable import Grux

/// D170 item 1: the Telegram chat id field cut its prompt to "the chat or
/// channel the alerts g". The field is 200 points wide (CapabilityCredentialsSection)
/// and a rounded border takes about 12 of them, so every companion prompt is
/// measured at the field's own system font.
@MainActor
final class CompanionPlaceholderFitsTests: XCTestCase {
    func test_everyCompanionPromptFitsItsField() throws {
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Settings/CapabilityCredentialsSection.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains(".frame(maxWidth: 200)"), "the field width this test measures against moved")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var seen = 0
        for req in SetupRequirement.allCases {
            guard let companion = CapabilityResolver.companion(for: req) else { continue }
            seen += 1
            let width = (companion.placeholder as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, 200 - 12, "\(req): \"\(companion.placeholder)\" is \(Int(width)) pt")
        }
        XCTAssertGreaterThan(seen, 0)
    }
}
