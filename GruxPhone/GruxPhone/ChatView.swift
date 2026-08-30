import SwiftUI

// "Remote control for Grux" chat UI. Thread list → conversation view.
// Mirrors the Mac's Chat sidebar and message pane. Input at the bottom.
// Grux's reply shows up as a bubble when the Mac appends it; a "thinking…"
// row appears while Grux is working.

struct ChatHomeView: View {
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var transport = TransportService.shared
    @State private var navigatingTo: UUID?
    @State private var renaming: ThreadSummaryDTO?
    @State private var renameTitle: String = ""
    @State private var confirmDelete: ThreadSummaryDTO?

    var body: some View {
        NavigationStack {
            Group {
                if store.threads.isEmpty {
                    if case .streaming = transport.state {
                        ProgressView("Loading threads…")
                    } else {
                        disconnectedPlaceholder
                    }
                } else {
                    threadList
                }
            }
            .navigationTitle("Grux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { createNewThread() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!isReady)
                }
                ToolbarItem(placement: .topBarLeading) {
                    connectionDot
                }
            }
            .navigationDestination(item: $navigatingTo) { id in
                ChatConversationView(threadId: id)
            }
            .sheet(item: $renaming) { thread in
                renameSheet(for: thread)
            }
            .alert(
                "Delete this chat?",
                isPresented: Binding(
                    get: { confirmDelete != nil },
                    set: { if !$0 { confirmDelete = nil } }
                ),
                presenting: confirmDelete
            ) { target in
                Button("Delete", role: .destructive) {
                    TransportService.shared.sendChat(.deleteThread(threadId: target.id))
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            } message: { target in
                Text("“\(target.title)” · \(target.messageCount) messages")
            }
        }
    }

    private var connectionDot: some View {
        let (color, label): (Color, String) = {
            switch transport.state {
            case .idle: return (.gray, "Idle")
            case .dialing: return (.yellow, "Connecting")
            case .handshaking: return (.yellow, "Handshake")
            case .authenticating: return (.blue, "Auth")
            case .streaming: return (.green, "Live")
            case .failed: return (.red, "Error")
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(color)
        }
    }

    private var isReady: Bool {
        if case .streaming = transport.state { return true }
        return false
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Connecting to Grux on your Mac…")
                .font(.headline)
            Text(stateDescription)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                TransportService.shared.stopStreaming()
                TransportService.shared.startStreaming()
            }
            .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stateDescription: String {
        switch transport.state {
        case .idle: return "Tap Retry to reconnect."
        case .dialing(let h): return "Dialing \(h)…"
        case .handshaking: return "Handshaking…"
        case .authenticating: return "Authenticating…"
        case .streaming: return "Live"
        case .failed(let r): return r
        }
    }

    private var threadList: some View {
        List {
            ForEach(store.threads) { thread in
                ThreadRow(thread: thread, isActive: thread.id == store.activeThreadId)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.setActiveLocally(thread.id)
                        TransportService.shared.sendChat(.switchThread(threadId: thread.id))
                        navigatingTo = thread.id
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { confirmDelete = thread } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { beginRename(thread) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
        .refreshable { TransportService.shared.sendChat(.requestSync) }
    }

    private func beginRename(_ thread: ThreadSummaryDTO) {
        renameTitle = thread.title
        renaming = thread
    }

    private func renameSheet(for thread: ThreadSummaryDTO) -> some View {
        NavigationStack {
            Form {
                TextField("Title", text: $renameTitle)
            }
            .navigationTitle("Rename chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { renaming = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = renameTitle.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty {
                            TransportService.shared.sendChat(.renameThread(threadId: thread.id, title: t))
                        }
                        renaming = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createNewThread() {
        TransportService.shared.sendChat(.newThread(title: "New chat"))
    }
}

struct ThreadRow: View {
    let thread: ThreadSummaryDTO
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.cyan : Color.white.opacity(0.15))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title).font(.body.weight(.semibold)).lineLimit(1)
                    if thread.starred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text(timeShort(thread.updatedAt)).font(.caption2).foregroundStyle(.secondary)
                }
                if let p = thread.preview, !p.isEmpty {
                    Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(thread.messageCount) messages").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func timeShort(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct ChatConversationView: View {
    let threadId: UUID
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var transport = TransportService.shared
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages(for: threadId)) { msg in
                            MessageBubble(message: msg).id(msg.id)
                        }
                        if store.isThinking && store.activeThreadId == threadId {
                            HStack {
                                ThinkingPill()
                                Spacer()
                            }
                            .id("thinking")
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.messagesByThread[threadId]?.count ?? 0) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: store.optimistic[threadId]?.count ?? 0) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: store.isThinking) {
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                    // Make sure the Mac knows this is now our active thread.
                    if store.activeThreadId != threadId {
                        TransportService.shared.sendChat(.switchThread(threadId: threadId))
                    }
                }
            }

            composer
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(store.threads.first(where: { $0.id == threadId })?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if store.isThinking {
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            } else if let last = store.messages(for: threadId).last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Grux…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Color.cyan : Color.gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && {
            if case .streaming = transport.state { return true }; return false
        }()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = store.optimisticallyAddUserMessage(text)
        TransportService.shared.sendChat(.userMessage(threadId: threadId, text: text))
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessageDTO

    var body: some View {
        let isUser = message.role == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(message.content)
                    .foregroundStyle(isUser ? Color.black : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                        ? AnyShapeStyle(LinearGradient(colors: [Color.cyan, Color.mint],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                Text(roleLabel + "  " + shortTime(message.timestamp))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user": return "You"
        case "assistant": return "Grux"
        default: return message.role.uppercased()
        }
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: d)
    }
}

struct ThinkingPill: View {
    @State private var phase: Double = 0
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .scaleEffect(phase == Double(i) ? 1.2 : 0.8)
                    .opacity(phase == Double(i) ? 1.0 : 0.45)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                phase = (phase + 1).truncatingRemainder(dividingBy: 3)
            }
        }
    }
}
