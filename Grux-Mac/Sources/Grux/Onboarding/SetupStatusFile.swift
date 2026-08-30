import Foundation

/// The machine-readable answer to "what does this Mac still need".
///
/// ## Why this exists
///
/// Every agent handoff Grux emits ends with a VERIFY section, and a VERIFY section that
/// points at nothing is a lie. Before this file there was no way for anything outside the
/// app to ask what was configured: the state lived in a Keychain, a `UserDefaults` domain,
/// a config struct and the live TCC database, and only SwiftUI views knew how to read all
/// four. So an agent told to "install these two things and then check" had nothing to check.
///
/// ## Where it lives, and why not Application Support
///
/// `~/.grux/` is already this app's machine interface: 64 file triggers and `mic-status.json`
/// live there, and a caller polling for state should read ONE directory rather than learn
/// that half the interface moved. Application Support holds real app DATA (the config, the
/// shell snapshots, the agent jobs). A status file is an interface, not data.
///
/// ## The two failure modes this inherits, both already paid for once
///
/// `mic-status.json` is the same pattern and its bug history is the specification.
///
/// **It reported the state from before the change that produced it.** Both `mute()` and
/// `unmute()` finish their real work in a detached task, and the file was written the
/// instant they returned, so a successful mute reported a live capture. The fix was to
/// await the pending work first. The rule that follows for this file: **call `write()`
/// AFTER the thing it describes has finished**, never inside the mutation. Every call site
/// below is placed accordingly, and `writeAfter(_:)` exists so a caller cannot forget.
///
/// **It truncated on write.** A plain write empties the file first, so a reader polling in
/// a loop can land in the gap and parse nothing. Writing to a temporary and renaming makes
/// every read see one whole version or the previous one. `.atomic` below, and a test
/// asserts a reader never sees a partial document.
@MainActor
enum SetupStatusFile {

    /// Bumped when a consumer would break. Readers must refuse a schema they do not know
    /// rather than guess, which is why it is first in the file and not optional.
    /// 2 since 2026-08-28: every feature now carries its full declaration, not
    /// only what is missing right now. The CLI needs to answer "if you picked
    /// this, what would it ask for", which is a different question from "what is
    /// it missing", and it cannot answer it from a list of unmet things.
    /// 3 since CR-36: every feature reports whether it was CHOSEN, and an
    /// unchosen one carries state `notChosen`. A consumer counting things that
    /// need setup must not count features the owner already declined.
    static let schemaVersion = 3

    nonisolated static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/setup-status.json")
    }

    // MARK: - Shape

    struct Status: Codable, Equatable {
        var schema: Int
        var generatedAt: String
        var appVersion: String
        var capabilities: [Capability]
        var features: [Feature]
        var summary: Summary
    }

    struct Capability: Codable, Equatable {
        var id: String
        var kind: String
        var label: String
        var satisfied: Bool
        /// TRUE MEANS NOBODY MEASURED ANYTHING.
        ///
        /// Four of these are consent decisions and two are settings the app itself owns, so
        /// their answer is somebody's word rather than a probe, and no VERIFY section may
        /// imply otherwise. The four detected steps, every key, every permission and every
        /// endpoint are read from the machine, so they are false.
        var selfAttested: Bool
        /// Present only when unsatisfied. A remediation on a satisfied capability is noise
        /// that a consumer has to know to ignore.
        var remediation: String?
    }

    struct Feature: Codable, Equatable {
        var id: String
        var label: String
        var tier: String
        var state: String
        /// False only when the owner explicitly left it out. Absence of any selection means
        /// everything is chosen, so an install predating CR-36 reports true for all.
        var chosen: Bool
        /// Blocking capabilities not yet satisfied, honouring any-of groups, so a feature
        /// satisfied by either of two credentials does not list both as missing.
        var missing: [String]
        /// THE FULL DECLARATION, so a caller can price a selection it has not made yet.
        /// `missing` answers "what is wrong now"; these answer "what would this cost".
        var requires: [String]
        var optional: [String]
        var steps: [String]
        var optionalSteps: [String]
        /// Either-or groups: `min` of these is enough and the rest are excused. Without
        /// this a caller reading `requires` alone would demand two credentials for a
        /// feature that needs one.
        var anyOf: [Group]

        struct Group: Codable, Equatable {
            var capabilities: [String]
            var min: Int
        }
        /// Other features that must be on. Not derivable from capabilities. See CR-35.
        var dependsOn: [String]
    }

    struct Summary: Codable, Equatable {
        var capabilities: Int
        var satisfied: Int
        var selfAttested: Int
        var featuresReady: Int
        var featuresNeedingSetup: Int
        var featuresChosen: Int
    }

    // MARK: - Building

    static func current() -> Status {
        let caps: [Capability] = SetupRequirement.allCases.map { req in
            let ok = CapabilityResolver.isSatisfied(req)
            return Capability(
                id: req.rawValue,
                kind: req.kind.rawValue,
                label: req.label,
                satisfied: ok,
                selfAttested: isSelfAttested(req),
                remediation: ok ? nil : req.remediation)
        }

        let features: [Feature] = FeatureRegistry.rows.map { row in
            Feature(id: row.id,
                    label: row.label,
                    tier: row.tier.rawValue,
                    state: FeatureRegistry.state(of: row).rawValue,
                    chosen: FeatureSelection.isOn(row.id),
                    missing: FeatureRegistry.unmetBlocking(of: row).map(\.rawValue),
                    requires: row.requires.map(\.rawValue),
                    optional: row.optional.map(\.rawValue),
                    steps: row.steps.map(\.rawValue),
                    optionalSteps: row.optionalSteps.map(\.rawValue),
                    anyOf: row.anyOf.map {
                        .init(capabilities: $0.capabilities.map(\.rawValue), min: $0.min)
                    },
                    dependsOn: row.dependsOn)
        }

        return Status(
            schema: schemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            // Only meaningful inside the app; a test host would report its own version, so
            // `write` refuses the real path outside the app rather than publishing that.
            appVersion: isRunningAsTheApp
                ? ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                   ?? "unknown")
                : "not-the-app",
            capabilities: caps,
            features: features,
            summary: Summary(
                capabilities: caps.count,
                satisfied: caps.filter(\.satisfied).count,
                selfAttested: caps.filter(\.selfAttested).count,
                featuresReady: features.filter { $0.state == FeatureState.ready.rawValue }.count,
                featuresNeedingSetup: features
                    .filter { $0.state == FeatureState.needsSetup.rawValue }.count,
                featuresChosen: features.filter { $0.chosen }.count))
    }

    /// Only a step can be self-attested. A key, a permission and an endpoint are all read
    /// from the machine, so claiming any of them was taken on trust would be as wrong as the
    /// reverse.
    static func isSelfAttested(_ req: SetupRequirement) -> Bool {
        req.kind == .step && CapabilityResolver.selfAttestedSteps.contains(req)
    }

    // MARK: - Writing

    /// TAKES ITS TARGET so a test can drive it without writing over the real file, and so
    /// the atomicity claim can be raced against a concurrent reader in a temp directory.
    /// No caller in the app ever passes it.
    /// The bundle id this file is allowed to speak for.
    nonisolated static let appBundleID = "com.gruxai.grux"

    /// True when this process really is Grux.app.
    ///
    /// `Bundle.main` is whatever is hosting the code, and in a test run that is the xctest
    /// runner. Both of the defects below were found by reading the file the test suite had
    /// just written into a real home directory, not by reasoning about it.
    nonisolated static var isRunningAsTheApp: Bool {
        Bundle.main.bundleIdentifier == appBundleID
    }

    @discardableResult
    static func write(to target: URL = url) -> Bool {
        // A PROCESS THAT IS NOT GRUX MAY NOT WRITE THE REAL FILE.
        //
        // Two things went wrong at once and both were visible in the artifact.
        // `markStepCompleted` refreshes the status file, tests call it, so `swift test`
        // wrote 16 KB into the operator's own ~/.grux/setup-status.json. And the document
        // it wrote said `"appVersion": "16.0"`, the xctest runner's version, because
        // `Bundle.main` is the test host rather than the app. A status file is the one
        // document that must not be written by something that cannot answer for its
        // contents.
        //
        // A test naming its own target is unaffected, which is how every test here runs.
        if target == Self.url, !isRunningAsTheApp { return false }

        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current()) else { return false }
        // ATOMIC, for the reason written at the top: a plain write truncates first and a
        // poller that lands in the gap reads an empty file.
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Run the work, wait for it to finish, THEN describe it.
    ///
    /// The whole point. `mic-status.json` reported the state from before the change for
    /// weeks because the write happened at the moment the mutation was requested rather
    /// than the moment it completed. A caller using this cannot make that mistake; a caller
    /// calling `write()` directly is asserting there is nothing to wait for.
    static func writeAfter(to target: URL = url, _ work: () async -> Void) async {
        await work()
        write(to: target)
    }
}
