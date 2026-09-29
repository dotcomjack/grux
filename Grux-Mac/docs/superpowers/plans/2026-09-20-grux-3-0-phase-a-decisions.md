# Grux 3.0 Phase A: the decision engine and always-armed listening

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every judgment Grux makes has one shape, is served by Jev when a key exists and on device otherwise, is recorded with latency and cost, and drives always-on listening that acts on the spot for reversible commands and never on anything destructive.

**Architecture:** `Sources/Grux/Decisions/` holds the model, two providers, the engine and the ledger. `VoiceCommandRouter` turns each ambient transcript chunk into one Choice question over Grux's live command vocabulary and executes under `HandsFreePolicy`. `ListeningController` owns the three listening modes and is the only thing that starts or stops the wake and ambient listeners. The existing judgment points call the engine and keep their old code as the local path.

**Tech Stack:** Swift, SwiftUI, URLSession, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-grux-3-0-design.md` (sections 1, 2, 5). Roadmap: `2026-09-20-grux-3-0-roadmap.md`.

## Global Constraints

- Build worktree, branch `main`, commit and push per task.
- Test floor 2502 executed, 0 failures.
- No em or en dashes anywhere. Numerals with the dollar sign.
- The key is read only via `KeychainStore.get(.typesafeApiKey)`. Never logged, never persisted elsewhere.
- Audio never leaves the machine; only text reaches the provider, only with a key.
- Destructive actions never execute on a decision alone.
- `NoTelemetryInSourcesTests` and `NoPersonalIdentityTests` stay green; the provider host is a user-keyed API like the Anthropic host already in the tree.
- Provider timeout 3 seconds; on any failure the engine falls back to the local provider and records `provider: local`.

---

### Task A1: The Keychain slot for the decision-provider key

**Files:**
- Modify: `Sources/Grux/KeychainStore.swift:30-92` (the `Key` enum)
- Test: `Tests/GruxTests/KeychainStoreTypesafeKeyTests.swift`

**Interfaces:**
- Produces: `KeychainStore.Key.typesafeApiKey` with raw value `"typesafeApiKey"`.

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class KeychainStoreTypesafeKeyTests: XCTestCase {
    func test_typesafeKeyCaseExists_andIsStableString() {
        // The raw value is the Keychain account name, so it must never change
        // once shipped: a rename would orphan every user's stored key.
        XCTAssertEqual(KeychainStore.Key.typesafeApiKey.rawValue, "typesafeApiKey")
    }
}
```

- [x] **Step 2: Run it to verify it fails**

Run: `swift test --filter KeychainStoreTypesafeKeyTests`
Expected: compile error, `typesafeApiKey` has no member.

- [x] **Step 3: Add the case**

In `KeychainStore.Key`, after `case braveApiKey  // Brave Search API key for the web research tool.` add:

```swift
        case typesafeApiKey     // key.typesafe, the Jev decision model. Optional; on-device matching without it.
```

- [x] **Step 4: Run the test and the migrator suite**

Run: `swift test --filter "KeychainStoreTypesafeKeyTests|KeychainServiceMigratorTests"`
Expected: PASS. The migrator test asserts every live SERVICE has a row; a new account under the existing service needs none.

- [x] **Step 5: Commit**

```bash
git add Sources/Grux/KeychainStore.swift Tests/GruxTests/KeychainStoreTypesafeKeyTests.swift
git commit -F - <<'EOF'
The Keychain has a slot for the decision-provider key

Jev is optional and bring-your-own. The slot exists so Settings has somewhere
to write it and nothing else in the app ever holds the value.
EOF
git push
```

---

### Task A2: The decision model and the Jev provider

**Files:**
- Create: `Sources/Grux/Decisions/DecisionModel.swift`
- Create: `Sources/Grux/Decisions/JevDecisionProvider.swift`
- Test: `Tests/GruxTests/JevDecisionProviderTests.swift`

**Interfaces:**
- Produces:
  - `enum DecisionQuestion { case choice(instructions: String, criteria: [String: String]); case noul(instructions: String); case score(instructions: String, levels: [String]) }`
  - `enum DecisionAnswer: Equatable { case choice(String, confidence: Double, probabilities: [String: Double]); case noul(Double); case score(Double, confidence: Double) }`
  - `enum DecisionProviderKind: String, Codable { case jev, local }`
  - `struct DecisionResult { answers, latencyMs, inputTokens, outputTokens, provider }`
  - `protocol DecisionProvider { var kind: DecisionProviderKind { get }; func decide(state:questions:) async throws -> DecisionResult }`
  - `struct JevDecisionProvider: DecisionProvider` with `static func requestBody(state:questions:) -> [String: Any]` and `static func parse(_ data: Data, latencyMs: Int) throws -> DecisionResult`.

- [x] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Grux

final class JevDecisionProviderTests: XCTestCase {
    // The exact response shape observed from the provider on 2026-09-20.
    private let canned = """
    {"model":"jev-1.13.0","answers":{
      "is_destructive":{"type":"noul","noul":0.77},
      "intent":{"type":"choice","choice":"run_shell_command","confidence":0.99,
                "probabilities":{"send_email":0.0,"other":0.0,"answer_question":0.0,"write_code":0.0,"run_shell_command":1.0}},
      "severity":{"type":"score","score":1.43,"confidence":0.35,"probabilities":{"0":0.0,"1":0.57,"2":0.43}}
    },"usage":{"input_tokens":414,"output_tokens":78}}
    """.data(using: .utf8)!

    func test_parse_readsAllThreePrimitivesAndUsage() throws {
        let r = try JevDecisionProvider.parse(canned, latencyMs: 577)
        XCTAssertEqual(r.provider, .jev)
        XCTAssertEqual(r.latencyMs, 577)
        XCTAssertEqual(r.inputTokens, 414)
        XCTAssertEqual(r.outputTokens, 78)
        XCTAssertEqual(r.answers["is_destructive"], .noul(0.77))
        XCTAssertEqual(r.answers["intent"], .choice("run_shell_command", confidence: 0.99,
            probabilities: ["send_email": 0, "other": 0, "answer_question": 0, "write_code": 0, "run_shell_command": 1]))
        XCTAssertEqual(r.answers["severity"], .score(1.43, confidence: 0.35))
    }

    func test_requestBody_usesCriteriaMapForChoiceAndLevelsForScore() throws {
        let body = JevDecisionProvider.requestBody(state: "close everything", questions: [
            "intent": .choice(instructions: "What did they ask?", criteria: ["close_all": "close every window", "not_a_command": "talking to someone else"]),
            "urgent": .noul(instructions: "Is it urgent?"),
            "risk": .score(instructions: "How risky?", levels: ["harmless", "reversible", "irreversible"]),
        ])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        XCTAssertEqual(body["state"] as? String, "close everything")
        let qs = try XCTUnwrap(body["questions"] as? [String: Any])
        let intent = try XCTUnwrap(qs["intent"] as? [String: Any])
        XCTAssertEqual(intent["type"] as? String, "choice")
        XCTAssertEqual((intent["criteria"] as? [String: String])?["close_all"], "close every window")
        let risk = try XCTUnwrap(qs["risk"] as? [String: Any])
        XCTAssertEqual(risk["criteria"] as? [String], ["harmless", "reversible", "irreversible"])
        XCTAssertEqual((qs["urgent"] as? [String: Any])?["type"] as? String, "noul")
    }

    func test_parse_rejectsMissingAnswers() {
        XCTAssertThrowsError(try JevDecisionProvider.parse("{}".data(using: .utf8)!, latencyMs: 1))
    }

    func test_decide_withoutKeyThrowsBeforeAnyNetwork() async {
        let p = JevDecisionProvider(apiKey: "")
        do { _ = try await p.decide(state: "x", questions: ["q": .noul(instructions: "y")]); XCTFail("expected a throw") }
        catch let e as JevDecisionProvider.Failure { XCTAssertEqual(e, .noKey) }
        catch { XCTFail("wrong error \(error)") }
    }
}
```

- [x] **Step 2: Run to verify they fail**

Run: `swift test --filter JevDecisionProviderTests`
Expected: compile errors, the types do not exist.

- [x] **Step 3: Write the model**

`Sources/Grux/Decisions/DecisionModel.swift`:

```swift
import Foundation

// One shape for every small judgment Grux makes. A provider answers typed
// questions about a piece of state with a confidence attached; the engine
// picks the provider and the ledger records the cost. Text generation never
// goes through here, only decisions.

enum DecisionQuestion: Equatable {
    /// Pick one option. `criteria` maps an option name to its description.
    case choice(instructions: String, criteria: [String: String])
    /// A probability that a yes/no statement holds.
    case noul(instructions: String)
    /// A position on an ordered scale. `levels` runs from low to high.
    case score(instructions: String, levels: [String])
}

enum DecisionAnswer: Equatable {
    case choice(String, confidence: Double, probabilities: [String: Double])
    case noul(Double)
    case score(Double, confidence: Double)

    /// The confidence a router compares against the execute threshold.
    var confidence: Double {
        switch self {
        case .choice(_, let c, _): return c
        case .noul(let p): return max(p, 1 - p)
        case .score(_, let c): return c
        }
    }
}

enum DecisionProviderKind: String, Codable, Equatable {
    case jev, local
}

struct DecisionResult: Equatable {
    let answers: [String: DecisionAnswer]
    let latencyMs: Int
    let inputTokens: Int
    let outputTokens: Int
    let provider: DecisionProviderKind
}

protocol DecisionProvider {
    var kind: DecisionProviderKind { get }
    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult
}
```

- [x] **Step 4: Write the Jev provider**

`Sources/Grux/Decisions/JevDecisionProvider.swift`:

```swift
import Foundation

/// TypeSafe's Jev: typed decisions with calibrated confidence, about half a
/// second round trip. Bring your own key; without one this provider is never
/// constructed by the engine. The request and response shapes here are the
/// ones observed on 2026-09-20 and pinned by JevDecisionProviderTests.
struct JevDecisionProvider: DecisionProvider {
    let kind: DecisionProviderKind = .jev

    enum Failure: Error, Equatable {
        case noKey
        case http(Int)
        case malformed
    }

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 3
            cfg.timeoutIntervalForResource = 5
            self.session = URLSession(configuration: cfg)
        }
    }

    static func requestBody(state: String, questions: [String: DecisionQuestion]) -> [String: Any] {
        var qs: [String: Any] = [:]
        for (name, q) in questions {
            switch q {
            case .choice(let instructions, let criteria):
                qs[name] = ["type": "choice", "instructions": instructions, "criteria": criteria]
            case .noul(let instructions):
                qs[name] = ["type": "noul", "instructions": instructions]
            case .score(let instructions, let levels):
                qs[name] = ["type": "score", "instructions": instructions, "criteria": levels]
            }
        }
        return ["state": state, "model": model, "questions": qs]
    }

    static func parse(_ data: Data, latencyMs: Int) throws -> DecisionResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { throw Failure.malformed }
        var out: [String: DecisionAnswer] = [:]
        for (name, raw) in answers {
            guard let a = raw as? [String: Any], let type = a["type"] as? String else { throw Failure.malformed }
            switch type {
            case "choice":
                guard let choice = a["choice"] as? String else { throw Failure.malformed }
                out[name] = .choice(choice,
                                    confidence: (a["confidence"] as? Double) ?? 0,
                                    probabilities: (a["probabilities"] as? [String: Double]) ?? [:])
            case "noul":
                guard let p = a["noul"] as? Double else { throw Failure.malformed }
                out[name] = .noul(p)
            case "score":
                guard let s = a["score"] as? Double else { throw Failure.malformed }
                out[name] = .score(s, confidence: (a["confidence"] as? Double) ?? 0)
            default:
                throw Failure.malformed
            }
        }
        let usage = root["usage"] as? [String: Any]
        return DecisionResult(answers: out,
                              latencyMs: latencyMs,
                              inputTokens: (usage?["input_tokens"] as? Int) ?? 0,
                              outputTokens: (usage?["output_tokens"] as? Int) ?? 0,
                              provider: .jev)
    }

    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("https://gruxai.com", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Grux OS: decisions", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(state: state, questions: questions))
        let started = Date()
        let (data, response) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return try Self.parse(data, latencyMs: ms)
    }
}
```

- [x] **Step 5: Run the tests**

Run: `swift test --filter JevDecisionProviderTests`
Expected: 4 passed.

- [x] **Step 6: Commit**

```bash
git add Sources/Grux/Decisions/DecisionModel.swift Sources/Grux/Decisions/JevDecisionProvider.swift Tests/GruxTests/JevDecisionProviderTests.swift
git commit -F - <<'EOF'
Every small judgment has one shape, and Jev is the first provider

Choice, Noul and Score questions with a confidence on the answer. The request
and response shapes are the ones the provider actually returned on
2026-09-20, pinned by test so a shape change fails here and not in the mic.
EOF
git push
```

---

### Task A3: The local provider, the ledger and the engine

**Files:**
- Create: `Sources/Grux/Decisions/LocalDecisionProvider.swift`
- Create: `Sources/Grux/Decisions/DecisionLedger.swift`
- Create: `Sources/Grux/Decisions/DecisionEngine.swift`
- Test: `Tests/GruxTests/LocalDecisionProviderTests.swift`, `Tests/GruxTests/DecisionEngineTests.swift`

**Interfaces:**
- Consumes: Task A2 types; `ChatIntentClassifier.containsAnyWord(_:keywords:)` (`Chat/IntentClassifier.swift:55`); `KeychainStore.get(.typesafeApiKey)`; `Persistence.supportDir`.
- Produces:
  - `struct LocalDecisionProvider: DecisionProvider` with `static func matchChoice(state:criteria:) -> DecisionAnswer`.
  - `struct DecisionLedgerEntry: Codable, Equatable { surface, provider, latencyMs, inputTokens, outputTokens, costUSD, at, summary }`
  - `final class DecisionLedger: ObservableObject { static let shared; @Published private(set) var last: DecisionLedgerEntry?; func record(_:); func today() -> (count: Int, avgLatencyMs: Int, costUSD: Double); static let jevInputUSDPerMillion = 0.042 }`
  - `final class DecisionEngine { static let shared; init(keyLookup:ledger:); func decide(surface:state:questions:) async -> DecisionResult }`

Criteria descriptions may hold several phrases separated by ` | `; the local provider treats each as an exact spoken phrase. Jev reads them as prose. One vocabulary serves both.

- [x] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Grux

final class LocalDecisionProviderTests: XCTestCase {
    let criteria = [
        "close_all": "close everything | close all windows | clear my screen",
        "open_calendar": "open my calendar | show the calendar",
        "not_a_command": "talking to someone else, thinking out loud, or nothing Grux can do",
    ]

    func test_exactPhrase_winsWithHighConfidence() {
        let a = LocalDecisionProvider.matchChoice(state: "okay close everything please", criteria: criteria)
        guard case .choice(let opt, let conf, _) = a else { return XCTFail("not a choice") }
        XCTAssertEqual(opt, "close_all")
        XCTAssertGreaterThanOrEqual(conf, 0.9)
    }

    func test_chatter_fallsToNotACommand() {
        let a = LocalDecisionProvider.matchChoice(state: "so I was thinking about the pricing page", criteria: criteria)
        guard case .choice(let opt, let conf, _) = a else { return XCTFail("not a choice") }
        XCTAssertEqual(opt, "not_a_command")
        XCTAssertGreaterThan(conf, 0.5)
    }

    func test_partialWords_scoreBelowExecuteThreshold() {
        let a = LocalDecisionProvider.matchChoice(state: "the calendar thing", criteria: criteria)
        guard case .choice(_, let conf, _) = a else { return XCTFail("not a choice") }
        XCTAssertLessThan(conf, 0.70)
    }

    func test_noul_isNeverConfidentOnDevice() async throws {
        let r = try await LocalDecisionProvider().decide(state: "anything", questions: ["q": .noul(instructions: "Is it urgent?")])
        XCTAssertEqual(r.answers["q"], .noul(0.5))
        XCTAssertEqual(r.provider, .local)
    }
}

@MainActor
final class DecisionEngineTests: XCTestCase {
    private struct Failing: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            throw JevDecisionProvider.Failure.http(500)
        }
    }

    func test_withoutKey_usesLocalAndRecords() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "" }, ledger: ledger)
        let r = await engine.decide(surface: "test", state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything", "not_a_command": "chatter"])])
        XCTAssertEqual(r.provider, .local)
        XCTAssertEqual(ledger.last?.surface, "test")
        XCTAssertEqual(ledger.last?.costUSD, 0)
    }

    func test_remoteFailure_fallsBackToLocal() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in Failing() })
        let r = await engine.decide(surface: "test", state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything", "not_a_command": "chatter"])])
        XCTAssertEqual(r.provider, .local)
    }

    func test_ledgerCost_isInputTokensAtTheJevRate() {
        let ledger = DecisionLedger(storeURL: nil)
        ledger.record(DecisionLedgerEntry(surface: "s", provider: .jev, latencyMs: 500, inputTokens: 1_000_000, outputTokens: 10, at: Date(), summary: "x"))
        XCTAssertEqual(ledger.last?.costUSD ?? -1, 0.042, accuracy: 1e-9)
        let t = ledger.today()
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.avgLatencyMs, 500)
    }
}
```

- [x] **Step 2: Run to verify they fail**

Run: `swift test --filter "LocalDecisionProviderTests|DecisionEngineTests"`
Expected: compile errors.

- [x] **Step 3: Write the local provider**

`Sources/Grux/Decisions/LocalDecisionProvider.swift`:

```swift
import Foundation

/// The on-device provider. Exact spoken phrases and whole-word overlap, no
/// network, no key. It is what everyone gets before they add a key, so its
/// confidence is honest: an exact phrase clears the execute threshold, a few
/// shared words do not, and a yes/no question it cannot judge answers 0.5.
struct LocalDecisionProvider: DecisionProvider {
    let kind: DecisionProviderKind = .local

    static let notACommand = "not_a_command"

    func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        let started = Date()
        var out: [String: DecisionAnswer] = [:]
        for (name, q) in questions {
            switch q {
            case .choice(_, let criteria): out[name] = Self.matchChoice(state: state, criteria: criteria)
            case .noul: out[name] = .noul(0.5)
            case .score: out[name] = .score(0, confidence: 0)
            }
        }
        return DecisionResult(answers: out,
                              latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                              inputTokens: 0, outputTokens: 0, provider: .local)
    }

    static func matchChoice(state: String, criteria: [String: String]) -> DecisionAnswer {
        let lowered = state.lowercased()
        var scores: [String: Double] = [:]
        for (option, description) in criteria where option != notACommand {
            let phrases = description.lowercased()
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if phrases.contains(where: { lowered.contains($0) }) {
                scores[option] = 0.95
                continue
            }
            let words = Set(phrases.joined(separator: " ").split { !$0.isLetter }.map(String.init).filter { $0.count > 2 })
            guard !words.isEmpty else { scores[option] = 0; continue }
            let hits = words.filter { ChatIntentClassifier.containsAnyWord(lowered, keywords: [$0]) }.count
            scores[option] = 0.6 * Double(hits) / Double(words.count)
        }
        let best = scores.max { $0.value < $1.value }
        let bestScore = best?.value ?? 0
        if let best, bestScore >= 0.5 {
            var probs = scores
            probs[notACommand] = max(0, 1 - bestScore)
            return .choice(best.key, confidence: bestScore, probabilities: probs)
        }
        var probs = scores
        probs[notACommand] = 1 - bestScore
        return .choice(notACommand, confidence: 1 - bestScore, probabilities: probs)
    }
}
```

- [x] **Step 4: Write the ledger**

`Sources/Grux/Decisions/DecisionLedger.swift`:

```swift
import Foundation
import Combine

struct DecisionLedgerEntry: Codable, Equatable {
    let surface: String
    let provider: DecisionProviderKind
    let latencyMs: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
    let at: Date
    /// One line a person can read: what was heard and what was decided.
    let summary: String

    init(surface: String, provider: DecisionProviderKind, latencyMs: Int, inputTokens: Int,
         outputTokens: Int, at: Date, summary: String) {
        self.surface = surface
        self.provider = provider
        self.latencyMs = latencyMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.at = at
        self.summary = summary
        self.costUSD = provider == .jev
            ? Double(inputTokens) / 1_000_000 * DecisionLedger.jevInputUSDPerMillion
            : 0
    }
}

/// Every decision, with its latency and cost, kept locally as one JSON line
/// per record. This is what the orb hover, the Usage card and the morning
/// briefing read. Nothing here is sent anywhere.
@MainActor
final class DecisionLedger: ObservableObject {
    static let shared = DecisionLedger(storeURL: Persistence.supportDir.appendingPathComponent("decisions.jsonl"))

    /// Jev input price observed 2026-09-20. Output is free. Change here only.
    static let jevInputUSDPerMillion = 0.042

    @Published private(set) var last: DecisionLedgerEntry?
    @Published private(set) var recent: [DecisionLedgerEntry] = []

    private let storeURL: URL?
    private let maxRecent = 2_000

    init(storeURL: URL?) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recent = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(DecisionLedgerEntry.self, from: Data($0)) }
            last = recent.last
        }
    }

    func record(_ r: DecisionLedgerEntry) {
        recent.append(r)
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
        last = r
        guard let storeURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(r) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: storeURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: storeURL, options: .atomic)
        }
    }

    func today(now: Date = Date()) -> (count: Int, avgLatencyMs: Int, costUSD: Double) {
        let start = Calendar.current.startOfDay(for: now)
        let rows = recent.filter { $0.at >= start }
        guard !rows.isEmpty else { return (0, 0, 0) }
        let avg = rows.map(\.latencyMs).reduce(0, +) / rows.count
        return (rows.count, avg, rows.map(\.costUSD).reduce(0, +))
    }
}
```

- [x] **Step 5: Write the engine**

`Sources/Grux/Decisions/DecisionEngine.swift`:

```swift
import Foundation

/// Picks the provider and records the outcome. Jev when a key is present,
/// otherwise on device; and on any provider failure, on device, so a decision
/// is always returned. Callers never see a throw.
@MainActor
final class DecisionEngine {
    static let shared = DecisionEngine(
        keyLookup: { KeychainStore.get(.typesafeApiKey) },
        ledger: DecisionLedger.shared)

    private let keyLookup: () -> String
    private let ledger: DecisionLedger
    private let remote: (String) -> DecisionProvider
    private let local: DecisionProvider = LocalDecisionProvider()

    init(keyLookup: @escaping () -> String,
         ledger: DecisionLedger,
         remote: @escaping (String) -> DecisionProvider = { JevDecisionProvider(apiKey: $0) }) {
        self.keyLookup = keyLookup
        self.ledger = ledger
        self.remote = remote
    }

    var hasRemoteKey: Bool { !keyLookup().isEmpty }

    func decide(surface: String, state: String, questions: [String: DecisionQuestion]) async -> DecisionResult {
        let key = keyLookup()
        var result: DecisionResult
        if !key.isEmpty, let r = try? await remote(key).decide(state: state, questions: questions) {
            result = r
        } else {
            result = (try? await local.decide(state: state, questions: questions))
                ?? DecisionResult(answers: [:], latencyMs: 0, inputTokens: 0, outputTokens: 0, provider: .local)
        }
        ledger.record(DecisionLedgerEntry(surface: surface, provider: result.provider, latencyMs: result.latencyMs,
                                     inputTokens: result.inputTokens, outputTokens: result.outputTokens,
                                     at: Date(), summary: Self.summary(state: state, result: result)))
        return result
    }

    static func summary(state: String, result: DecisionResult) -> String {
        let heard = state.count > 60 ? String(state.prefix(57)) + "..." : state
        let decided = result.answers.map { name, a -> String in
            switch a {
            case .choice(let c, let conf, _): return "\(name)=\(c) \(String(format: "%.2f", conf))"
            case .noul(let p): return "\(name)=\(String(format: "%.2f", p))"
            case .score(let s, _): return "\(name)=\(String(format: "%.1f", s))"
            }
        }.sorted().joined(separator: ", ")
        return "\(heard) -> \(decided)"
    }
}
```

- [x] **Step 6: Run the tests**

Run: `swift test --filter "LocalDecisionProviderTests|DecisionEngineTests"`
Expected: 7 passed.

- [x] **Step 7: Commit**

```bash
git add Sources/Grux/Decisions/LocalDecisionProvider.swift Sources/Grux/Decisions/DecisionLedger.swift Sources/Grux/Decisions/DecisionEngine.swift Tests/GruxTests/LocalDecisionProviderTests.swift Tests/GruxTests/DecisionEngineTests.swift
git commit -F - <<'EOF'
The engine answers every decision, with or without a key, and writes the bill

On device by default, Jev the moment a key exists, on device again if the
provider ever fails, so callers never see a throw. Every answer lands in a
local ledger with its latency and cost, which is what the orb, the Usage card
and the morning briefing will read.
EOF
git push
```

---

### Task A4: Listening mode in config, with migration

**Files:**
- Modify: `Sources/Grux/Models.swift` (the `ListeningMode` enum near `AmbientMode` at line 170; `GruxConfig` fields, `CodingKeys`, memberwise init, `.default`, and `init(from:)` near line 1035)
- Test: `Tests/GruxTests/ListeningModeMigrationTests.swift`

**Interfaces:**
- Produces: `enum ListeningMode: String, Codable, CaseIterable, Identifiable { case alwaysOn, wakeWord, off }` with `label` and `explanation`; `GruxConfig.listeningMode`, `listeningThreshold` (0.70), `listeningBannerExplained` (false), `showLastDecision` (true).
- Migration rule: a saved config without `listeningMode` maps to `.wakeWord` when `wakeWordEnabled` was true and `ambientEnabled` false; `.alwaysOn` when `ambientEnabled` was true; `.off` when both were false AND either consent flag had been acknowledged (the person turned it down on purpose); `.alwaysOn` otherwise (a fresh install has never been asked, and the mic consent dialog still gates the first capture).

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class ListeningModeMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> GruxConfig {
        try JSONDecoder().decode(GruxConfig.self, from: json.data(using: .utf8)!)
    }

    func test_freshConfig_isAlwaysOnWithDefaults() throws {
        let c = try decode("{}")
        XCTAssertEqual(c.listeningMode, .alwaysOn)
        XCTAssertEqual(c.listeningThreshold, 0.70, accuracy: 1e-9)
        XCTAssertFalse(c.listeningBannerExplained)
        XCTAssertTrue(c.showLastDecision)
    }

    func test_oldWakeWordOnly_becomesWakeWord() throws {
        let c = try decode(#"{"wakeWordEnabled":true,"ambientEnabled":false}"#)
        XCTAssertEqual(c.listeningMode, .wakeWord)
    }

    func test_oldAmbientOn_becomesAlwaysOn() throws {
        let c = try decode(#"{"wakeWordEnabled":false,"ambientEnabled":true}"#)
        XCTAssertEqual(c.listeningMode, .alwaysOn)
    }

    func test_deliberatelyOff_staysOff() throws {
        let c = try decode(#"{"wakeWordEnabled":false,"ambientEnabled":false,"wakeWordConsentAcknowledged":true}"#)
        XCTAssertEqual(c.listeningMode, .off)
    }

    func test_explicitValue_wins() throws {
        let c = try decode(#"{"listeningMode":"off","ambientEnabled":true}"#)
        XCTAssertEqual(c.listeningMode, .off)
    }

    func test_labelsHaveNoJargon() {
        for m in ListeningMode.allCases {
            XCTAssertFalse(m.label.lowercased().contains("ambient"), m.label)
            XCTAssertFalse(m.explanation.lowercased().contains("whisper"), m.explanation)
        }
    }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift test --filter ListeningModeMigrationTests`
Expected: compile errors.

- [x] **Step 3: Add the enum next to `AmbientMode` in `Models.swift`**

```swift
/// The one listening control. Replaces the separate wake word, ambient and
/// auto-send switches in the face; those fields stay for the listeners
/// underneath and are derived from this at launch.
public enum ListeningMode: String, Codable, CaseIterable, Identifiable {
    case alwaysOn
    case wakeWord
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .alwaysOn: return "Always on"
        case .wakeWord: return "After \u{201C}Hey Grux\u{201D}"
        case .off: return "Off"
        }
    }

    public var explanation: String {
        switch self {
        case .alwaysOn:
            return "Grux hears you all the time and decides, in under a second, whether you were talking to it. Nothing you say is kept unless you ask it to remember."
        case .wakeWord:
            return "Grux ignores everything until you say Hey Grux, then listens for one request."
        case .off:
            return "The microphone stays closed. Type instead, or tap the orb to talk."
        }
    }
}
```

- [x] **Step 4: Add the four fields to `GruxConfig`**

In the stored properties, after `var ambientMode: AmbientMode`:

```swift
    var listeningMode: ListeningMode
    /// Execute at or above this confidence; ask below it. Tuning owns it.
    var listeningThreshold: Double
    /// The one-time banner that explains the per-decision banners has shown.
    var listeningBannerExplained: Bool
    /// Show the last decision in the menu bar and the HUD.
    var showLastDecision: Bool
```

Add the same four names to `CodingKeys`. In the memberwise `init`, add parameters with defaults `listeningMode: ListeningMode = .alwaysOn, listeningThreshold: Double = 0.70, listeningBannerExplained: Bool = false, showLastDecision: Bool = true` and assign them. In `init(from:)`, after `ambientMode = try c.decodeIfPresent(...)`:

```swift
        listeningThreshold = try c.decodeIfPresent(Double.self, forKey: .listeningThreshold) ?? 0.70
        listeningBannerExplained = try c.decodeIfPresent(Bool.self, forKey: .listeningBannerExplained) ?? false
        showLastDecision = try c.decodeIfPresent(Bool.self, forKey: .showLastDecision) ?? true
        if let explicit = try c.decodeIfPresent(ListeningMode.self, forKey: .listeningMode) {
            listeningMode = explicit
        } else {
            // Migration from the three old switches. A person who turned both
            // off after seeing a consent dialog turned it down on purpose; a
            // fresh install has never been asked and starts always on.
            let turnedDown = !wakeWordEnabled && !ambientEnabled
                && (wakeWordConsentAcknowledged || ambientConsentAcknowledged)
            if ambientEnabled { listeningMode = .alwaysOn }
            else if wakeWordEnabled { listeningMode = .wakeWord }
            else if turnedDown { listeningMode = .off }
            else { listeningMode = .alwaysOn }
        }
```

Note: `wakeWordConsentAcknowledged` and `ambientConsentAcknowledged` are decoded later in `init(from:)` today (line ~1130). Move the two `decodeIfPresent` lines for them ABOVE this block so the migration reads decoded values, not uninitialised ones. The compiler enforces this: it refuses to read a `let`/`var` before assignment in a memberwise decode.

- [x] **Step 5: Run the tests**

Run: `swift test --filter "ListeningModeMigrationTests|GruxConfig"`
Expected: PASS, and every existing config test still passes.

- [x] **Step 6: Commit**

```bash
git add Sources/Grux/Models.swift Tests/GruxTests/ListeningModeMigrationTests.swift
git commit -F - <<'EOF'
One listening control with three states, migrated from the three old switches

Always on is the default for a fresh install; a person who turned the old
switches off after a consent dialog stays off. The threshold and the two tells
live beside it so Tuning has one place to read.
EOF
git push
```

---

### Task A5: Hands-free policy and the voice command router

**Files:**
- Create: `Sources/Grux/Decisions/HandsFreePolicy.swift`
- Create: `Sources/Grux/Decisions/VoiceCommandRouter.swift`
- Test: `Tests/GruxTests/HandsFreePolicyTests.swift`, `Tests/GruxTests/VoiceCommandRouterTests.swift`, `Tests/GruxTests/DestructiveNeverTests.swift`

**Interfaces:**
- Consumes: `DecisionEngine.decide`, `SidebarIA.groups` (`DesignSystem/SidebarModel.swift:27`), `VoiceMacroRegistry.shared.macros` and `run(name:)` (`VoiceMacros.swift:353,540`), `AppDelegate.shared?.openLaunchWindow(tab:)` (`GruxApp.swift:3325`), `ApprovalQueue.shared.enqueue(_:urgent:persona:reason:)` (`Jax/ApprovalQueue.swift:159`), `AppState.shared.micMuted`, `MeetingPanelController` start/stop (read the exact call at implementation time in `Meeting/MeetingPanelController.swift` and record it in this task's commit).
- Produces:
  - `enum HandsFreeClass { case onTheSpot, asksFirst, never }`
  - `struct VoiceCommand { let id: String; let phrases: [String]; let klass: HandsFreeClass; let run: () async -> String }`
  - `enum HandsFreePolicy { static func classify(macro: Macro) -> HandsFreeClass; static func classify(action: MacroAction) -> HandsFreeClass }`
  - `struct VoiceDecisionEvent { heard, commandId, confidence, latencyMs, provider, outcome }` with `enum Outcome { case executed, askedFirst, refused, ignored }`
  - `@MainActor final class VoiceCommandRouter: ObservableObject { static let shared; @Published private(set) var events: [VoiceDecisionEvent]; func consider(chunk: String) async -> VoiceDecisionEvent?; func vocabulary() -> [VoiceCommand] }`

- [x] **Step 1: Write the failing tests**

```swift
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

@MainActor
final class VoiceCommandRouterTests: XCTestCase {
    private func router(threshold: Double = 0.70, key: String = "") -> VoiceCommandRouter {
        let engine = DecisionEngine(keyLookup: { key }, ledger: DecisionLedger(storeURL: nil))
        return VoiceCommandRouter(engine: engine, threshold: { threshold })
    }

    func test_navigationPhrase_executesOnTheSpot() async {
        let r = router()
        var opened: String?
        r.navigate = { opened = $0 }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.outcome, .executed)
        XCTAssertEqual(opened, "calendar")
    }

    func test_chatter_isIgnored() async {
        let r = router()
        let e = await r.consider(chunk: "so anyway I was thinking about lunch")
        XCTAssertEqual(e?.outcome, .ignored)
    }

    func test_belowThreshold_asks() async {
        let r = router(threshold: 0.99)
        var asked = 0
        r.askFirst = { _ in asked += 1 }
        let e = await r.consider(chunk: "open my calendar")
        XCTAssertEqual(e?.outcome, .askedFirst)
        XCTAssertEqual(asked, 1)
    }

    func test_vocabularyAlwaysCarriesNotACommand() {
        XCTAssertTrue(router().vocabulary().contains { $0.id == LocalDecisionProvider.notACommand })
    }
}

@MainActor
final class DestructiveNeverTests: XCTestCase {
    /// A provider that is certain the chunk is a shell command. The router must
    /// still refuse, because shell is a `never` class, not a confidence question.
    private struct Certain: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            DecisionResult(answers: ["intent": .choice("macro:wipe", confidence: 0.99, probabilities: ["macro:wipe": 0.99])],
                           latencyMs: 1, inputTokens: 1, outputTokens: 1, provider: .jev)
        }
    }

    func test_certainShellCommand_isRefusedNotExecuted() async {
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: DecisionLedger(storeURL: nil), remote: { _ in Certain() })
        let wipe = Macro(name: "wipe", triggers: ["wipe it"], description: "", rawActions: [.runShell(command: "rm -rf ~")])
        let r = VoiceCommandRouter(engine: engine, threshold: { 0.70 }, macros: { [wipe] })
        var ran = false
        r.runMacro = { _ in ran = true; return "" }
        let e = await r.consider(chunk: "wipe it")
        XCTAssertEqual(e?.outcome, .refused)
        XCTAssertFalse(ran)
    }
}
```

- [x] **Step 2: Run to verify they fail**

Run: `swift test --filter "HandsFreePolicyTests|VoiceCommandRouterTests|DestructiveNeverTests"`
Expected: compile errors.

- [x] **Step 3: Write the policy**

`Sources/Grux/Decisions/HandsFreePolicy.swift`:

```swift
import Foundation

/// What a spoken command may do without asking. Fixed by design, not a
/// setting: reversible things happen on the spot, anything that reaches
/// another person or cannot be undone stops in Approvals first, and shell,
/// publishing, payments and permission grants never run by voice alone.
enum HandsFreeClass: Equatable {
    case onTheSpot
    case asksFirst
    case never
}

enum HandsFreePolicy {
    static func classify(action: MacroAction) -> HandsFreeClass {
        switch action {
        case .runShell, .runInTerminalCell, .runAppleScript, .speakShellOutput:
            return .never
        case .launchApp, .openURL, .spawnTerminalsToGrid, .enableTerminalFocusOverlay,
             .disableTerminalFocusOverlay, .playMusic, .prepareCleanWorkspace, .speak,
             .delay, .awaitSilence, .openEmpireDashboard:
            return .onTheSpot
        }
    }

    /// A macro is as strict as its strictest enabled step.
    static func classify(macro: Macro) -> HandsFreeClass {
        var worst: HandsFreeClass = .onTheSpot
        for step in macro.actions where step.enabled {
            switch classify(action: step.action) {
            case .never: return .never
            case .asksFirst: worst = .asksFirst
            case .onTheSpot: break
            }
        }
        return worst
    }
}
```

If `MacroAction` has gained cases since 2026-09-20, the `switch` will not compile until each is placed; place shell-shaped ones under `.never` and everything else under `.onTheSpot`. Do not add a `default`.

- [x] **Step 4: Write the router**

`Sources/Grux/Decisions/VoiceCommandRouter.swift`:

```swift
import Foundation
import Combine

struct VoiceCommand {
    let id: String
    let phrases: [String]
    let klass: HandsFreeClass
    let run: () async -> String
}

struct VoiceDecisionEvent: Identifiable, Equatable {
    enum Outcome: Equatable { case executed, askedFirst, refused, ignored }
    let id = UUID()
    let at = Date()
    let heard: String
    let commandId: String
    let confidence: Double
    let latencyMs: Int
    let provider: DecisionProviderKind
    let outcome: Outcome
}

/// Turns each transcript chunk into one question: which command, if any. The
/// vocabulary is built fresh per chunk from the live sidebar and the person's
/// own macros, so a new macro is speakable the moment it is saved.
@MainActor
final class VoiceCommandRouter: ObservableObject {
    static let shared = VoiceCommandRouter(
        engine: DecisionEngine.shared,
        threshold: { AppState.shared.config.listeningThreshold })

    @Published private(set) var events: [VoiceDecisionEvent] = []
    private let maxEvents = 200

    private let engine: DecisionEngine
    private let threshold: () -> Double
    private let macros: () -> [Macro]

    // Seams for tests and for the app to wire at launch. Defaults reach the
    // real surfaces.
    var navigate: (String) -> Void = { AppDelegate.shared?.openLaunchWindow(tab: $0) }
    var runMacro: (String) async -> String = { await VoiceMacroRegistry.shared.run(name: $0) }
    var askFirst: (VoiceCommand) -> Void = { cmd in
        ApprovalQueue.shared.enqueue(
            ProposedAction(kind: .other, summary: "You said: \(cmd.phrases.first ?? cmd.id)", target: cmd.id),
            urgent: true, persona: .owner, reason: "Spoken command that asks first")
    }
    var setMuted: (Bool) -> Void = { AppState.shared.micMuted = $0 }

    init(engine: DecisionEngine, threshold: @escaping () -> Double,
         macros: @escaping () -> [Macro] = { VoiceMacroRegistry.shared.macros }) {
        self.engine = engine
        self.threshold = threshold
        self.macros = macros
    }

    // MARK: Vocabulary

    func vocabulary() -> [VoiceCommand] {
        var out: [VoiceCommand] = []
        for group in SidebarIA.groups {
            for item in group.items {
                let label = item.label.lowercased()
                out.append(VoiceCommand(id: "tab:\(item.key)",
                                        phrases: ["open \(label)", "open my \(label)", "show \(label)", "go to \(label)", "show me \(label)"],
                                        klass: .onTheSpot,
                                        run: { [navigate] in navigate(item.key); return "opened \(label)" }))
            }
        }
        out.append(VoiceCommand(id: "mute", phrases: ["mute", "stop listening", "grux mute"], klass: .onTheSpot,
                                run: { [setMuted] in setMuted(true); return "muted" }))
        out.append(VoiceCommand(id: "unmute", phrases: ["unmute", "start listening again"], klass: .onTheSpot,
                                run: { [setMuted] in setMuted(false); return "listening" }))
        for m in macros() where m.enabled {
            let klass = HandsFreePolicy.classify(macro: m)
            let name = m.name
            out.append(VoiceCommand(id: "macro:\(name)", phrases: m.triggers, klass: klass,
                                    run: { [runMacro] in await runMacro(name) }))
        }
        out.append(VoiceCommand(id: LocalDecisionProvider.notACommand,
                                phrases: ["talking to someone else", "thinking out loud", "nothing for Grux to do"],
                                klass: .onTheSpot, run: { "" }))
        return out
    }

    private func criteria(for vocab: [VoiceCommand]) -> [String: String] {
        var c: [String: String] = [:]
        for v in vocab { c[v.id] = v.phrases.joined(separator: " | ") }
        return c
    }

    // MARK: Routing

    @discardableResult
    func consider(chunk: String) async -> VoiceDecisionEvent? {
        let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        let vocab = vocabulary()
        let result = await engine.decide(
            surface: "voice",
            state: text,
            questions: ["intent": .choice(instructions: "Which of these did the person just ask Grux to do, if any?",
                                          criteria: criteria(for: vocab))])
        guard case .choice(let id, let confidence, _)? = result.answers["intent"] else { return nil }
        let outcome: VoiceDecisionEvent.Outcome
        if id == LocalDecisionProvider.notACommand || confidence < 0.5 {
            outcome = .ignored
        } else if let cmd = vocab.first(where: { $0.id == id }) {
            switch cmd.klass {
            case .never:
                outcome = .refused
            case .asksFirst:
                askFirst(cmd); outcome = .askedFirst
            case .onTheSpot:
                if confidence >= threshold() { _ = await cmd.run(); outcome = .executed }
                else { askFirst(cmd); outcome = .askedFirst }
            }
        } else {
            outcome = .ignored
        }
        let event = VoiceDecisionEvent(heard: text, commandId: id, confidence: confidence,
                                       latencyMs: result.latencyMs, provider: result.provider, outcome: outcome)
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        return event
    }
}
```

- [x] **Step 5: Run the tests**

Run: `swift test --filter "HandsFreePolicyTests|VoiceCommandRouterTests|DestructiveNeverTests"`
Expected: 8 passed. Then red-prove `DestructiveNeverTests`: temporarily change `case .never: outcome = .refused` to execute, run, watch it fail, restore, `git diff --stat` shows only the intended files.

- [x] **Step 6: Commit**

```bash
git add Sources/Grux/Decisions/HandsFreePolicy.swift Sources/Grux/Decisions/VoiceCommandRouter.swift Tests/GruxTests/HandsFreePolicyTests.swift Tests/GruxTests/VoiceCommandRouterTests.swift Tests/GruxTests/DestructiveNeverTests.swift
git commit -F - <<'EOF'
Spoken commands act on the spot when reversible and never when they touch a shell

One question per transcript chunk over the live vocabulary: every sidebar
row, mute, and the person's own macros. A macro is as strict as its strictest
step. A provider certain that 'wipe it' means rm -rf is still refused, and a
test plants exactly that.
EOF
git push
```

---

### Task A6: The listening controller, always-armed routing, and mic-status

**Files:**
- Create: `Sources/Grux/Decisions/ListeningController.swift`
- Modify: `Sources/Grux/Ambient/AmbientState.swift:150` (`appendChunk` hands the chunk to the router when the mode is always on)
- Modify: `Sources/Grux/MicController.swift:170-200` (`writeMicStatus` adds `listeningMode`)
- Modify: `Sources/Grux/GruxApp.swift` (launch: `ListeningController.shared.apply()`; the `fire-wake-enable` / `fire-ambient-enable` triggers set `config.listeningMode` and call `apply()`)
- Test: `Tests/GruxTests/ListeningControllerTests.swift`

**Interfaces:**
- Consumes: `WakeWordListener.shared.start()/stop()` (`WakeWord.swift:126,172`), `AmbientListener.shared.start()/stop()` (`AmbientListener.swift:90,142`), `AmbientState.shared`, `VoiceCommandRouter.shared.consider(chunk:)`.
- Produces: `@MainActor final class ListeningController { static let shared; init(startWake:stopWake:startAmbient:stopAmbient:); func apply(mode: ListeningMode) async; var current: ListeningMode }`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

@MainActor
final class ListeningControllerTests: XCTestCase {
    private var log: [String] = []
    private func make() -> ListeningController {
        ListeningController(startWake: { self.log.append("wake+") }, stopWake: { self.log.append("wake-") },
                            startAmbient: { self.log.append("amb+") }, stopAmbient: { self.log.append("amb-") })
    }

    func test_alwaysOn_runsAmbientNotWake() async {
        let c = make(); await c.apply(mode: .alwaysOn)
        XCTAssertEqual(log, ["wake-", "amb+"])
    }

    func test_wakeWord_runsWakeNotAmbient() async {
        let c = make(); await c.apply(mode: .wakeWord)
        XCTAssertEqual(log, ["amb-", "wake+"])
    }

    func test_off_stopsBoth() async {
        let c = make(); await c.apply(mode: .off)
        XCTAssertEqual(log, ["wake-", "amb-"])
    }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift test --filter ListeningControllerTests`
Expected: compile error.

- [x] **Step 3: Write the controller**

`Sources/Grux/Decisions/ListeningController.swift`:

```swift
import Foundation

/// The only thing that starts or stops the two listeners. Every other path
/// (Settings, the CLI triggers, launch) sets `config.listeningMode` and calls
/// `apply`, so the mode and what is actually running cannot drift apart.
@MainActor
final class ListeningController {
    static let shared = ListeningController(
        startWake: { await WakeWordListener.shared.start() },
        stopWake: { WakeWordListener.shared.stop() },
        startAmbient: { await AmbientListener.shared.start() },
        stopAmbient: { AmbientListener.shared.stop() })

    private(set) var current: ListeningMode?
    private let startWake: () async -> Void
    private let stopWake: () -> Void
    private let startAmbient: () async -> Void
    private let stopAmbient: () -> Void

    init(startWake: @escaping () async -> Void, stopWake: @escaping () -> Void,
         startAmbient: @escaping () async -> Void, stopAmbient: @escaping () -> Void) {
        self.startWake = startWake; self.stopWake = stopWake
        self.startAmbient = startAmbient; self.stopAmbient = stopAmbient
    }

    func apply(mode: ListeningMode) async {
        current = mode
        switch mode {
        case .alwaysOn:
            stopWake(); await startAmbient()
        case .wakeWord:
            stopAmbient(); await startWake()
        case .off:
            stopWake(); stopAmbient()
        }
    }

    /// Reads the saved mode and applies it. Called at launch and after any
    /// change to `config.listeningMode`.
    func apply() async {
        await apply(mode: AppState.shared.config.listeningMode)
    }
}
```

- [x] **Step 4: Route ambient chunks**

In `AmbientState.appendChunk(_:)`, after `Persistence.save(recentChunks, to: Persistence.ambientTranscriptURL)`:

```swift
        if AppState.shared.config.listeningMode == .alwaysOn, !AppState.shared.micMuted {
            Task { await VoiceCommandRouter.shared.consider(chunk: clean) }
        }
```

In `MicController.writeMicStatus(dir:)`, add to the dictionary: `"listeningMode": s.config.listeningMode.rawValue`.

In `GruxApp.swift` at the launch point where `AmbientListener` or `WakeWordListener` is first started (find it with `grep -n "WakeWordListener.shared.start\|AmbientListener.shared.start" Sources/Grux/GruxApp.swift`), replace those direct starts with `Task { await ListeningController.shared.apply() }`. In the `fire-wake-enable` handler set `state.config.listeningMode = .wakeWord`, in `fire-ambient-enable` set `.alwaysOn`, then `await ListeningController.shared.apply()` before the existing `writeMicStatus` call. Keep the consent dialogs exactly where they are; they gate the first capture, not the mode.

- [x] **Step 5: Run the tests, then prove the flip on the running app**

Run: `swift test --filter "ListeningControllerTests|MicController"`
Expected: PASS.

Then build and install (`./build.sh`), run the operator's display keeper if configured, and:

```bash
touch ~/.grux/fire-wake-enable; sleep 2; python3 -c "import json;d=json.load(open('$HOME/.grux/mic-status.json'));print(d['listeningMode'], d.get('ambientListening'), d.get('wakeListening'))"
touch ~/.grux/fire-ambient-enable; sleep 2; python3 -c "import json;d=json.load(open('$HOME/.grux/mic-status.json'));print(d['listeningMode'], d.get('ambientListening'), d.get('wakeListening'))"
```

Expected: `wakeWord True/False` pattern flips to `alwaysOn` with ambient on and wake off. Record both lines in the evidence file (DoD item 5).

- [x] **Step 6: Commit**

```bash
git add Sources/Grux/Decisions/ListeningController.swift Sources/Grux/Ambient/AmbientState.swift Sources/Grux/MicController.swift Sources/Grux/GruxApp.swift Tests/GruxTests/ListeningControllerTests.swift
git commit -F - <<'EOF'
One controller owns the listeners, and always on routes every chunk to the router

Settings, the CLI triggers and launch all set the mode and call apply, so what
is saved and what is running cannot drift. mic-status.json now reports the
mode, which is how the wake-word downgrade is proven from the terminal.
EOF
git push
```

---

### Task A7: The Listening control in Settings and the key field in Integrations

**Files:**
- Modify: `Sources/Grux/SettingsView.swift` (the "Passive listening" section at line ~75 and the "Wake word" section at line ~236 become one `ListeningSection`)
- Modify: `Sources/Grux/Integrations/` (add a "Decisions" card with the TypeSafe key field; read the existing Slack card in `IntegrationsView.swift` for the field and Save pattern and copy it exactly)
- Test: `Tests/GruxTests/ListeningSectionCopyTests.swift`

**Interfaces:**
- Consumes: `ListeningMode`, `ListeningController.shared.apply()`, `KeychainStore.set(.typesafeApiKey, _:)`.
- Produces: `struct ListeningSection: View`.

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class ListeningSectionCopyTests: XCTestCase {
    func test_sectionCopy_isPlainLanguage() {
        let copy = ListeningSection.copy
        XCTAssertEqual(copy.title, "Listening")
        for banned in ["Whisper", "ambient", "VP", "AEC", "wake word listener"] {
            XCTAssertFalse(copy.body.contains(banned), "jargon in Listening copy: \(banned)")
        }
    }
}
```

- [x] **Step 2: Run to verify it fails**

Run: `swift test --filter ListeningSectionCopyTests`
Expected: compile error.

- [x] **Step 3: Write the section and replace the two old sections**

Add to `SettingsView.swift` (or a new `Sources/Grux/Settings/ListeningSection.swift` if `SettingsView.swift` has a sibling folder by then):

```swift
import SwiftUI

struct ListeningSection: View {
    struct Copy { let title: String; let body: String }
    static let copy = Copy(
        title: "Listening",
        body: "Closing windows and opening tabs happen on the spot. Sending, deleting and spending always stop in Approvals first. Shell commands never run by voice.")

    @ObservedObject private var state = AppState.shared

    var body: some View {
        Section(Self.copy.title) {
            Picker("", selection: Binding(
                get: { state.config.listeningMode },
                set: { mode in
                    state.config.listeningMode = mode
                    state.saveConfig()
                    Task { await ListeningController.shared.apply() }
                })) {
                ForEach(ListeningMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(state.config.listeningMode.explanation)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
            Text(Self.copy.body)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
            Toggle("Show what it heard", isOn: Binding(
                get: { state.config.showLastDecision },
                set: { state.config.showLastDecision = $0; state.saveConfig() }))
        }
    }
}
```

`state.saveConfig()` is whatever `SettingsView` already calls after a toggle; read the existing `.onChange(of: wakeWord)` handler at `SettingsView.swift:238` and use the same persistence call. Remove the "Passive listening" section (lines ~75-110) and the "Wake word" section (lines ~236-250) and place `ListeningSection()` where "Passive listening" was. Keep every OTHER control in those sections (coach, hourly summaries, microphone picker) by moving them under a "Voice" section directly below.

In Integrations, add a card titled "Decisions" whose body reads: "Jev by TypeSafe makes Grux's small decisions in about half a second with a confidence attached. Optional. Without it Grux decides on device." with one secure field labelled "TypeSafe API key" that writes `KeychainStore.set(.typesafeApiKey, trimmed)` on Save and shows "Connected" when `KeychainStore.get(.typesafeApiKey)` is non-empty. Copy the Slack card's field, Show and Save layout exactly.

- [x] **Step 4: Run the tests, build, sweep**

Run: `swift test --filter ListeningSectionCopyTests` (PASS), `./build.sh`, keeper, then `GRUX_SWEEP_OUT=/tmp/shots tools/grux-sweep.sh floor settings integrations` and read both captures: the segmented control is visible with three labels; the Decisions card is visible.

- [x] **Step 5: Commit**

```bash
git add Sources/Grux/SettingsView.swift Sources/Grux/Integrations Tests/GruxTests/ListeningSectionCopyTests.swift
git commit -F - <<'EOF'
Settings has one Listening control, and Integrations has the optional key

Always on, After Hey Grux, Off, in one segmented control with two plain
lines under it. The four old switches and their paragraph are gone from the
face; the listeners still honour them underneath.
EOF
git push
```

---

### Task A8: The tells: orb ARMED, menu bar line, HUD chips, banner, Chat live rail

**Files:**
- Modify: `Sources/Grux/LaunchRootView.swift:35-42` (`orbState`: `.armed` when listening always on and capturing) and `Sources/Grux/MenuBarView.swift:23-31` (same)
- Modify: `Sources/GruxShellCore/OrbKit/OrbPalette.swift` (add `case armed` with label "armed"; read the file to place its colour beside `listening`)
- Modify: `Sources/Grux/MenuBarView.swift` (one line under the pill: `DecisionLedger.shared.last?.summary` with latency, shown when `config.showLastDecision`)
- Modify: `Sources/Grux/Ambient/AmbientHUD.swift` (the transcript ticker renders a green chip for a chunk whose `VoiceCommandRouter.shared.events` entry has `outcome == .executed`, gray text otherwise)
- Create: `Sources/Grux/Decisions/DecisionBanner.swift` (posts a local notification per executed event through `NotificationManager.shared.sendInfo(title:body:)`; the first time on a device posts the explainer first and sets `config.listeningBannerExplained`)
- Modify: `Sources/Grux/ChatView.swift` (a right rail `VoiceLiveRail` listing `VoiceCommandRouter.shared.events`, newest at the bottom, decisions as green chips with latency, chatter gray; toggled by `config.showLastDecision`)
- Test: `Tests/GruxTests/DecisionBannerTests.swift`

**Interfaces:**
- Consumes: `VoiceCommandRouter.shared.events`, `DecisionLedger.shared.last`, `config.showLastDecision`, `config.listeningBannerExplained`.
- Produces: `struct VoiceLiveRail: View`, `final class DecisionBanner { init(post:); func handle(_ event: VoiceDecisionEvent, config: inout GruxConfig) }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class DecisionBannerTests: XCTestCase {
    func test_firstBannerOnDevice_isPrecededByTheExplainer() {
        var posted: [String] = []
        let b = DecisionBanner(post: { title, _ in posted.append(title) })
        var config = GruxConfig.default
        let e = VoiceDecisionEvent(heard: "close everything", commandId: "macro:close_all", confidence: 0.98,
                                   latencyMs: 465, provider: .local, outcome: .executed)
        b.handle(e, config: &config)
        XCTAssertEqual(posted.count, 2)
        XCTAssertTrue(posted[0].contains("listening"), posted[0])
        XCTAssertTrue(config.listeningBannerExplained)
        b.handle(e, config: &config)
        XCTAssertEqual(posted.count, 3)
    }

    func test_ignoredAndRefused_postNothing() {
        var posted: [String] = []
        let b = DecisionBanner(post: { title, _ in posted.append(title) })
        var config = GruxConfig.default
        for outcome in [VoiceDecisionEvent.Outcome.ignored, .refused] {
            b.handle(VoiceDecisionEvent(heard: "x", commandId: "y", confidence: 0.9, latencyMs: 1, provider: .local, outcome: outcome), config: &config)
        }
        XCTAssertTrue(posted.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DecisionBannerTests`
Expected: compile error.

- [ ] **Step 3: Write the banner**

`Sources/Grux/Decisions/DecisionBanner.swift`:

```swift
import Foundation

/// One macOS banner per executed spoken command, and one explainer before the
/// very first so nobody wonders what the banners are.
final class DecisionBanner {
    static let shared = DecisionBanner(post: { title, body in
        // sendInfo batches through the triage matrix; a spoken command wants
        // the banner now. Use the interrupting Commands category. Read the
        // exact case name in Notifications/TriageClassifier.swift before
        // compiling; it is the row labelled Commands in Settings.
        NotificationManager.shared.sendCategorized(.commands, title: title, body: body)
    })

    private let post: (String, String) -> Void

    init(post: @escaping (String, String) -> Void) { self.post = post }

    func handle(_ event: VoiceDecisionEvent, config: inout GruxConfig) {
        guard event.outcome == .executed else { return }
        if !config.listeningBannerExplained {
            post("Grux is listening",
                 "When you ask it to do something, a banner like the next one says what it did. Turn these off in Settings, Listening.")
            config.listeningBannerExplained = true
        }
        post("Grux", "\(Self.plain(event.commandId)) in \(event.latencyMs) ms")
    }

    static func plain(_ commandId: String) -> String {
        if commandId.hasPrefix("tab:") { return "Opened \(commandId.dropFirst(4))" }
        if commandId.hasPrefix("macro:") { return "Ran \(commandId.dropFirst(6).replacingOccurrences(of: "_", with: " "))" }
        return commandId.capitalized
    }
}
```

Wire it: in `VoiceCommandRouter.consider(chunk:)`, after appending the event, `DecisionBanner.shared.handle(event, config: &AppState.shared.config)` followed by the same persistence call Settings uses. Keep it behind `if self === VoiceCommandRouter.shared` so tests with private routers post nothing.

- [ ] **Step 4: The rail, the HUD chips, the menu bar line, the orb**

`VoiceLiveRail` in `ChatView.swift` (or `Chat/VoiceLiveRail.swift`):

```swift
struct VoiceLiveRail: View {
    @ObservedObject private var router = VoiceCommandRouter.shared
    @ObservedObject private var ledger = DecisionLedger.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(GruxTheme.successMint).frame(width: 7, height: 7)
                Text("LIVE").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.textSecondary)
                Spacer()
                let t = ledger.today()
                Text(String(format: "$%.2f, %d ms avg", t.costUSD, t.avgLatencyMs))
                    .font(GruxTheme.Font.mono).foregroundStyle(GruxTheme.textTertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(router.events.suffix(40)) { e in
                        if e.outcome == .executed {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.heard).font(GruxTheme.Font.body)
                                Text("\(DecisionBanner.plain(e.commandId).uppercased()) \u{00B7} \(e.latencyMs) MS")
                                    .font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.successMint)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(GruxTheme.successMint.opacity(0.10), in: RoundedRectangle(cornerRadius: GruxTheme.Radius.chip))
                            .overlay(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip).stroke(GruxTheme.successMint.opacity(0.35)))
                        } else {
                            Text(e.heard).font(GruxTheme.Font.caption).foregroundStyle(GruxTheme.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}
```

Read `GruxTheme.Radius` and `GruxTheme.Font` names in `DesignSystem/GruxTheme.swift:99-123` before compiling; the names above are the ones present on 2026-09-20 (`card`, `hud`, `chip`, `pill`; `display`, `title`, `body`, `caption`, `mono`, `microCaps`).

Place `VoiceLiveRail()` as the trailing column of Chat's `HStack` when `state.config.showLastDecision && state.config.listeningMode == .alwaysOn`. In `AmbientHUD.swift`, where the transcript ticker renders each chunk, look up `VoiceCommandRouter.shared.events.last(where: { $0.heard == chunk.text })` and render the same green chip when `outcome == .executed`. In `MenuBarView.swift`, under `OrbStatusPill`, add `if state.config.showLastDecision, let last = DecisionLedger.shared.last { Text("\(last.summary) \u{00B7} \(last.latencyMs) ms").font(GruxTheme.Font.mono).lineLimit(1) }`. In both `orbState` computations, before `if wake.isListening { return .listening }`, add `if state.config.listeningMode == .alwaysOn && AmbientState.shared.isCapturing { return .armed }`, and add `case armed` to `GruxOrbState` in `OrbPalette.swift` with the label `"armed"` and the same colour as `listening`.

- [ ] **Step 5: Run the tests, build, sweep Chat**

Run: `swift test --filter "DecisionBannerTests|OrbPalette"` (PASS), `./build.sh`, keeper, `tools/grux-sweep.sh floor chat`. Read the capture: the rail is on the right, the pill reads ARMED. Speak "open my calendar" near the Mac and confirm: Calendar tab opens, a banner appears, the rail shows a green chip with a latency. Record the capture path and the ledger line in the evidence file.

- [ ] **Step 6: Commit**

```bash
git add Sources/Grux/Decisions/DecisionBanner.swift Sources/Grux/ChatView.swift Sources/Grux/Ambient/AmbientHUD.swift Sources/Grux/MenuBarView.swift Sources/Grux/LaunchRootView.swift Sources/GruxShellCore/OrbKit/OrbPalette.swift Tests/GruxTests/DecisionBannerTests.swift
git commit -F - <<'EOF'
Every spoken decision shows where it was asked for: rail, HUD, menu bar, banner, orb

The orb reads ARMED while always on is capturing. Executed commands render as
a green chip with their latency in the Chat rail and the HUD, one line in the
menu bar, and one macOS banner, with a single explainer the first time.
EOF
git push
```

---

### Task A9: The existing judgment points route through the engine, measured

**Files:**
- Modify: `Sources/Grux/Chat/IntentClassifier.swift` (a `classifyAsync(utterance:)` that asks the engine one Choice per section and falls back to the keyword result; `classify` stays as the local path)
- Modify: `Sources/GruxShellCore/ShellSafety.swift` (add `public static var secondOpinion: ((String) async -> Double?)?` and, in `evaluate`, treat the command as destructive when the heuristics say so OR the opinion is above 0.5; the opinion can only tighten)
- Modify: `Sources/Grux/EmailTriage/EmailTriageEngine.swift` (the four-way classify step asks the engine first; the local model path stays as the fallback)
- Modify: `Sources/Grux/Jax/DecisionGate.swift` (before returning `.proceed` for a non-spend, non-comms action, ask a Noul "does this action reach outside this Mac or cost money"; above 0.5 becomes `.queueForApproval`; never turns a queue into a proceed)
- Modify: `Sources/Grux/Notifications/TriageClassifier.swift` (ask the engine a Choice over the triage categories before the language-model path)
- Modify: `Sources/Grux/Ambient/AmbientCoach.swift` (the drift judgment is a Noul; the nudge text stays on the language model)
- Modify: `Sources/Grux/Jax/ApprovalQueue.swift` (a `riskScore` per item from a Score with levels harmless, reversible, irreversible; the tray orders by it)
- Modify: `Sources/Grux/Email/` (a `needsYou` Score per message, levels: no action, reply when convenient, needs you today; stored on the message model the inbox reads; surface `mail.needsYou`)
- Modify: the Task Stack model (a `priorityScore` from a Score with levels later, this week, today, now; surface `tasks.priority`; the stack sorts by it when the person has not dragged)
- Modify: `Sources/Grux/Meeting/` (per transcript chunk a Noul each for decision, commitment and question; chunks above 0.6 are marked as moments the meeting note lists first; surface `meeting.moments`)
- Test: `Tests/GruxTests/ShellSafetySecondOpinionTests.swift`, `Tests/GruxTests/DecisionGateTightensOnlyTests.swift`

**Interfaces:**
- Consumes: `DecisionEngine.shared.decide(surface:state:questions:)`.
- Produces: per-surface ledger entries with `surface` in `["chat.intent", "shell.safety", "mail.triage", "gate", "notifications", "focus.drift", "approvals.risk", "mail.needsYou", "tasks.priority", "meeting.moments", "voice"]`, which the release notes table reads.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import GruxShellCore

final class ShellSafetySecondOpinionTests: XCTestCase {
    override func tearDown() { ShellSafety.secondOpinion = nil }

    func test_opinionCanOnlyTighten() async {
        ShellSafety.secondOpinion = { _ in 0.0 }
        let v = ShellSafety.evaluate(command: "rm -rf /", rootDir: "/tmp", currentCwd: "/tmp", mode: .strict)
        XCTAssertNotEqual(v.decision, .allow, "heuristics still block even when the opinion says harmless")
    }

    func test_highOpinion_blocksACommandTheHeuristicsMissed() async {
        ShellSafety.secondOpinion = { _ in 0.9 }
        let v = ShellSafety.evaluate(command: "python3 cleanup.py --all", rootDir: "/tmp", currentCwd: "/tmp", mode: .strict)
        XCTAssertNotEqual(v.decision, .allow)
    }
}
```

```swift
import XCTest
@testable import Grux

@MainActor
final class DecisionGateTightensOnlyTests: XCTestCase {
    func test_spendNeverBecomesProceed() async {
        let action = ProposedAction(kind: .spend, summary: "pay invoice", target: "stripe", isSpend: true)
        let verdict = await DecisionGate.evaluateAsync(action, opinion: { _ in 0.0 })
        if case .proceed = verdict { XCTFail("spend must not proceed on an opinion") }
    }
}
```

Read `ShellGateDecision` cases (`ShellSafety.swift:23`) and `DecisionGate`'s current evaluate signature before writing `evaluateAsync`; the test names the shape, the implementation matches the existing verdict flow.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "ShellSafetySecondOpinionTests|DecisionGateTightensOnlyTests"`
Expected: compile errors.

- [ ] **Step 3: Implement each hook, one commit per surface**

For each surface the pattern is identical:

```swift
// before: let sections = ChatIntentClassifier.classify(utterance: text)
// after:
let sections = await ChatIntentClassifier.classifyAsync(utterance: text)
```

with

```swift
    static func classifyAsync(utterance: String, hasImage: Bool = false) async -> VolatileSections {
        let local = classify(utterance: utterance, hasImage: hasImage)
        let r = await DecisionEngine.shared.decide(
            surface: "chat.intent", state: utterance,
            questions: [
                "tasks": .noul(instructions: "Is the person managing tasks or to-dos?"),
                "focus": .noul(instructions: "Is the person asking about what they were doing or their focus?"),
                "macro": .noul(instructions: "Is this a short command to run something?"),
            ])
        guard r.provider == .jev else { return local }
        var s = local
        if case .noul(let p)? = r.answers["tasks"] { s.taskStack = p >= 0.5 || local.taskStack }
        if case .noul(let p)? = r.answers["focus"] { s.recentFocus = p >= 0.5 || local.recentFocus }
        if case .noul(let p)? = r.answers["macro"] { s.availableMacros = p >= 0.5 || local.availableMacros }
        return s
    }
```

The rule everywhere: the local answer is computed first and the engine may only ADD context, tighten a verdict, or pick among categories. It never removes a safeguard. In `ShellSafety.evaluate`, because it is synchronous inside `GruxShellCore`, the opinion is fetched by the caller (`ShellSession.swift:198` and `:271`) before `evaluate` and passed through a new `opinion: Double?` parameter with a default of `nil`; `ShellSafety.secondOpinion` is the static seam the app sets at launch to `{ cmd in
    let r = await DecisionEngine.shared.decide(surface: "shell.safety", state: cmd, questions: ["destructive": .noul(instructions: "Would running this shell command delete or irreversibly modify user data?")])
    if case .noul(let p)? = r.answers["destructive"] { return p }; return nil }`.

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed N tests, with M skipped and 0 failures`, N at or above 2502 plus the tests this phase added.

- [ ] **Step 5: Measure before and after per surface**

With the app built and the key present, exercise each surface once (a chat turn, a shell command in Commands, one triage run, one notification, one drift check) and read the ledger:

```bash
python3 - <<'EOF'
import json,collections,os
rows=[json.loads(l) for l in open(os.path.expanduser('~/Library/Application Support/Grux/decisions.jsonl'))]
by=collections.defaultdict(list)
for r in rows: by[(r['surface'],r['provider'])].append(r['latencyMs'])
for k,v in sorted(by.items()): print(k, len(v), 'avg', sum(v)//len(v), 'ms')
EOF
```

Paste the table into the evidence file; it becomes the release-notes table (DoD item 9). The "before" column for each surface is the local provider's latency on the same surface, measured by temporarily removing the key from the Keychain for one run.

- [ ] **Step 6: Commit (one per surface, same shape)**

```bash
git add <the surface's files and test>
git commit -F - <<'EOF'
<Surface> asks the engine first and keeps its own answer as the floor

The engine may add context, tighten a verdict or pick a category. It never
removes a safeguard, and a test plants the case where it tries.
EOF
git push
```

---

### Task A10: Cost on orb hover and the Settings Usage card

**Files:**
- Modify: `Sources/Grux/LaunchRootView.swift` (the sidebar orb gains a `.help` tooltip and a hover popover fed by `DecisionLedger.shared.today()`)
- Modify: `Sources/Grux/Usage/UsageView.swift` (a "Voice decisions, this month" card: count, average latency, spend against the credit, plus the existing chat line)
- Create: `Sources/Grux/Decisions/DecisionUsageSummary.swift`
- Test: `Tests/GruxTests/DecisionUsageSummaryTests.swift`

**Interfaces:**
- Consumes: `DecisionLedger.shared.recent`.
- Produces: `enum DecisionUsageSummary { static func month(from:now:) -> (count: Int, avgLatencyMs: Int, costUSD: Double); static func hoverLine(today:) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class DecisionUsageSummaryTests: XCTestCase {
    func test_monthTotals_countOnlyThisMonth() {
        let now = Date()
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: now)!
        let rows = [
            DecisionLedgerEntry(surface: "voice", provider: .jev, latencyMs: 400, inputTokens: 1000, outputTokens: 1, at: now, summary: "a"),
            DecisionLedgerEntry(surface: "voice", provider: .jev, latencyMs: 600, inputTokens: 1000, outputTokens: 1, at: now, summary: "b"),
            DecisionLedgerEntry(surface: "voice", provider: .jev, latencyMs: 9000, inputTokens: 1000, outputTokens: 1, at: lastMonth, summary: "c"),
        ]
        let m = DecisionUsageSummary.month(from: rows, now: now)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.avgLatencyMs, 500)
        XCTAssertEqual(m.costUSD, 2 * 0.042 / 1000, accuracy: 1e-12)
    }

    func test_hoverLine_readsPlainly() {
        let line = DecisionUsageSummary.hoverLine(today: (count: 214, avgLatencyMs: 380, costUSD: 0.03))
        XCTAssertEqual(line, "214 decisions today, 380 ms average, $0.03")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DecisionUsageSummaryTests`
Expected: compile error.

- [ ] **Step 3: Write the summary**

```swift
import Foundation

enum DecisionUsageSummary {
    static func month(from rows: [DecisionLedgerEntry], now: Date = Date()) -> (count: Int, avgLatencyMs: Int, costUSD: Double) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let inMonth = rows.filter { $0.at >= start }
        guard !inMonth.isEmpty else { return (0, 0, 0) }
        return (inMonth.count,
                inMonth.map(\.latencyMs).reduce(0, +) / inMonth.count,
                inMonth.map(\.costUSD).reduce(0, +))
    }

    static func hoverLine(today: (count: Int, avgLatencyMs: Int, costUSD: Double)) -> String {
        String(format: "%d decisions today, %d ms average, $%.2f", today.count, today.avgLatencyMs, today.costUSD)
    }
}
```

Wire the orb: `.help(DecisionUsageSummary.hoverLine(today: DecisionLedger.shared.today()))` on the sidebar orb in `LaunchRootView.swift`, and a `.popover` on hover with the same three numbers. In `UsageView.swift`, add the card using the existing card style in that file with `month(from: DecisionLedger.shared.recent)`.

- [ ] **Step 4: Run tests, build, sweep Settings**

Run: `swift test --filter DecisionUsageSummaryTests` (PASS), `./build.sh`, keeper, `tools/grux-sweep.sh floor settings` and read the capture for the card.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/Decisions/DecisionUsageSummary.swift Sources/Grux/LaunchRootView.swift Sources/Grux/Usage/UsageView.swift Tests/GruxTests/DecisionUsageSummaryTests.swift
git commit -F - <<'EOF'
The cost of listening is one hover away and one card in Settings, and nowhere else

Decisions today, average latency and spend on the orb; the month on the
Usage card. Nothing permanent in the face.
EOF
git push
```

---

### Task A11: Apps and windows as spoken targets

**Files:**
- Create: `Sources/Grux/Decisions/WindowTargets.swift`
- Modify: `Sources/Grux/Decisions/VoiceCommandRouter.swift` (vocabulary gains open, focus, hide and close-all commands over the running apps)
- Test: `Tests/GruxTests/WindowTargetsTests.swift`

**Interfaces:**
- Consumes: `NSWorkspace.shared.runningApplications`, `NSRunningApplication.activate`, `.hide`.
- Produces: `enum WindowTargets { static func runningAppNames() -> [String]; static func phrases(forApp:) -> [String]; static func focus(appNamed:) -> Bool; static func hide(appNamed:) -> Bool; static func hideAllExceptGrux() -> Int; static let closeEverythingVerb }`. "Close everything" hides every other app; it never quits and never discards unsaved work. Quit is absent from the vocabulary by construction.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Grux

final class WindowTargetsTests: XCTestCase {
    func test_vocabularyPhrases_forAnApp() {
        let phrases = WindowTargets.phrases(forApp: "Safari")
        XCTAssertTrue(phrases.contains("open safari"))
        XCTAssertTrue(phrases.contains("switch to safari"))
        XCTAssertTrue(phrases.contains("hide safari"))
    }

    func test_closeEverything_isHideNotQuit() {
        XCTAssertEqual(WindowTargets.closeEverythingVerb, "hide")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter WindowTargetsTests`
Expected: compile error.

- [ ] **Step 3: Write it**

```swift
import AppKit

/// Apps and windows as things you can say. Reversible only: focus and hide.
/// Quit is deliberately absent, so "close everything" can never lose work.
enum WindowTargets {
    static let closeEverythingVerb = "hide"

    static func runningAppNames() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter { $0 != "Grux" }
    }

    static func phrases(forApp name: String) -> [String] {
        let n = name.lowercased()
        return ["open \(n)", "switch to \(n)", "focus \(n)", "bring up \(n)", "hide \(n)", "minimise \(n)", "minimize \(n)"]
    }

    @discardableResult
    static func focus(appNamed name: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            return NSWorkspace.shared.launchApplication(name)
        }
        return app.activate(options: [.activateIgnoringOtherApps])
    }

    @discardableResult
    static func hide(appNamed name: String) -> Bool {
        NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.hide() ?? false
    }

    @discardableResult
    static func hideAllExceptGrux() -> Int {
        var n = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.localizedName != "Grux" {
            if app.hide() { n += 1 }
        }
        return n
    }
}
```

In `VoiceCommandRouter.vocabulary()`, add for each `WindowTargets.runningAppNames()` two commands: `app.focus:<name>` (phrases open, switch to, focus, bring up) and `app.hide:<name>` (hide, minimise, minimize), both `.onTheSpot`; and one `close_all` with phrases "close everything", "hide everything", "clear my screen" that calls `hideAllExceptGrux()`. The `not_a_command` option stays last.

- [ ] **Step 4: Run tests, build, say it**

Run: `swift test --filter "WindowTargetsTests|VoiceCommandRouterTests"` (PASS), `./build.sh`, keeper. Say "close everything" and confirm every other app hides and Grux stays; say "open safari" and confirm Safari comes forward. Record the two ledger lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/Grux/Decisions/WindowTargets.swift Sources/Grux/Decisions/VoiceCommandRouter.swift Tests/GruxTests/WindowTargetsTests.swift
git commit -F - <<'EOF'
Running apps are spoken targets, and close everything hides rather than quits

Open, switch to, focus, hide, and one close-everything that leaves Grux up.
Quit is not in the vocabulary, so nothing said out loud can lose unsaved work.
EOF
git push
```

---

### Phase A close

- [ ] `swift build` exit 0; `swift test` exit 0 with the count printed (at or above 2502 plus this phase's additions).
- [ ] `DestructiveNeverTests`, `ShellSafetySecondOpinionTests` and `DecisionGateTightensOnlyTests` each red-proven once by planting the failure they guard, then restored, `git diff --stat` clean.
- [ ] `mic-status.json` flip lines recorded (DoD 5).
- [ ] Chat sweep capture with ARMED pill and the live rail (DoD 8 partial, finished in Phase B).
- [ ] Per-surface latency table recorded (DoD 9).
- [ ] `scripts/oss-guarantee.sh` PASS: the tree carries no key (DoD 6).
- [ ] Evidence lines written to `docs/superpowers/plans/2026-09-20-grux-3-0-evidence.md`.
