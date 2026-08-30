import Foundation

// Codable record of a single rule's audit outcome. Carried inside
// ConventionAuditReport. Workers in the iosAppFull swarm receive the parent
// report and decide what to do - this is informational, not a hard gate.
public struct RuleCheck: Codable, Sendable {
    public let ruleNumber: Int
    public let ruleHeadline: String
    public let passed: Bool
    public let severity: Severity
    public let details: String

    public enum Severity: String, Codable, Sendable {
        case blocker
        case warning
        case notApplicable
    }

    public init(
        ruleNumber: Int,
        ruleHeadline: String,
        passed: Bool,
        severity: Severity,
        details: String
    ) {
        self.ruleNumber = ruleNumber
        self.ruleHeadline = ruleHeadline
        self.passed = passed
        self.severity = severity
        self.details = details
    }
}

// Aggregate report. `markdown()` is the form embedded into build_summary.md
// so the build-loop / qa workers can read the same human-friendly output the
// orchestrator surfaces in the UI.
public struct ConventionAuditReport: Codable, Sendable {
    public let timestamp: Date
    public let projectDir: String
    public let conventionsVersion: String  // sha256 of conventions.md content
    public let checks: [RuleCheck]

    public init(
        timestamp: Date,
        projectDir: String,
        conventionsVersion: String,
        checks: [RuleCheck]
    ) {
        self.timestamp = timestamp
        self.projectDir = projectDir
        self.conventionsVersion = conventionsVersion
        self.checks = checks
    }

    public var allPassed: Bool {
        checks.allSatisfy { $0.passed }
    }

    public func markdown() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        lines.append("# Convention Audit Report")
        lines.append("")
        lines.append("- **Project:** \(projectDir)")
        lines.append("- **Timestamp:** \(iso.string(from: timestamp))")
        lines.append("- **Conventions version (sha256):** `\(conventionsVersion)`")
        lines.append("- **Overall:** \(allPassed ? "PASS" : "FAIL")")
        lines.append("")
        lines.append("| Rule | Headline | Status | Severity | Details |")
        lines.append("|------|----------|--------|----------|---------|")
        for check in checks.sorted(by: { $0.ruleNumber < $1.ruleNumber }) {
            let status: String
            if check.severity == .notApplicable {
                status = "N/A"
            } else {
                status = check.passed ? "PASS" : "FAIL"
            }
            let safeDetails = check.details
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("| \(check.ruleNumber) | \(check.ruleHeadline) | \(status) | \(check.severity.rawValue) | \(safeDetails) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
