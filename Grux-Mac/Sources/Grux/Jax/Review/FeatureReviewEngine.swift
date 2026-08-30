import Foundation

// Grux Feature Review: the staging-to-main governance + "Grux explains his work"
// surface. Nothing static: for every feature, Grux GENERATES the pitch (what it
// is, the reasoning, what it helps, why to implement) live via the model, in his
// own voice, and you decide per feature whether it reaches main.
//
// Two feature sources:
//   1. SEEDED: this session's shipped work (already on main) so the catalog is
//      immediately rich and you can see the whole arc.
//   2. STAGED: anything on the `staging` branch not yet on `main` (git log
//      main..staging), auto-discovered. These are the ones awaiting your tap.
//
// Decisions: a STAGED feature can be implemented (merged to main, green-gated),
// held, or rejected. A SEEDED/live feature is already on main (status .live), so
// it is explained, not gated. Implement never runs git inside the app: it writes
// a merge-intent that the guarded tools/implement-feature.sh executes with the
// build-green gate, so a feature can never break main on the way in.
//
// House style: @MainActor singleton, Codable local persistence to ~/.grux/jax/,
// zero em/en dashes, dollars as $N.

enum FeatureStatus: String, Codable {
    case live       // already on main (seeded session work)
    case staged     // on staging, awaiting the user's decision
    case held       // the user parked it
    case rejected   // the user declined it
    case approved   // approved; merge-intent written for the guarded merge

    var label: String {
        switch self {
        case .live: return "Live on main"
        case .staged: return "Awaiting review"
        case .held: return "Held"
        case .rejected: return "Rejected"
        case .approved: return "Approved for main"
        }
    }
}

// Grux's generated pitch for a feature. Every field is model-written from the
// real commit; nothing is hardcoded. generatedAt lets the UI show freshness and
// the user re-generate.
struct FeaturePitch: Codable, Equatable {
    var what: String        // what it is, plainly
    var reasoning: String   // why Grux built it this way
    var helps: String       // what it helps / who it is for
    var why: String         // why the user should implement it
    var generatedAt: Date
}

struct ReviewFeature: Codable, Identifiable {
    let id: String          // the commit sha (stable key)
    var title: String       // commit subject, cleaned
    var branch: String      // "main" or "staging"
    var status: FeatureStatus
    var pitch: FeaturePitch?
    var addedAt: Date

    init(id: String, title: String, branch: String, status: FeatureStatus, pitch: FeaturePitch? = nil, addedAt: Date = Date()) {
        self.id = id; self.title = title; self.branch = branch; self.status = status; self.pitch = pitch; self.addedAt = addedAt
    }
}

@MainActor
final class FeatureReviewEngine: ObservableObject {
    static let shared = FeatureReviewEngine()

    @Published private(set) var features: [ReviewFeature] = []
    @Published private(set) var isGenerating = false
    // Quality-gate verdicts keyed by commit sha. A staged feature cannot be
    // implemented to main until verdicts[sha]?.status == .pass.
    @Published private(set) var verdicts: [String: QualityVerdict] = [:]
    @Published private(set) var gatingIDs: Set<String> = []   // gate in flight


    // Which checkout the review queue reads. Was one machine's absolute home
    // path, which is a path that exists on exactly one computer. EMPTY by
    // default, which means "not configured": every git call below then returns
    // no output, so bootstrap discovers nothing and the surface renders an
    // empty catalog instead of failing.
    //
    // Order: env var, then UserDefaults, then nothing.
    //   GRUX_REVIEW_REPO_DIR=/path/to/checkout
    //   defaults write com.gruxai.grux grux.review.repo_dir /path/to/checkout
    static let repoDirDefaultsKey = "grux.review.repo_dir"
    private var repoDir: String {
        if let env = ProcessInfo.processInfo.environment["GRUX_REVIEW_REPO_DIR"], !env.isEmpty { return env }
        return UserDefaults.standard.string(forKey: Self.repoDirDefaultsKey) ?? ""
    }
    private let storeURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("features.json")
    }()
    private let verdictsURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
        return dir.appendingPathComponent("gate-verdicts.json")
    }()
    private let mergeIntentURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
        return dir.appendingPathComponent("merge-intent.json")
    }()

    private init() { load(); verdicts = Persistence.load([String: QualityVerdict].self, from: verdictsURL, fallback: [:]) }

    // MARK: Discovery

    // Seed this session's shipped features (already on main) + discover anything
    // on staging awaiting review. Idempotent: never duplicates an existing sha,
    // never clobbers a pitch or a decided status.
    func bootstrap() {
        // 1. staged features not yet on main (the review queue)
        for (sha, subject) in gitLog("main..staging") {
            upsert(sha: sha, title: subject, branch: "staging", defaultStatus: .staged)
        }
        // 2. recent main features (the explained catalog). Cap to the last 20 so
        //    the seed stays the relevant arc, not all history.
        for (sha, subject) in gitLog("-20", main: true) where isFeatureCommit(subject) {
            upsert(sha: sha, title: cleanTitle(subject), branch: "main", defaultStatus: .live)
        }
        save()
    }

    private func upsert(sha: String, title: String, branch: String, defaultStatus: FeatureStatus) {
        if features.contains(where: { $0.id == sha }) { return }
        features.insert(ReviewFeature(id: sha, title: title, branch: branch, status: defaultStatus), at: 0)
    }

    private func isFeatureCommit(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return s.hasPrefix("feat(") || s.hasPrefix("fix(") || s.hasPrefix("feat:") || s.hasPrefix("fix:")
    }

    private func cleanTitle(_ subject: String) -> String {
        // Drop the conventional-commit prefix for a human title.
        if let r = subject.range(of: "): ") { return String(subject[r.upperBound...]) }
        if let r = subject.range(of: ": ") { return String(subject[r.upperBound...]) }
        return subject
    }

    // MARK: Pitch generation (live, Grux voice)

    func regeneratePitch(for id: String) async {
        guard let idx = features.firstIndex(where: { $0.id == id }) else { return }
        let f = features[idx]
        let stat = gitShowStat(f.id)
        let pitch = await generate(title: f.title, sha: f.id, diffStat: stat)
        if let i = features.firstIndex(where: { $0.id == id }) {
            features[i].pitch = pitch
            save()
        }
    }

    // Generate pitches for every feature missing one (used by the exporter + a
    // first-open of the tab). Sequential to respect rate limits.
    func generateMissingPitches() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        for f in features where f.pitch == nil {
            await regeneratePitch(for: f.id)
        }
    }

    private func generate(title: String, sha: String, diffStat: String) async -> FeaturePitch {
        let fallback = FeaturePitch(
            what: title, reasoning: "Built as part of the Jax/Grux work.",
            helps: "Improves Grux.", why: "Review the diff to decide.", generatedAt: Date())
        // ROUTED. This built its own ClaudeClient and gated on
        // AppState.anthropicKey, so a local-only or custom-endpoint user saw the
        // canned fallback pitch on every feature and never a generated one.
        // Resolved ONCE per pitch.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        guard !routing.apiKey.isEmpty else { return fallback }

        let sys = """
        \(JaxProfile.shared.persona)

        RIGHT NOW you are walking the user through a feature YOU built, so they can decide whether to implement it to main. Be concrete and honest, grounded only in the real commit + diff stat below. Do NOT invent capabilities or numbers that are not in the change. Speak in your own voice, direct, no hype.

        Return STRICT JSON, nothing else:
        {"what":"<1-2 sentences: what this feature is, plainly>","reasoning":"<1-2 sentences: why you built it this way>","helps":"<1 sentence: what it helps or who it is for>","why":"<1 sentence: why they should implement it>"}
        """
        let user = "FEATURE COMMIT: \(title)\nSHA: \(sha)\nDIFF STAT:\n\(diffStat.isEmpty ? "(not available)" : diffStat)\n\nWrite the JSON pitch."
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey, model: routing.modelId, system: sys,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 500, temperature: 0.5,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete", feature: "featureReview")
            if let p = Self.parse(reply) { return p }
        } catch {
            WakeLog.shared.log("featureReview: pitch generation failed for \(sha.prefix(8)): \(error.localizedDescription)")
        }
        return fallback
    }

    nonisolated static func parse(_ reply: String) -> FeaturePitch? {
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}") else { return nil }
        guard let data = String(reply[s...e]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let what = (o["what"] as? String) ?? ""
        guard !what.isEmpty else { return nil }
        // Every field here is model-written prose that goes straight onto the
        // screen, so this is the boundary where the house no-dash rule has to be
        // enforced. The system prompt asks for no em dashes and the model
        // complies most of the time, which is exactly what makes an unguarded
        // path dangerous: it looks clean until it is not. Observed live in the
        // Feature Review tab as "catch regressions<em dash>so you can trust".
        // stripDashesOnly rather than clean, because these strings are rendered
        // as prose blocks and the whitespace tidy in clean() is meant for
        // single-line email subjects.
        return FeaturePitch(
            what: DashSanitizer.stripDashesOnly(what),
            reasoning: DashSanitizer.stripDashesOnly((o["reasoning"] as? String) ?? ""),
            helps: DashSanitizer.stripDashesOnly((o["helps"] as? String) ?? ""),
            why: DashSanitizer.stripDashesOnly((o["why"] as? String) ?? ""),
            generatedAt: Date())
    }

    // MARK: Decisions

    func hold(_ id: String) { setStatus(id, .held) }
    func reject(_ id: String) { setStatus(id, .rejected) }

    // MARK: Quality gate

    // Run the in-app quality gate for a staged feature: offline duplication scan
    // + adversarial multi-dimension model review of the commit's real diff. The
    // verdict gates implementToMain. This is the review half of the gate; the
    // build + full test suite are enforced separately by implement-feature.sh.
    func runGate(for id: String) async {
        guard let f = features.first(where: { $0.id == id }), f.branch == "staging" else { return }
        guard !gatingIDs.contains(id) else { return }
        gatingIDs.insert(id)
        verdicts[id] = QualityVerdict(status: .running, dimensions: [], dupFindings: [],
                                   summary: "Reviewing...", diffLineCount: 0, ranAt: Date())
        defer { gatingIDs.remove(id) }
        let diff = gitShow(f.id)
        let dup = SymbolCollisionScanner.scanDiff(diff, repoDir: repoDir)
        let verdict = await QualityGate.run(diff: diff, title: f.title, dupFindings: dup)
        verdicts[id] = verdict
        Persistence.save(verdicts, to: verdictsURL)
        NotificationManager.shared.route(.system, actionRequired: verdict.status == .fail, TriageEnvelope(
            identifier: "grux.gate.\(f.id.prefix(8))",
            title: "Quality gate: \(verdict.status.label)",
            body: "\(f.title). \(verdict.summary)"))
    }

    // Approve a STAGED feature for main. GATED: refuses unless the quality gate
    // has PASSED for this feature (kicks the gate off if it has not run yet).
    // Does NOT run git in-process: writes a merge-intent the guarded
    // tools/implement-feature.sh consumes (cherry-pick + swift test + build-green
    // gate + push), and the intent records the gate verdict so the script can
    // refuse any intent that did not pass review. Two independent gates, both
    // required, so an approved feature can neither slip past review nor break main.
    func implementToMain(_ id: String) {
        guard let f = features.first(where: { $0.id == id }), f.branch == "staging" else { return }
        let verdict = verdicts[id]
        guard verdict?.status == .pass else {
            // Not reviewed (or not passed): do NOT approve. Run the gate instead.
            WakeLog.shared.log("featureReview: blocked implement of \(f.id.prefix(8)) (gate status: \(verdict?.status.rawValue ?? "not run")). Running gate.")
            NotificationManager.shared.route(.system, actionRequired: false, TriageEnvelope(
                identifier: "grux.feature.blocked.\(f.id.prefix(8))",
                title: "Implement blocked: review required",
                body: "\(f.title) has not passed the quality gate. Running review now."))
            if verdict == nil || verdict?.status == .error { Task { await runGate(for: id) } }
            return
        }
        setStatus(id, .approved)
        let v = verdict!
        let intent: [String: Any] = [
            "sha": f.id, "title": f.title,
            "approvedAt": ISO8601DateFormatter().string(from: Date()),
            "gateStatus": "PASS",
            "gateSummary": v.summary,
            "gateRanAt": ISO8601DateFormatter().string(from: v.ranAt)]
        if let data = try? JSONSerialization.data(withJSONObject: intent, options: [.prettyPrinted]) {
            try? Persistence.write(data, to: mergeIntentURL)
        }
        WakeLog.shared.log("featureReview: approved \(f.id.prefix(8)) for main (gate PASS). Run tools/implement-feature.sh to land it (test + green gated).")
        NotificationManager.shared.route(.system, actionRequired: true, TriageEnvelope(
            identifier: "grux.feature.approve.\(f.id.prefix(8))",
            title: "Feature approved for main",
            body: "\(f.title). Passed review; merge runs test + green gated via implement-feature.sh."))
    }

    private func setStatus(_ id: String, _ status: FeatureStatus) {
        guard let i = features.firstIndex(where: { $0.id == id }) else { return }
        features[i].status = status
        save()
    }

    // MARK: git (read-only here; writes happen only in the guarded script)

    private func gitLog(_ range: String, main: Bool = false) -> [(String, String)] {
        let args = main ? ["log", range, "--pretty=%H%x09%s"] : ["log", range, "--pretty=%H%x09%s"]
        let out = runGit(args)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1])
        }
    }

    private func gitShowStat(_ sha: String) -> String {
        return runGit(["show", "--stat", "--oneline", sha]).split(separator: "\n").prefix(25).joined(separator: "\n")
    }

    // Full unified diff of a single commit, for the quality gate to review.
    private func gitShow(_ sha: String) -> String {
        return runGit(["show", "--format=%s%n%b", "-U3", sha])
    }

    private func runGit(_ args: [String]) -> String {
        // No configured checkout means no repo to read. Return the same empty
        // output a failed git call would, so every caller's existing
        // no-output path handles it and nothing has to learn a new failure mode.
        let dir = repoDir
        guard !dir.isEmpty else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Persistence

    private func load() { features = Persistence.load([ReviewFeature].self, from: storeURL, fallback: []) }
    private func save() { Persistence.save(features, to: storeURL) }
}
