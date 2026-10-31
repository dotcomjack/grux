import XCTest
import GruxShellCore
@testable import Grux

// D22. Measured 2026-10-23: a full suite run wrote `shell_run` lines resolved in
// `$TMPDIR/grux-ceiling-*` into the person's real fs-audit.log, and Foundry's
// telemetry source filed proposals ("36 gated, 39 blocked") from that test noise.
// Every audit writer resolves its log under Persistence's folder, which is the
// suite's own `Grux-tests-<pid>` under XCTest, the same rule the stores follow.
final class AuditLogsStayInTheSuiteTests: XCTestCase {

    private var realSupport: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grux").path
    }

    func testEveryAuditLogResolvesInTheSuitesOwnFolder() throws {
        let suite = Persistence.supportDir.standardizedFileURL.path
        XCTAssertFalse(suite.hasPrefix(realSupport), "the suite's folder is the person's: \(suite)")
        let logs: [(String, URL?)] = [
            ("ShellAuditLog", ShellAuditLog.logURL),
            ("FilesystemToolState", FilesystemToolState.auditLogURL()),
            ("SecurityAuditLog", SecurityAuditLog.auditLogURL()),
        ]
        for (writer, url) in logs {
            let path = try XCTUnwrap(url, "\(writer) has no log").standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(suite + "/"), "\(writer) writes the person's log under test: \(path)")
        }
        // The shell and the app write ONE fs-audit.log; two paths would split it.
        XCTAssertEqual(ShellAuditLog.logURL?.standardizedFileURL, FilesystemToolState.auditLogURL()?.standardizedFileURL)
    }

    // No source in the app builds an audit log's path from Application Support by
    // hand. GruxShellCore cannot see Persistence, so its one default (tested above)
    // is the only other place the folder is spelled.
    func testNoOtherSourceBuildsAnAuditLogPathByHand() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
            if code.contains("appendingPathComponent(\"fs-audit.log\")") || code.contains("appendingPathComponent(\"security-audit.log\")"),
               code.contains("applicationSupportDirectory") {
                found.insert(String(url.path.dropFirst(sources.path.count + 1)))
            }
        }
        XCTAssertTrue(found.contains("GruxShellCore/ShellOutputGuard.swift"), "the scan is broken: \(found)")
        XCTAssertEqual(found, ["GruxShellCore/ShellOutputGuard.swift"], "these build an audit log path by hand")
    }
}
