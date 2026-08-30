import XCTest
@testable import GruxShellCore

final class ConventionAuditRunnerTests: XCTestCase {

    // MARK: - WCAG luminance + contrast

    func testWCAGContrastWhiteOnBlackIs21() {
        let ratio = WCAGContrastChecker.contrastRatio(.white, .black)
        // Per WCAG 2.1: white(L=1.0) on black(L=0.0) → (1.0+0.05)/(0.0+0.05) = 21.0
        XCTAssertEqual(ratio, 21.0, accuracy: 0.001, "white-on-black must equal 21.0")
    }

    func testWCAGContrastWhiteOnWhiteIs1() {
        let ratio = WCAGContrastChecker.contrastRatio(.white, .white)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.001, "white-on-white must equal 1.0")
    }

    func testWCAGContrastBlackOnBlackIs1() {
        let ratio = WCAGContrastChecker.contrastRatio(.black, .black)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.001)
    }

    func testWCAGAAThresholds() {
        // 4.5:1 must pass for normal text, 3.0:1 must pass for large text.
        XCTAssertTrue(WCAGContrastChecker.passesAA(ratio: 4.5, isLargeText: false))
        XCTAssertFalse(WCAGContrastChecker.passesAA(ratio: 4.49, isLargeText: false))
        XCTAssertTrue(WCAGContrastChecker.passesAA(ratio: 3.0, isLargeText: true))
        XCTAssertFalse(WCAGContrastChecker.passesAA(ratio: 2.99, isLargeText: true))
    }

    // MARK: - Markdown report

    func testMarkdownReportFormat() {
        let report = ConventionAuditReport(
            timestamp: Date(timeIntervalSince1970: 0),
            projectDir: "/tmp/test",
            conventionsVersion: "deadbeef",
            checks: [
                RuleCheck(
                    ruleNumber: 9,
                    ruleHeadline: "Privacy manifest",
                    passed: true,
                    severity: .blocker,
                    details: "ok"
                ),
                RuleCheck(
                    ruleNumber: 7,
                    ruleHeadline: "WCAG AA",
                    passed: false,
                    severity: .blocker,
                    details: "ratio 2.1 < 4.5"
                )
            ]
        )
        let md = report.markdown()
        XCTAssertTrue(md.contains("# Convention Audit Report"))
        XCTAssertTrue(md.contains("| Rule | Headline | Status | Severity | Details |"))
        // Sorted by rule number: Rule 7 row comes before Rule 9 row.
        let r7 = md.range(of: "| 7 |")
        let r9 = md.range(of: "| 9 |")
        XCTAssertNotNil(r7)
        XCTAssertNotNil(r9)
        if let r7 = r7, let r9 = r9 {
            XCTAssertLessThan(r7.lowerBound, r9.lowerBound)
        }
        XCTAssertTrue(md.contains("FAIL"))
        XCTAssertTrue(md.contains("PASS"))
        XCTAssertFalse(report.allPassed)
    }

    func testAllPassedWhenEveryCheckPasses() {
        let report = ConventionAuditReport(
            timestamp: Date(),
            projectDir: "/tmp/x",
            conventionsVersion: "a",
            checks: [
                RuleCheck(ruleNumber: 1, ruleHeadline: "x", passed: true, severity: .warning, details: "ok"),
                RuleCheck(ruleNumber: 2, ruleHeadline: "y", passed: true, severity: .blocker, details: "ok"),
                RuleCheck(ruleNumber: 3, ruleHeadline: "z", passed: true, severity: .notApplicable, details: "n/a")
            ]
        )
        XCTAssertTrue(report.allPassed)
    }

    // MARK: - End-to-end against a mock project tree

    private func makeMockProject(privacyManifest: Bool) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("conv-audit-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let app = root.appendingPathComponent("Sources/MyApp")
        let resources = app.appendingPathComponent("Resources")
        let views = app.appendingPathComponent("Views")
        let intents = app.appendingPathComponent("Intents")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.createDirectory(at: views, withIntermediateDirectories: true)
        try fm.createDirectory(at: intents, withIntermediateDirectories: true)

        // Info.plist (with explicit ITSAppUsesNonExemptEncryption + version).
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "ITSAppUsesNonExemptEncryption": false
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: app.appendingPathComponent("Info.plist"))

        // Privacy manifest (conditionally).
        if privacyManifest {
            let pm: [String: Any] = [
                "NSPrivacyAccessedAPITypes": [],
                "NSPrivacyTracking": false,
                "NSPrivacyCollectedDataTypes": []
            ]
            let pmData = try PropertyListSerialization.data(
                fromPropertyList: pm,
                format: .xml,
                options: 0
            )
            try pmData.write(to: resources.appendingPathComponent("PrivacyInfo.xcprivacy"))
        }

        // Colors.swift, high-contrast pair (black text on white bg).
        let colorsSwift = """
        import SwiftUI
        enum Colors {
            static let bgSurface = Color(red: 1.0, green: 1.0, blue: 1.0)
            static let textPrimary = Color(red: 0.0, green: 0.0, blue: 0.0)
        }
        """
        try colorsSwift.write(
            to: app.appendingPathComponent("Colors.swift"),
            atomically: true,
            encoding: .utf8
        )

        // A view file that uses the flat-toolbar pattern (Rule 6).
        let viewSwift = """
        import SwiftUI
        struct HomeView: View {
            var body: some View {
                VStack { Text("hello") }
                    .safeAreaInset(edge: .top) { Text("Header") }
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        """
        try viewSwift.write(
            to: views.appendingPathComponent("HomeView.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Intents file with brand-leading phrases.
        let intentsSwift = """
        import AppIntents
        struct AddNoteShortcut: AppShortcutsProvider {
            static var appShortcuts: [AppShortcut] {
                AppShortcut(
                    intent: AddNoteIntent(),
                    phrases: [
                        "Add to MyApp",
                        "Save to MyApp"
                    ]
                )
            }
        }
        """
        try intentsSwift.write(
            to: intents.appendingPathComponent("AppShortcuts.swift"),
            atomically: true,
            encoding: .utf8
        )

        // Entitlements file with universal links.
        let entitlements: [String: Any] = [
            "com.apple.developer.associated-domains": ["applinks:myapp.example.com"]
        ]
        let entData = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        try entData.write(to: app.appendingPathComponent("MyApp.entitlements"))

        return root
    }

    func testMockProjectAllRulesPassing() async throws {
        let root = try makeMockProject(privacyManifest: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Empty conventions path → version becomes "missing" but audit still runs.
        let report = await ConventionAuditRunner.audit(
            projectDir: root.path,
            conventionsPath: "/nonexistent/conventions.md",
            brand: "MyApp"
        )
        // Audit always returns 10 checks (rule 6, 7, 8, 9, 10, 12, 13, 16, 27, 29).
        XCTAssertEqual(report.checks.count, 10)

        let r9 = report.checks.first { $0.ruleNumber == 9 }
        XCTAssertNotNil(r9)
        XCTAssertEqual(r9?.passed, true)

        let r10 = report.checks.first { $0.ruleNumber == 10 }
        XCTAssertEqual(r10?.passed, true)

        let r29 = report.checks.first { $0.ruleNumber == 29 }
        XCTAssertEqual(r29?.passed, true)

        let r13 = report.checks.first { $0.ruleNumber == 13 }
        XCTAssertEqual(r13?.passed, true)

        let r27 = report.checks.first { $0.ruleNumber == 27 }
        XCTAssertEqual(r27?.passed, true)

        let r7 = report.checks.first { $0.ruleNumber == 7 }
        // Black text on white bg = 21:1, passes AA.
        XCTAssertEqual(r7?.passed, true)
    }

    func testMockProjectMissingPrivacyManifestFails() async throws {
        let root = try makeMockProject(privacyManifest: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = await ConventionAuditRunner.audit(
            projectDir: root.path,
            conventionsPath: "/nonexistent/conventions.md",
            brand: "MyApp"
        )
        let r9 = report.checks.first { $0.ruleNumber == 9 }
        XCTAssertNotNil(r9)
        XCTAssertEqual(r9?.passed, false)
        XCTAssertEqual(r9?.severity, .blocker)
        XCTAssertFalse(report.allPassed)
    }
}
