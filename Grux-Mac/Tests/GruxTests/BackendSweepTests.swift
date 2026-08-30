import XCTest

/// Keeps every feature surface on the routed backend, permanently.
///
/// ## The defect this closes
///
/// `ModelBackend.swift` said it out loud in its own header: "The other 17 call
/// sites keep calling the concrete `ClaudeClient()` they instantiate directly."
/// Measured over `Sources/Grux` the day this file was written, it was 32 files,
/// not 17. So "your key or a local model" was true for the Chat tab and false
/// for everything else: meeting summaries, email triage, deep research, vision,
/// reminders, the ambient coach and Design Studio all built their own
/// `ClaudeClient`, sent `AppState.anthropicKey`, and either went silent or threw
/// a raw provider error on a local-only or custom-endpoint install.
///
/// A sweep fixes it once. Only a test keeps it fixed. The next feature written
/// in any of these files will start `let claude = ClaudeClient()` because every
/// neighbouring file used to, and the failure is invisible on the machine of
/// whoever writes it: they have an Anthropic key, so their surface works.
///
/// ## Why this reads the source instead of asserting on behaviour
///
/// There is no runtime observation that distinguishes "routed through the
/// registry" from "built its own client and happened to be pointed at the same
/// provider", because on a developer machine with an Anthropic key configured
/// the two are byte-identical on the wire. The difference is structural, so the
/// assertion is structural, the same technique `NoPersonalIdentityTests` and
/// `DenylistParityTests` already use in this repo.
///
/// ## The exception list is the point
///
/// Four sites are NOT routed, on purpose, and they are named here with the
/// reason. Naming them is what makes a future addition to that list a deliberate
/// edit somebody has to justify in a diff, rather than silent drift back to
/// where this started. `testExceptionsAreNotStale` deletes an exception whose
/// reason has stopped being true, and pins each one at the SINGLE construction
/// it excuses, so an exemption never quietly widens into a pass for its file.
final class BackendSweepTests: XCTestCase {

    // MARK: - The sweep set

    /// Every file that constructed a `ClaudeClient` before this sweep, relative
    /// to the package root, plus the four that still do.
    ///
    /// Hardcoded rather than rediscovered, because the set IS the contract: a
    /// file that quietly drops off a discovered list takes its guarantee with
    /// it, and `testEverySweptFileExists` fails on a path that no longer
    /// resolves so a rename cannot silently shrink the scope.
    ///
    /// `ChatService.swift` and `Backend/ModelRegistry.swift` are deliberately
    /// absent. The registry is where the ONE canonical `ClaudeClient()` is
    /// supposed to live, and ChatService is the chat seam that already routed
    /// before this sweep began.
    ///
    /// `SettingsView.swift` used to be listed here as a third absence on those
    /// same grounds, and that was wrong twice over. It contains no
    /// `resolvedRouting(` call at all, so calling it part of the routed chat
    /// seam described a file that does not exist. And it still constructs a
    /// client, correctly, for the Test Key button, whose comment pointed AT this
    /// list for its justification: the one deliberate exemption in the file was
    /// documented by a guard that never opened the file. It is swept now, with
    /// that site named in `exceptions` below, so the pointer is true and a
    /// SECOND construction here fails.
    static let sweptFiles: [String] = [
        "Sources/Grux/Ambient/AmbientCoach.swift",
        "Sources/Grux/Ambient/AmbientHourlySummarizer.swift",
        "Sources/Grux/Ambient/AmbientMemoryExtractor.swift",
        "Sources/Grux/Compare/ComparisonService.swift",
        "Sources/Grux/Creative/CreativeEngine.swift",
        "Sources/Grux/DesignStudio/Iteration/CritiqueGate.swift",
        "Sources/Grux/DesignStudio/Iteration/DirectionEngine.swift",
        "Sources/Grux/DesignStudio/Iteration/SurgicalEditEngine.swift",
        "Sources/Grux/Documents/DocumentEditorView.swift",
        "Sources/Grux/FocusWatcher.swift",
        "Sources/Grux/Foundry/Signals/UXAuditSource.swift",
        "Sources/Grux/Jax/Autonomy/GoalPursuitEngine.swift",
        "Sources/Grux/Jax/BriefingEngine.swift",
        "Sources/Grux/Jax/Cognition/ConfidenceGate.swift",
        "Sources/Grux/Jax/Grounding/GroundedGenerator.swift",
        "Sources/Grux/Jax/Review/FeatureReviewEngine.swift",
        "Sources/Grux/Jax/Review/QualityGate.swift",
        "Sources/Grux/LocalLLM.swift",
        "Sources/Grux/Meeting/MeetingSummarizer.swift",
        "Sources/Grux/Memory/PersonMemory.swift",
        "Sources/Grux/Outreach/ColdEmail.swift",
        "Sources/Grux/Reminders/DailyRecap.swift",
        "Sources/Grux/Reminders/MentorTriggerDetector.swift",
        "Sources/Grux/Reminders/MorningBrief.swift",
        "Sources/Grux/Reminders/StuckDetector.swift",
        "Sources/Grux/Research/DeepResearchEngine.swift",
        "Sources/Grux/SettingsView.swift",
        "Sources/Grux/TranscriptCorrector.swift",
        "Sources/Grux/VisionTool.swift",
        "Sources/Grux/WebResearch.swift",
    ]

    /// The files that still construct a `ClaudeClient`, each with the reason and
    /// with a marker that proves the reason is still true.
    ///
    /// `marker` is what makes this list self-deleting. An exception whose
    /// justification has been removed from the file (the gate stops calling
    /// `completeCached`, Compare stops building contenders) is an exception that
    /// has outlived its reason, and an exemption that outlives its reason is
    /// just a hole.
    struct Exception {
        let reason: String
        /// A substring that must still be present in the file for the exception
        /// to be legitimate.
        let marker: String
    }

    static let exceptions: [String: Exception] = [
        "Sources/Grux/Compare/ComparisonService.swift": Exception(
            reason: "Compare runs Anthropic BESIDE each local model in one fan-out, so a "
                  + "single resolved provider would collapse the comparison to one column. "
                  + "Each contender also needs its own client because usageSnapshot() "
                  + "reports the most recent call on that instance.",
            marker: "ComparisonContender("),
        "Sources/Grux/DesignStudio/Iteration/CritiqueGate.swift": Exception(
            reason: "Calls completeCached, which is a ClaudeClient method and NOT a "
                  + "ModelBackend requirement, so resolvedRouting cannot express it. "
                  + "Blocked on completeCached joining the protocol.",
            marker: "completeCached("),
        "Sources/Grux/Jax/Review/QualityGate.swift": Exception(
            reason: "Same block as CritiqueGate: completeCached is not on the ModelBackend "
                  + "protocol, and rewriting onto plain complete would throw away the "
                  + "shared cached diff prefix that makes five reviewers affordable.",
            marker: "completeCached("),
        "Sources/Grux/SettingsView.swift": Exception(
            reason: "The Test Key button answers \"is the Anthropic key you just pasted "
                  + "good\". Routing it would test whichever backend happens to be active "
                  + "and report success on a key it never sent, which is the exact opposite "
                  + "of what the button is for.",
            marker: "private func testKeyInner()"),
    ]

    /// Swept files that legitimately do NOT call `resolvedRouting`, with the
    /// reason and the marker that keeps the entry honest.
    ///
    /// Without this second list the primary assertion is weaker than it looks:
    /// deleting the model call outright also removes the `ClaudeClient()`, and a
    /// test that only counts constructions would call that a pass.
    static let routingExempt: [String: Exception] = [
        "Sources/Grux/Ambient/AmbientHourlySummarizer.swift": Exception(
            reason: "Its ClaudeClient was a dead stored property with no call site: the "
                  + "summarizer has always gone through AmbientLLM, which this sweep "
                  + "routed. The property was deleted rather than converted.",
            marker: "AmbientLLM.complete("),
        "Sources/Grux/Compare/ComparisonService.swift": Exception(
            reason: "Not routed at all, see the exceptions list.",
            marker: "ComparisonContender("),
        "Sources/Grux/DesignStudio/Iteration/CritiqueGate.swift": Exception(
            reason: "Not routed at all, see the exceptions list.",
            marker: "completeCached("),
        "Sources/Grux/Jax/Review/QualityGate.swift": Exception(
            reason: "Not routed at all, see the exceptions list.",
            marker: "completeCached("),
        "Sources/Grux/SettingsView.swift": Exception(
            reason: "Not routed at all, see the exceptions list. This pane READS and WRITES "
                  + "the routing configuration rather than sending a turn through it, so "
                  + "there is no turn here for resolvedRouting to answer about.",
            marker: "private func testKeyInner()"),
    ]

    // MARK: - The scan

    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Grux-Mac/Tests/GruxTests/ThisFile.swift
            .deletingLastPathComponent()    // .../Grux-Mac/Tests/GruxTests
            .deletingLastPathComponent()    // .../Grux-Mac/Tests
            .deletingLastPathComponent()    // .../Grux-Mac
    }

    static func source(_ rel: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    /// Line numbers on which `text` constructs a `ClaudeClient`, ignoring line
    /// comments.
    ///
    /// Ignoring comments is not cosmetic. Nearly every converted site now
    /// carries a comment that names `ClaudeClient` to explain what it stopped
    /// doing, so a plain grep for the type would report the whole sweep as
    /// unswept. What is asserted on is the CONSTRUCTION, `ClaudeClient(`, on
    /// code rather than in prose.
    ///
    /// The comment strip cuts at the first `//`, which would also cut a `//`
    /// inside a string literal. That can only ever hide a construction that
    /// shares a line with a URL literal, and `testTheScannerDetectsAPlantedConstruction`
    /// pins the direction that matters.
    static func constructionLines(in text: String) -> [Int] {
        var out: [Int] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let code = raw.components(separatedBy: "//")[0]
            if code.contains("ClaudeClient(") { out.append(i + 1) }
        }
        return out
    }

    // MARK: - The invariant

    /// No swept file builds its own `ClaudeClient`, except the three that are
    /// named above with a reason.
    func testSweptFilesDoNotConstructClaudeClient() throws {
        var offenders: [String] = []
        for rel in Self.sweptFiles {
            if Self.exceptions[rel] != nil { continue }
            let lines = Self.constructionLines(in: try Self.source(rel))
            for line in lines {
                offenders.append("\(rel):\(line)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            "these files build their own ClaudeClient instead of routing through "
          + "ModelRegistry.resolvedRouting, so a local-only or custom-endpoint user "
          + "cannot use them:\n" + offenders.joined(separator: "\n")
          + "\n\nConvert the site, or add it to BackendSweepTests.exceptions with a reason.")
    }

    /// Removing the construction is only half the fix. Every swept file that was
    /// actually converted has to be READING the registry, or the site was
    /// deleted rather than routed.
    func testConvertedFilesResolveRouting() throws {
        var missing: [String] = []
        for rel in Self.sweptFiles {
            if Self.routingExempt[rel] != nil { continue }
            let text = try Self.source(rel)
            if !text.contains("resolvedRouting(") { missing.append(rel) }
        }
        XCTAssertTrue(missing.isEmpty,
            "these files no longer construct a ClaudeClient but never ask the registry "
          + "which backend to use, so the model call was removed rather than routed:\n"
          + missing.joined(separator: "\n"))
    }

    /// A path that stops resolving takes its guarantee with it, silently, and the
    /// suite stays green. So the set is proved to exist before it is trusted.
    func testEverySweptFileExists() throws {
        var missing: [String] = []
        for rel in Self.sweptFiles {
            let url = Self.packageRoot().appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: url.path) { missing.append(rel) }
        }
        XCTAssertTrue(missing.isEmpty,
            "BackendSweepTests names files that do not exist. A rename shrank the scope "
          + "of this guard without failing it:\n" + missing.joined(separator: "\n"))
        XCTAssertEqual(Self.sweptFiles.count, 30,
            "the sweep covered 29 files, plus SettingsView.swift, added afterwards so that "
          + "its Test Key exemption sits inside a guard that actually opens the file. "
          + "Changing that number is a scope change and should be a deliberate edit with "
          + "a reason in the diff.")
    }

    // MARK: - The exception lists cannot rot

    /// An exemption that outlives its reason is a hole. Both lists are checked
    /// the same way: the file must still contain the construction it is excused
    /// for, and still contain the marker that justifies the excuse.
    ///
    /// The construction count is pinned at ONE per exempted file, not merely at
    /// "more than zero", because every entry above excuses a single named site
    /// for a single named reason and `testSweptFilesDoNotConstructClaudeClient`
    /// skips an exempted file whole. Without the count, listing a file here
    /// would hand it a file-wide pass, which matters most for the largest of
    /// them: `SettingsView.swift` is a 2000 line view where a second "test my
    /// endpoint" button is a plausible next edit, and a file-level exemption
    /// would wave it straight through into exactly the unrouted state this
    /// sweep was written to end.
    func testExceptionsAreNotStale() throws {
        for (rel, ex) in Self.exceptions {
            let text = try Self.source(rel)
            let built = Self.constructionLines(in: text)
            let sites = built.isEmpty ? "none" : "lines \(built)"
            XCTAssertEqual(built.count, 1,
                "\(rel) is exempted from the backend sweep for exactly ONE named site and "
              + "now builds \(built.count) of them (\(sites)). Zero means the reason is "
              + "gone: remove it from BackendSweepTests.exceptions. More than one means the "
              + "exemption is being read as a pass for the whole file: route the new site "
              + "through ModelRegistry.resolvedRouting, or restate the exception to say why "
              + "there are now two. On record: \(ex.reason)")
            XCTAssertTrue(text.contains(ex.marker),
                "\(rel) is exempted because: \(ex.reason)\nThat reason is no longer true: "
              + "\"\(ex.marker)\" is gone from the file. Route the site, or restate the "
              + "exception.")
        }
    }

    func testRoutingExemptionsAreNotStale() throws {
        for (rel, ex) in Self.routingExempt {
            let text = try Self.source(rel)
            XCTAssertFalse(text.contains("resolvedRouting("),
                "\(rel) is listed as routing-exempt but now calls resolvedRouting. Remove "
              + "it from BackendSweepTests.routingExempt so the real assertion covers it.")
            XCTAssertTrue(text.contains(ex.marker),
                "\(rel) is routing-exempt because: \(ex.reason)\nThat reason is no longer "
              + "true: \"\(ex.marker)\" is gone from the file.")
        }
    }

    /// Every exempted path has to be inside the sweep set, or the exemption
    /// forgives a file this guard never looks at and reads as coverage it does
    /// not have.
    func testExceptionPathsAreInsideTheSweepSet() {
        let swept = Set(Self.sweptFiles)
        for rel in Self.exceptions.keys {
            XCTAssertTrue(swept.contains(rel), "\(rel) is exempted but is not swept.")
        }
        for rel in Self.routingExempt.keys {
            XCTAssertTrue(swept.contains(rel), "\(rel) is routing-exempt but is not swept.")
        }
    }

    // MARK: - Proving the scanner can fail

    /// A guard that has never gone red is a guard nobody has confirmed is wired
    /// up. This plants both directions: a real construction must be found, and
    /// the same words in a comment must not be.
    func testTheScannerDetectsAPlantedConstruction() {
        let planted = """
        // This file used to build its own ClaudeClient() and send the raw key.
        final class Thing {
            private let claude = ClaudeClient()
        }
        """
        XCTAssertEqual(Self.constructionLines(in: planted), [3],
            "the construction scanner reported \(Self.constructionLines(in: planted)) "
          + "instead of line 3 alone. It must find real code and ignore prose, or every "
          + "converted file (which now names ClaudeClient in a comment) reads as unswept.")
    }

    /// The mirror control: a file that only mentions the type, and never builds
    /// one, is clean. This is exactly the shape every converted site now has.
    func testAMentionWithoutAConstructionIsNotAHit() {
        let converted = """
        // ROUTED. This built its own ClaudeClient and sent AppState.anthropicKey.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        let reply = try await routing.backend.complete(apiKey: routing.apiKey)
        """
        XCTAssertTrue(Self.constructionLines(in: converted).isEmpty,
            "a converted site was reported as still constructing a ClaudeClient.")
    }
}
