import Foundation

// Jax's approval queue. The one place where a thing Jax wants to do, but is not
// allowed to do autonomously, waits for the user's one-tap yes/no. The DecisionGate
// decides WHAT lands here (see DecisionGate.swift); this file owns the queue
// itself, its persistence, and the menubar ping on an urgent enqueue.
//
// House style mirrors the rest of Grux:
//   * @MainActor final class : ObservableObject with a static let shared
//   * Codable persistence through JSONEncoder/Decoder to ~/.grux/jax/ (same
//     ~/.grux posture InboxStore uses for its mirror file)
//   * lenient init(from:) on the persisted types so an older approvals.json with
//     missing keys still decodes cleanly and never strands the queue
//   * zero em/en dashes, dollars as $N
//
// SAFETY: nothing in here ever executes a ProposedAction. Approving an item only
// marks it approved and hands the ProposedAction back to the caller, which is the
// only code allowed to actually perform the (now human-sanctioned) work. Jax
// never moves money, never sends a document, never posts publicly: those stay
// refused at the gate, and even a queued spend is "queue for one-tap approval",
// never "spend on approval inside this class".
//
// Shared-type note: the persona token (GatePersona) and ProposedAction live in
// DecisionGate.swift; the empire-vs-personal disclosure helper (CommsPersona)
// lives in CommsPersona.swift. This file references both and redefines neither.

// MARK: - PendingApproval

// One item awaiting the user's tap. Wraps the full ProposedAction so approving it can
// hand the exact same payload back to the caller, plus the queue metadata
// (created stamp, urgency, resolved comms persona, and the lifecycle state).
struct PendingApproval: Codable, Identifiable, Equatable {
    enum State: String, Codable, Equatable {
        case pending, approved, skipped
    }

    let id: UUID
    var action: ProposedAction
    var createdAt: Date
    // Urgent items ping the menubar on enqueue (notify now); non-urgent ones just
    // wait quietly in the queue for the next time the user looks.
    var urgent: Bool
    // The face this would go out as IF it is an outbound comm. .none otherwise.
    var persona: GatePersona
    // Why the gate routed this to approval instead of proceeding. Shown on the
    // card so the user reads the reason before tapping.
    var reason: String
    var state: State
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        action: ProposedAction,
        createdAt: Date = Date(),
        urgent: Bool = false,
        persona: GatePersona = .none,
        reason: String = "",
        state: State = .pending,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.action = action
        self.createdAt = createdAt
        self.urgent = urgent
        self.persona = persona
        self.reason = reason
        self.state = state
        self.resolvedAt = resolvedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, action, createdAt, urgent, persona, reason, state, resolvedAt
    }

    // Lenient decode: an older approvals.json missing any newer key still loads
    // (defaults rather than a thrown error that would wipe the whole queue at
    // launch). action is the one genuinely required field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        action = try c.decode(ProposedAction.self, forKey: .action)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        urgent = (try? c.decode(Bool.self, forKey: .urgent)) ?? false
        persona = (try? c.decode(GatePersona.self, forKey: .persona)) ?? .none
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        state = (try? c.decode(State.self, forKey: .state)) ?? .pending
        resolvedAt = try? c.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    // Convenience passthroughs the queue + any UI use without reaching into
    // action every time.
    var amountCents: Int? { action.amountCents }
    var brand: String? { action.brand }
    var summary: String { action.summary }
}

// MARK: - ApprovalQueue

@MainActor
final class ApprovalQueue: ObservableObject {
    static let shared = ApprovalQueue()

    // Full history, newest last. The UI filters to .pending for the inbox and can
    // show resolved items in an activity log if it wants.
    @Published private(set) var items: [PendingApproval] = []

    private let storeURL: URL
    private var loaded = false

    // ~/.grux/jax/approvals.json , matching the global-instructions storage hint
    // and the InboxStore ~/.grux mirror posture.
    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dir = home
                .appendingPathComponent(".grux", isDirectory: true)
                .appendingPathComponent("jax", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("approvals.json")
        }
        load()
    }

    // MARK: Derived views

    var pending: [PendingApproval] { items.filter { $0.state == .pending } }
    var pendingCount: Int { pending.count }
    var hasUrgentPending: Bool { pending.contains { $0.urgent } }

    // MARK: Load / save

    func load() {
        guard !loaded else { return }
        loaded = true
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: storeURL),
           let arr = try? dec.decode([PendingApproval].self, from: data) {
            items = arr
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        Persistence.write(data, to: storeURL)
    }

    // MARK: Mutations

    // Put an item on the queue. On an urgent enqueue, ping the menubar right now
    // via the existing notification path so the user sees it; non-urgent items simply
    // wait. Returns the stored PendingApproval (with its assigned id).
    @discardableResult
    func enqueue(
        _ action: ProposedAction,
        urgent: Bool = false,
        persona: GatePersona = .none,
        reason: String = ""
    ) -> PendingApproval {
        let item = PendingApproval(
            action: action,
            urgent: urgent,
            persona: persona,
            reason: reason
        )
        items.append(item)
        save()
        if urgent { notifyUrgent(item) }
        return item
    }

    // Convenience: enqueue straight from a GateVerdict.queueForApproval payload
    // the gate already populated. Keeps callers from re-deriving urgency/persona.
    @discardableResult
    func enqueue(_ prepared: PendingApproval) -> PendingApproval {
        items.append(prepared)
        save()
        if prepared.urgent { notifyUrgent(prepared) }
        return prepared
    }

    // The user tapped yes. Marks the item approved and hands the ProposedAction back
    // so the CALLER can perform the (now sanctioned) work. This class never
    // executes the action itself.
    @discardableResult
    func approve(_ id: UUID) -> ProposedAction? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        guard items[idx].state == .pending else { return nil }
        items[idx].state = .approved
        items[idx].resolvedAt = Date()
        save()
        return items[idx].action
    }

    // The user tapped yes AND we actually perform the sanctioned work. This closes the
    // one-tap loop: it marks the item approved, then re-dispatches the original
    // tool call through the universal choke point (ChatService.dispatchTool) using
    // a one-shot bypass token armed only for this exact item, so the gate lets that
    // single replay through and runs it. The token is disarmed the instant the
    // dispatch returns. If the item carries no replay coordinates (e.g. a spend
    // with no executor yet) the approval is recorded and nothing is performed: the
    // safe direction. Returns a human-readable result of the execution.
    // Serializes approved replays. The one-shot bypass token (JaxToolGate.arm)
    // is a single shared value, so two overlapping approveAndExecute calls could
    // cross-arm and run the wrong queued tool. Approvals are user taps (rare and
    // serial in practice); this guard makes that guarantee explicit so only one
    // armed window can ever exist at a time.
    private var executing = false

    @discardableResult
    func approveAndExecute(_ id: UUID) async -> String {
        guard !executing else { return "busy: another approval is executing, give it a second" }
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return "error: approval not found" }
        guard items[idx].state == .pending else { return "error: already resolved" }
        executing = true
        defer { executing = false }

        items[idx].state = .approved
        items[idx].resolvedAt = Date()
        save()

        let action = items[idx].action
        guard let tool = action.detail["__replay_tool"] else {
            return "approved: recorded. Nothing executable was attached, so nothing was performed."
        }
        var input = action.detail["__replay_input"].flatMap(Self.decodeInput) ?? [:]
        input["__approved_id"] = id.uuidString

        JaxToolGate.arm(id)
        let result = await ChatService.dispatchTool(name: tool, input: input)
        JaxToolGate.disarm()

        // Do not leave a FAILED execution showing as a green "Approved". If the
        // tool reported an error or refusal, return the item to pending so the user
        // sees it still needs them (and can retry / skip) instead of a false
        // success in the activity log.
        let failed = result.hasPrefix("error") || result.hasPrefix("refused") || result.hasPrefix("busy")
        if let i = items.firstIndex(where: { $0.id == id }), failed {
            items[i].state = .pending
            items[i].resolvedAt = nil
            save()
        }
        WakeLog.shared.log("jax-approve: \(failed ? "FAILED" : "executed") '\(tool)' for \(id.uuidString.prefix(8)) -> \(result.prefix(120))")
        return result
    }

    // Decode a stored replay input back into a tool input dict. Fails soft to nil.
    static func decodeInput(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    // The user tapped no / dismiss. The action is dropped; nothing runs.
    func skip(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].state == .pending else { return }
        items[idx].state = .skipped
        items[idx].resolvedAt = Date()
        save()
    }

    // Drop resolved history older than a cutoff so the file does not grow without
    // bound. Pending items are never pruned regardless of age.
    func pruneResolved(olderThan seconds: TimeInterval = 60 * 60 * 24 * 30) {
        let cutoff = Date().addingTimeInterval(-seconds)
        let before = items.count
        items.removeAll { $0.state != .pending && ($0.resolvedAt ?? $0.createdAt) < cutoff }
        if items.count != before { save() }
    }

    // MARK: Menubar ping

    // Route the urgent item through Grux's existing triage notification path so it
    // lands as a real banner. .foundry is the closest existing category for
    // autonomous-engine activity that needs the user; actionRequired upgrades it to an
    // interrupt even under a batch/silent base policy (quiet hours still fold it
    // into the digest, matching the rest of the app). The body never leaks payload
    // beyond the human summary the gate already wrote.
    private func notifyUrgent(_ item: PendingApproval) {
        let title = "\(UserIdentity.assistantName) needs you: \(item.bannerNoun)"
        var body = item.summary
        if !item.reason.isEmpty { body += " (\(item.reason))" }
        NotificationManager.shared.sendCategorized(
            .foundry,
            actionRequired: true,
            title: title,
            body: body
        )
    }
}

private extension PendingApproval {
    // A short, safe label for the banner title that never leaks payload detail.
    var bannerNoun: String {
        switch action.kind {
        case .spend: return "approve a queued spend"
        case .externalComms: return "approve an outbound message"
        case .other: return "approve an action"
        }
    }
}
