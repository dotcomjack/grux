import Foundation

// BYTE-IDENTICAL copy of the Mac's Sources/Grux/iPhone/PhoneChatEnvelope.swift.
// Keep in lockstep.

struct ThreadSummaryDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let starred: Bool
    let updatedAt: Date
    let messageCount: Int
    let preview: String?
}

struct ChatMessageDTO: Codable, Hashable, Identifiable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
}

enum ChatEnvelope: Codable {
    case userMessage(threadId: UUID, text: String)
    case switchThread(threadId: UUID)
    case newThread(title: String?)
    case renameThread(threadId: UUID, title: String)
    case deleteThread(threadId: UUID)
    case requestSync
    case agentResumeRequest(jobId: String)

    case threadList(threads: [ThreadSummaryDTO])
    case threadMessages(threadId: UUID, messages: [ChatMessageDTO], summary: String?)
    case activeThread(threadId: UUID?)
    case thinking(isThinking: Bool)
    case assistantMessage(threadId: UUID, message: ChatMessageDTO)
    case userMessageEcho(threadId: UUID, message: ChatMessageDTO)
    case agentPaused(jobId: String, title: String, accountLabel: String?, reason: String, ts: Int64)
    // Social Ops Cockpit. The Mac pushes the full live grid to the phone; the
    // phone routes two-tap operator actions back. All payloads carry no secrets.
    //   socialOpsPanelSnapshot: mac → phone, the live brand × platform grid.
    //     generatedAt is a unix-millis stamp the phone uses for freshness.
    //   socialOpsAction: phone → mac, a two-tap control on one cell.
    //     action is "retry"|"reauth"|"mute"|"approve"; ts is unix-millis.
    //   socialOpsAck: mac → phone, optional ack of an action's outcome.
    case socialOpsPanelSnapshot(generatedAt: Int64, records: [SocialHealthRecord])
    case socialOpsAction(brand: String, platform: String, action: String, ts: Int64)
    case socialOpsAck(brand: String, platform: String, status: String, message: String?, ts: Int64)

    enum CodingKeys: String, CodingKey { case type, payload }
    private struct UserMessageP: Codable { let threadId: UUID; let text: String }
    private struct SwitchP: Codable { let threadId: UUID }
    private struct NewP: Codable { let title: String? }
    private struct RenameP: Codable { let threadId: UUID; let title: String }
    private struct DeleteP: Codable { let threadId: UUID }
    private struct ThreadListP: Codable { let threads: [ThreadSummaryDTO] }
    private struct ThreadMessagesP: Codable { let threadId: UUID; let messages: [ChatMessageDTO]; let summary: String? }
    private struct ActiveP: Codable { let threadId: UUID? }
    private struct ThinkingP: Codable { let isThinking: Bool }
    private struct AssistantMsgP: Codable { let threadId: UUID; let message: ChatMessageDTO }
    private struct AgentPausedP: Codable {
        let jobId: String
        let title: String
        let accountLabel: String?
        let reason: String
        let ts: Int64
    }
    private struct AgentResumeReqP: Codable { let jobId: String }
    private struct SocialOpsPanelSnapshotP: Codable {
        let generatedAt: Int64
        let records: [SocialHealthRecord]
    }
    private struct SocialOpsActionP: Codable {
        let brand: String
        let platform: String
        let action: String
        let ts: Int64
    }
    private struct SocialOpsAckP: Codable {
        let brand: String
        let platform: String
        let status: String
        let message: String?
        let ts: Int64
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userMessage(let t, let x):
            try c.encode("userMessage", forKey: .type)
            try c.encode(UserMessageP(threadId: t, text: x), forKey: .payload)
        case .switchThread(let t):
            try c.encode("switchThread", forKey: .type)
            try c.encode(SwitchP(threadId: t), forKey: .payload)
        case .newThread(let title):
            try c.encode("newThread", forKey: .type)
            try c.encode(NewP(title: title), forKey: .payload)
        case .renameThread(let t, let title):
            try c.encode("renameThread", forKey: .type)
            try c.encode(RenameP(threadId: t, title: title), forKey: .payload)
        case .deleteThread(let t):
            try c.encode("deleteThread", forKey: .type)
            try c.encode(DeleteP(threadId: t), forKey: .payload)
        case .requestSync:
            try c.encode("requestSync", forKey: .type)
        case .threadList(let threads):
            try c.encode("threadList", forKey: .type)
            try c.encode(ThreadListP(threads: threads), forKey: .payload)
        case .threadMessages(let t, let msgs, let sum):
            try c.encode("threadMessages", forKey: .type)
            try c.encode(ThreadMessagesP(threadId: t, messages: msgs, summary: sum), forKey: .payload)
        case .activeThread(let t):
            try c.encode("activeThread", forKey: .type)
            try c.encode(ActiveP(threadId: t), forKey: .payload)
        case .thinking(let on):
            try c.encode("thinking", forKey: .type)
            try c.encode(ThinkingP(isThinking: on), forKey: .payload)
        case .assistantMessage(let t, let m):
            try c.encode("assistantMessage", forKey: .type)
            try c.encode(AssistantMsgP(threadId: t, message: m), forKey: .payload)
        case .userMessageEcho(let t, let m):
            try c.encode("userMessageEcho", forKey: .type)
            try c.encode(AssistantMsgP(threadId: t, message: m), forKey: .payload)
        case .agentPaused(let jid, let ti, let acct, let reason, let ts):
            try c.encode("agentPaused", forKey: .type)
            try c.encode(AgentPausedP(jobId: jid, title: ti, accountLabel: acct, reason: reason, ts: ts), forKey: .payload)
        case .agentResumeRequest(let jid):
            try c.encode("agentResumeRequest", forKey: .type)
            try c.encode(AgentResumeReqP(jobId: jid), forKey: .payload)
        case .socialOpsPanelSnapshot(let ga, let recs):
            try c.encode("socialOpsPanelSnapshot", forKey: .type)
            try c.encode(SocialOpsPanelSnapshotP(generatedAt: ga, records: recs), forKey: .payload)
        case .socialOpsAction(let b, let p, let a, let ts):
            try c.encode("socialOpsAction", forKey: .type)
            try c.encode(SocialOpsActionP(brand: b, platform: p, action: a, ts: ts), forKey: .payload)
        case .socialOpsAck(let b, let p, let st, let msg, let ts):
            try c.encode("socialOpsAck", forKey: .type)
            try c.encode(SocialOpsAckP(brand: b, platform: p, status: st, message: msg, ts: ts), forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "userMessage":
            let p = try c.decode(UserMessageP.self, forKey: .payload)
            self = .userMessage(threadId: p.threadId, text: p.text)
        case "switchThread":
            let p = try c.decode(SwitchP.self, forKey: .payload)
            self = .switchThread(threadId: p.threadId)
        case "newThread":
            let p = try c.decode(NewP.self, forKey: .payload)
            self = .newThread(title: p.title)
        case "renameThread":
            let p = try c.decode(RenameP.self, forKey: .payload)
            self = .renameThread(threadId: p.threadId, title: p.title)
        case "deleteThread":
            let p = try c.decode(DeleteP.self, forKey: .payload)
            self = .deleteThread(threadId: p.threadId)
        case "requestSync":
            self = .requestSync
        case "threadList":
            let p = try c.decode(ThreadListP.self, forKey: .payload)
            self = .threadList(threads: p.threads)
        case "threadMessages":
            let p = try c.decode(ThreadMessagesP.self, forKey: .payload)
            self = .threadMessages(threadId: p.threadId, messages: p.messages, summary: p.summary)
        case "activeThread":
            let p = try c.decode(ActiveP.self, forKey: .payload)
            self = .activeThread(threadId: p.threadId)
        case "thinking":
            let p = try c.decode(ThinkingP.self, forKey: .payload)
            self = .thinking(isThinking: p.isThinking)
        case "assistantMessage":
            let p = try c.decode(AssistantMsgP.self, forKey: .payload)
            self = .assistantMessage(threadId: p.threadId, message: p.message)
        case "userMessageEcho":
            let p = try c.decode(AssistantMsgP.self, forKey: .payload)
            self = .userMessageEcho(threadId: p.threadId, message: p.message)
        case "agentPaused":
            let p = try c.decode(AgentPausedP.self, forKey: .payload)
            self = .agentPaused(jobId: p.jobId, title: p.title, accountLabel: p.accountLabel, reason: p.reason, ts: p.ts)
        case "agentResumeRequest":
            let p = try c.decode(AgentResumeReqP.self, forKey: .payload)
            self = .agentResumeRequest(jobId: p.jobId)
        case "socialOpsPanelSnapshot":
            let p = try c.decode(SocialOpsPanelSnapshotP.self, forKey: .payload)
            self = .socialOpsPanelSnapshot(generatedAt: p.generatedAt, records: p.records)
        case "socialOpsAction":
            let p = try c.decode(SocialOpsActionP.self, forKey: .payload)
            self = .socialOpsAction(brand: p.brand, platform: p.platform, action: p.action, ts: p.ts)
        case "socialOpsAck":
            let p = try c.decode(SocialOpsAckP.self, forKey: .payload)
            self = .socialOpsAck(brand: p.brand, platform: p.platform, status: p.status, message: p.message, ts: p.ts)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown envelope type: \(type)"
            )
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    func encode() throws -> Data { try Self.encoder.encode(self) }
    static func decode(_ data: Data) throws -> ChatEnvelope {
        try Self.decoder.decode(ChatEnvelope.self, from: data)
    }
}
