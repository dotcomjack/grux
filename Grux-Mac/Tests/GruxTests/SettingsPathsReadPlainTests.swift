import XCTest
@testable import Grux

/// D166 item 13 (sense pass 20): Settings, Sessions showed the agent CLI as
/// "/Users/someone/.nvm/versions/node/v24.14.0/bin/claude", a path with the Mac's
/// user name in it; Backup's Restore said "Pick a grux-backup-*.zip" and
/// "validates its manifest". Both name the thing in words a person uses; the
/// full path stays in the row's hover.
@MainActor
final class SettingsPathsReadPlainTests: XCTestCase {

    func test_theAgentCLIRowNamesTheProgramNotItsPath() {
        XCTAssertEqual(TerminalSessionsSettingsView.agentCLIName("/Users/someone/.nvm/versions/node/v24.14.0/bin/claude"),
                       "Claude Code")
        XCTAssertEqual(TerminalSessionsSettingsView.agentCLIName("/opt/homebrew/bin/claude"), "Claude Code")
        XCTAssertEqual(TerminalSessionsSettingsView.agentCLIName(nil), "Not found")
        for path in ["/Users/someone/.nvm/versions/node/v24.14.0/bin/claude", "/usr/local/bin/claude"] {
            let shown = TerminalSessionsSettingsView.agentCLIName(path)
            XCTAssertFalse(shown.contains("/"), shown)
        }
    }

    func test_theRowShowsTheNameAndKeepsThePathInItsHover() throws {
        let src = try source("Sources/Grux/Settings/TerminalSessionsSettingsView.swift")
        XCTAssertTrue(src.contains("Text(Self.agentCLIName(resolvedBinary))"))
        XCTAssertTrue(src.contains(".help(resolvedBinary ?? \"\")"))
        XCTAssertFalse(src.contains("Text(resolvedBinary"))
    }

    func test_restoreSaysWhichFileInPlainWords() {
        let line = BackupView.restoreLine
        XCTAssertFalse(line.contains("*"), line)
        XCTAssertFalse(line.lowercased().contains("manifest"), line)
        XCTAssertTrue(line.contains("grux-backup"), "it still says how to recognise the file: \(line)")
        XCTAssertTrue(line.contains("Nothing is deleted."), line)
    }

    func test_autoBackupSaysADayNotTwentyFourH() {
        XCTAssertFalse(BackupView.autoBackupLine.contains("24h"), BackupView.autoBackupLine)
    }

    func test_theBackupViewDrawsBothLines() throws {
        let src = try source("Sources/Grux/Backup/BackupView.swift")
        XCTAssertTrue(src.contains("Text(Self.restoreLine)"))
        XCTAssertTrue(src.contains("Text(Self.autoBackupLine)"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(path), encoding: .utf8)
    }
}
