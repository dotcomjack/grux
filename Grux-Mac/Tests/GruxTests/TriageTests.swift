import XCTest
@testable import Grux

// Notification triage (blueprint section 03): policy resolution table,
// quiet-hours window math, the batching fold, and the rule classifier.
// Everything here exercises the pure nonisolated cores so no MainActor
// singleton state is touched.

final class TriageTests: XCTestCase {

    // MARK: - Policy resolution table

    func testResolutionTable() {
        typealias Row = (base: TriageAction, urgent: Bool, quiet: Bool, expect: TriageAction)
        let table: [Row] = [
            // Plain pass-through, no modifiers.
            (.interrupt, false, false, .interrupt),
            (.batch,     false, false, .batch),
            (.silent,    false, false, .silent),
            // actionRequired upgrades batch and silent to interrupt.
            (.interrupt, true,  false, .interrupt),
            (.batch,     true,  false, .interrupt),
            (.silent,    true,  false, .interrupt),
            // Quiet hours downgrade interrupts to batch, including upgraded
            // blockers. Batch/silent are untouched by quiet hours.
            (.interrupt, false, true,  .batch),
            (.batch,     false, true,  .batch),
            (.silent,    false, true,  .silent),
            (.interrupt, true,  true,  .batch),
            (.batch,     true,  true,  .batch),
            (.silent,    true,  true,  .batch)
        ]
        for row in table {
            let got = TriagePolicyStore.resolve(
                base: row.base, actionRequired: row.urgent, inQuietHours: row.quiet
            )
            XCTAssertEqual(
                got, row.expect,
                "base=\(row.base) urgent=\(row.urgent) quiet=\(row.quiet)"
            )
        }
    }

    func testDefaultPoliciesMatchBlueprintAnchors() {
        // Commitment reminders interrupt, agent completions batch, info silent.
        XCTAssertEqual(TriagePolicyStore.defaultPolicies[.reminders], .interrupt)
        XCTAssertEqual(TriagePolicyStore.defaultPolicies[.agentLifecycle], .batch)
        XCTAssertEqual(TriagePolicyStore.defaultPolicies[.system], .silent)
        // Every category has a default.
        for cat in TriageCategory.allCases {
            XCTAssertNotNil(TriagePolicyStore.defaultPolicies[cat], "\(cat) missing default")
        }
    }

    // MARK: - Quiet hours window math

    func testQuietHoursNormalWindow() {
        // 09:00 -> 17:00, no wrap. Start inclusive, end exclusive.
        let s = 9 * 60, e = 17 * 60
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 8 * 60 + 59, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 9 * 60, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 12 * 60, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 16 * 60 + 59, start: s, end: e))
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 17 * 60, start: s, end: e))
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 23 * 60, start: s, end: e))
    }

    func testQuietHoursWrappingWindow() {
        // 22:00 -> 07:00, wraps midnight.
        let s = 22 * 60, e = 7 * 60
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 22 * 60, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 23 * 60 + 59, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 0, start: s, end: e))
        XCTAssertTrue(TriageQuietHours.windowContains(minuteOfDay: 6 * 60 + 59, start: s, end: e))
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 7 * 60, start: s, end: e))
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 12 * 60, start: s, end: e))
        XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: 21 * 60 + 59, start: s, end: e))
    }

    func testQuietHoursZeroLengthWindowNeverContains() {
        let s = 10 * 60
        for m in [0, s - 1, s, s + 1, 23 * 60] {
            XCTAssertFalse(TriageQuietHours.windowContains(minuteOfDay: m, start: s, end: s))
        }
    }

    func testQuietHoursDisabledNeverContains() {
        let qh = TriageQuietHours(enabled: false, startMinute: 0, endMinute: 24 * 60 - 1)
        XCTAssertFalse(qh.contains(Date()))
    }

    // MARK: - Batching fold

    private func item(_ cat: TriageCategory, _ title: String) -> TriageBatchedItem {
        TriageBatchedItem(category: cat, title: title, body: "")
    }

    func testDigestSummaryGroupsByCategoryInTaxonomyOrder() {
        let items = [
            item(.system, "Domain check: foo.com"),
            item(.agentLifecycle, "Swarm finished: refactor"),
            item(.agentLifecycle, "Swarm finished: tests"),
            item(.system, "API key OK")
        ]
        let digest = TriageBatchQueue.digestSummary(for: items)
        XCTAssertTrue(digest.hasPrefix("Notifications digest (4): "), digest)
        XCTAssertTrue(digest.contains("agents 2 (Swarm finished: refactor; Swarm finished: tests)"), digest)
        XCTAssertTrue(digest.contains("system 2 (Domain check: foo.com; API key OK)"), digest)
        // agentLifecycle precedes system in the taxonomy, so it must come
        // first in the digest regardless of arrival order.
        let agentsIdx = digest.range(of: "agents 2")!.lowerBound
        let systemIdx = digest.range(of: "system 2")!.lowerBound
        XCTAssertLessThan(agentsIdx, systemIdx)
    }

    func testDigestSummaryCapsExamplesAtTwoPerCategory() {
        let items = (1...5).map { item(.emailTriage, "draft \($0)") }
        let digest = TriageBatchQueue.digestSummary(for: items)
        XCTAssertTrue(digest.contains("email triage 5 (draft 1; draft 2)"), digest)
        XCTAssertFalse(digest.contains("draft 3"), digest)
    }

    func testDigestSummaryEmpty() {
        XCTAssertEqual(TriageBatchQueue.digestSummary(for: []), "Notifications digest: none.")
    }

    // MARK: - Rule classifier

    func testKindHintsWinOverKeywords() {
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: "supportDrafts", title: "anything", body: "")?.category,
            .emailTriage
        )
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: "agentPaused", title: "x", body: "")?.category,
            .agentLifecycle
        )
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: "v2PhaseTransition", title: "x", body: "")?.category,
            .commandPhases
        )
    }

    func testKeywordRules() {
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: nil, title: "Domain expiring: foo.com", body: "12 days.")?.category,
            .system
        )
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: nil, title: "Schedule: morning sweep", body: "Running workflow")?.category,
            .commandPhases
        )
        XCTAssertEqual(
            TriageClassifier.ruleVerdict(kind: nil, title: "Grux switched focus", body: "promoted to NOW")?.category,
            .reminders
        )
        XCTAssertNil(TriageClassifier.ruleVerdict(kind: nil, title: "Totally novel thing", body: "no keywords here"))
    }

    func testUrgencyUpgradesBlockers() {
        let rejected = TriageClassifier.ruleVerdict(
            kind: nil, title: "Apple rejected the app", body: "State: REJECTED."
        )
        XCTAssertEqual(rejected?.category, .system)
        XCTAssertEqual(rejected?.actionRequired, true)

        let ok = TriageClassifier.ruleVerdict(
            kind: nil, title: "API key OK", body: "Got reply: hi"
        )
        XCTAssertEqual(ok?.actionRequired, false)
    }

    // The old substring match flagged "Terror" (contains "error") and the
    // negated "no errors" as urgent, escalating benign notifications to
    // interrupt banners. Word boundaries + negation handling fix both.
    func testUrgencyIgnoresSubstringsAndNegations() {
        XCTAssertFalse(TriageClassifier.urgent(title: "Standup", body: "all green, no errors"),
                       "'no errors' must not be urgent")
        XCTAssertFalse(TriageClassifier.urgent(title: "Terror flick at 8", body: ""),
                       "'error' inside 'terror' must not match")
        XCTAssertFalse(TriageClassifier.urgent(title: "Sync finished", body: "no error in this run"),
                       "'no error' must not be urgent")
        XCTAssertFalse(TriageClassifier.urgent(title: "Build", body: "0 errors, 0 warnings"),
                       "'0 errors' must not be urgent")
        // Genuine urgency still fires.
        XCTAssertTrue(TriageClassifier.urgent(title: "Deploy", body: "build failed"))
        XCTAssertTrue(TriageClassifier.urgent(title: "Cert expiring", body: ""))
        XCTAssertTrue(TriageClassifier.urgent(title: "Heads up", body: "an error occurred"))
        XCTAssertTrue(TriageClassifier.urgent(title: "Quota", body: "limit hit"))
    }

    func testNormalizedKeyCollapsesDigitsAndWhitespace() {
        XCTAssertEqual(
            TriageClassifier.normalizedKey(forTitle: "3 new support drafts"),
            TriageClassifier.normalizedKey(forTitle: "12  new support drafts")
        )
        XCTAssertEqual(TriageClassifier.normalizedKey(forTitle: "Phase 2/4"), "phase #/#")
    }
}
