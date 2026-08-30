import Foundation
import Combine

// Bridges phone ChatEnvelopes <-> ChatService/AppState.
//
// Outbound (Mac → phone):
//   - On AppState.$threads change → send threadList
//   - On AppState.$activeThreadId change → send activeThread + threadMessages
//   - On AppState.$chat change → send threadMessages (full) for active thread
//   - On AppState.$isThinking change → send thinking(on/off)
//   - When a single new .assistant message appears → also send assistantMessage
//     (lets the phone animate a single-new-bubble drop without reflowing)
//
// Inbound (phone → Mac):
//   - userMessage → AppState.switchThread (if needed) + ChatService.send
//   - switchThread → AppState.switchThread
//   - newThread    → AppState.newThread + switch
//   - renameThread → AppState.renameThread
//   - deleteThread → AppState.deleteThread
//   - requestSync  → broadcast threadList + activeThread + current messages
//
// The bridge is one-per-PhoneReceiverService session. PhoneReceiverService
// creates/destroys it per connection.
@MainActor
final class PhoneChatBridge {
    private var cancellables = Set<AnyCancellable>()
    private weak var receiver: PhoneReceiverService?
    private var lastMessagesById: [UUID: ChatMessage] = [:]

    init(receiver: PhoneReceiverService) {
        self.receiver = receiver
        observe()
        // Send initial snapshot to the phone.
        sendFullSync()
    }

    deinit {
        cancellables.forEach { $0.cancel() }
    }

    // MARK: - Observation

    private func observe() {
        let state = AppState.shared
        state.$threads
            .removeDuplicates { $0.map(\.id) == $1.map(\.id)
                && zip($0, $1).allSatisfy { $0.title == $1.title && $0.updatedAt == $1.updatedAt } }
            .sink { [weak self] list in self?.sendThreadList(list) }
            .store(in: &cancellables)

        state.$activeThreadId
            .removeDuplicates()
            .sink { [weak self] id in
                self?.sendActiveThread(id)
                self?.sendCurrentMessages()
            }
            .store(in: &cancellables)

        state.$chat
            .dropFirst()   // initial snapshot already sent via sendFullSync
            .sink { [weak self] msgs in self?.onChatChanged(msgs) }
            .store(in: &cancellables)

        state.$isThinking
            .removeDuplicates()
            .sink { [weak self] on in self?.send(.thinking(isThinking: on)) }
            .store(in: &cancellables)
    }

    // Detect new-since-last-seen messages so we can push them as single
    // bubble-drop events in addition to the full refresh.
    private func onChatChanged(_ msgs: [ChatMessage]) {
        guard let threadId = AppState.shared.activeThreadId else { return }
        // Emit a single "new" message event if exactly one fresh id appears.
        let known = Set(lastMessagesById.keys)
        let nowIds = Set(msgs.map { $0.id })
        let newIds = nowIds.subtracting(known)
        if let newId = newIds.first, newIds.count == 1,
           let new = msgs.first(where: { $0.id == newId }) {
            let dto = ChatMessageDTO(
                id: new.id, role: new.role.rawValue,
                content: new.content, timestamp: new.timestamp
            )
            switch new.role {
            case .assistant:
                send(.assistantMessage(threadId: threadId, message: dto))
            case .user:
                send(.userMessageEcho(threadId: threadId, message: dto))
            case .system:
                break
            }
        }
        // Always refresh the authoritative message array so diverging clients
        // self-heal.
        sendMessages(threadId: threadId, msgs: msgs, summary: AppState.shared.activeThreadSummary)
        lastMessagesById = Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, $0) })
    }

    // MARK: - Broadcasting helpers

    private func send(_ env: ChatEnvelope) {
        receiver?.sendChatEnvelope(env)
    }

    func sendFullSync() {
        sendThreadList(AppState.shared.threads)
        sendActiveThread(AppState.shared.activeThreadId)
        sendCurrentMessages()
        send(.thinking(isThinking: AppState.shared.isThinking))
    }

    private func sendThreadList(_ list: [ChatThreadIndexEntry]) {
        let dtos = list.map {
            ThreadSummaryDTO(
                id: $0.id, title: $0.title, starred: $0.starred,
                updatedAt: $0.updatedAt, messageCount: $0.messageCount,
                preview: $0.preview
            )
        }
        send(.threadList(threads: dtos))
    }

    private func sendActiveThread(_ id: UUID?) {
        send(.activeThread(threadId: id))
    }

    private func sendCurrentMessages() {
        guard let id = AppState.shared.activeThreadId else { return }
        let msgs = AppState.shared.chat
        sendMessages(threadId: id, msgs: msgs, summary: AppState.shared.activeThreadSummary)
        lastMessagesById = Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, $0) })
    }

    private func sendMessages(threadId: UUID, msgs: [ChatMessage], summary: String?) {
        let dtos = msgs.map {
            ChatMessageDTO(
                id: $0.id, role: $0.role.rawValue,
                content: $0.content, timestamp: $0.timestamp
            )
        }
        send(.threadMessages(threadId: threadId, messages: dtos, summary: summary))
    }

    // MARK: - Inbound handling

    func handle(_ env: ChatEnvelope) {
        switch env {
        case .userMessage(let threadId, let text):
            if AppState.shared.activeThreadId != threadId {
                AppState.shared.switchThread(threadId)
            }
            Task { await ChatService.shared.send(userText: text) }

        case .switchThread(let id):
            AppState.shared.switchThread(id)

        case .newThread(let title):
            let id = AppState.shared.newThread(title: title ?? "New chat")
            sendActiveThread(id)
            sendCurrentMessages()

        case .renameThread(let id, let title):
            AppState.shared.renameThread(id, title: title)

        case .deleteThread(let id):
            AppState.shared.deleteThread(id)

        case .requestSync:
            sendFullSync()

        case .agentResumeRequest(let jobId):
            // Phone "Resume on Mac" tap. We don't carry out the swap here -
            // the OAuth flow has to run on the Mac. Open the Agents tab
            // focused on the paused job; the Resume sheet appears once the
            // user clicks Resume there. Posting via the same notification
            // channel as the macOS UNUserNotification taps keeps the entry
            // points unified.
            NotificationCenter.default.post(
                name: .gruxNotificationAction,
                object: nil,
                userInfo: [
                    "action": "grux.agent.resume",
                    "userInfo": ["jobId": jobId, "kind": "agentPaused", "source": "phone"] as [String: Any]
                ]
            )

        case .phaseTransitioned:
            // Mac→Phone only - Mac shouldn't receive its own outbound type.
            // Explicit no-op (instead of falling through to `default`) so a
            // future ack/echo from the phone is impossible to silently miss.
            break

        case .socialOpsAction(let brand, let platform, let action, _):
            // A two-tap operator control from the phone. Route it to the
            // Social Ops coordinator, which POSTs the command to the companion
            // social-ops service and then re-pushes the refreshed grid to the
            // phone.
            SocialOpsCoordinator.shared.executePhoneAction(
                brand: brand, platform: platform, action: action
            )

        case .socialOpsPanelSnapshot, .socialOpsAck:
            // Mac→Phone only - Mac shouldn't receive its own outbound types.
            // Explicit no-op so a future phone-side echo is impossible to miss.
            break

        default:
            // Mac shouldn't receive the server-side types. Ignore silently.
            break
        }
    }
}
