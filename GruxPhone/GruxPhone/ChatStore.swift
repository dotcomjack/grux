import Foundation
import Combine

// Transient operator-action result for the cockpit toast. iOS-only (the shared
// SocialOpsModels stay byte-identical with the Mac, so this lives here).
struct SocialOpsToast: Equatable, Identifiable {
    let text: String
    let ok: Bool
    let id: Int64   // the ack ts, also used to retrigger the toast animation
}

// Mirrors Mac chat state on the phone. TransportService pumps every
// incoming ChatEnvelope through `ingest(_:)`. The UI observes @Published
// properties directly.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var threads: [ThreadSummaryDTO] = []
    @Published private(set) var messagesByThread: [UUID: [ChatMessageDTO]] = [:]
    @Published private(set) var summariesByThread: [UUID: String] = [:]
    @Published private(set) var activeThreadId: UUID?
    @Published private(set) var isThinking: Bool = false
    @Published private(set) var hasReceivedInitialSync: Bool = false

    // Optimistic user-message queue, shown immediately in UI before the Mac
    // echoes back. Clear when we see the message id arrive from Mac.
    @Published private(set) var optimistic: [UUID: [ChatMessageDTO]] = [:]

    // Social Ops Cockpit live grid. The Mac pushes the full snapshot; we always
    // reflect the latest pushed one (no caching, no stale data). When this is
    // non-nil the Ops tab appears.
    @Published private(set) var socialOpsPanel: SocialOpsSnapshot?

    // Transient result of the last operator action (drives a toast). Set from a
    // socialOpsAck the Mac sends after running a phone-issued command.
    @Published var socialOpsToast: SocialOpsToast?
    // Persistent last-action result per cell ("muted", "re-auth: 2FA needed"),
    // keyed by "brand|platform". Survives after the toast fades.
    @Published private(set) var lastActionByCell: [String: String] = [:]

    private init() {}

    func ingest(_ env: ChatEnvelope) {
        switch env {
        case .threadList(let threads):
            AppModel.diag("chat: threadList count=\(threads.count)")
            self.threads = threads.sorted(by: { $0.updatedAt > $1.updatedAt })
            hasReceivedInitialSync = true
        case .activeThread(let id):
            AppModel.diag("chat: activeThread id=\(id?.uuidString ?? "nil")")
            self.activeThreadId = id
        case .threadMessages(let threadId, let messages, let summary):
            AppModel.diag("chat: threadMessages thread=\(threadId) msgs=\(messages.count)")
            messagesByThread[threadId] = messages
            if let summary = summary {
                summariesByThread[threadId] = summary
            } else {
                summariesByThread.removeValue(forKey: threadId)
            }
            optimistic[threadId]?.removeAll { o in
                messages.contains { $0.role == o.role && $0.content == o.content }
            }
        case .userMessageEcho(let threadId, let message):
            AppModel.diag("chat: userEcho '\(message.content.prefix(60))'")
            append(threadId: threadId, message: message)
            optimistic[threadId]?.removeAll { $0.role == "user" && $0.content == message.content }
        case .assistantMessage(let threadId, let message):
            AppModel.diag("chat: assistantMessage '\(message.content.prefix(80))'")
            append(threadId: threadId, message: message)
        case .thinking(let on):
            AppModel.diag("chat: thinking=\(on)")
            isThinking = on
        case .socialOpsPanelSnapshot(let generatedAt, let records):
            AppModel.diag("chat: socialOpsPanelSnapshot count=\(records.count)")
            // Always reflect the latest pushed snapshot. No caching, no stale data.
            socialOpsPanel = SocialOpsSnapshot(
                generatedAt: generatedAt, source: "live", records: records
            )
        case .socialOpsAck(let brand, let platform, let status, let message, let ts):
            AppModel.diag("chat: socialOpsAck \(brand)/\(platform) \(status)")
            let ok = (status == "ok" || status == "acknowledged" || status == "done")
            let text = (message?.isEmpty == false ? message! : status)
            socialOpsToast = SocialOpsToast(text: text, ok: ok, id: ts)
            if !brand.isEmpty && !platform.isEmpty {
                lastActionByCell["\(brand)|\(platform)"] = text
            }
        default:
            break
        }
    }

    private func append(threadId: UUID, message: ChatMessageDTO) {
        var msgs = messagesByThread[threadId] ?? []
        if !msgs.contains(where: { $0.id == message.id }) {
            msgs.append(message)
            messagesByThread[threadId] = msgs
        }
    }

    // UI-facing helpers ---------------------------------------------------

    var activeThread: ThreadSummaryDTO? {
        guard let id = activeThreadId else { return nil }
        return threads.first(where: { $0.id == id })
    }

    func messages(for threadId: UUID) -> [ChatMessageDTO] {
        var base = messagesByThread[threadId] ?? []
        if let opt = optimistic[threadId] { base.append(contentsOf: opt) }
        return base
    }

    var activeMessages: [ChatMessageDTO] {
        guard let id = activeThreadId else { return [] }
        return messages(for: id)
    }

    // Optimistic add, shows the user bubble immediately in the list while
    // the Mac processes. Self-clears when the Mac echoes it back.
    func optimisticallyAddUserMessage(_ text: String) -> ChatMessageDTO {
        guard let id = activeThreadId else {
            return ChatMessageDTO(id: UUID(), role: "user", content: text, timestamp: Date())
        }
        let dto = ChatMessageDTO(id: UUID(), role: "user", content: text, timestamp: Date())
        var list = optimistic[id] ?? []
        list.append(dto)
        optimistic[id] = list
        return dto
    }

    func setActiveLocally(_ id: UUID) {
        activeThreadId = id
    }
}
