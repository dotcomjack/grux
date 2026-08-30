import SwiftUI
import Foundation
import GruxShellCore

// MARK: - SessionsObserver
//
// Lightweight poll-based observer of ShellSessionManager. Re-reads the live
// session list every 2s and publishes a sorted snapshot. This is deliberately
// poll-based rather than pub/sub - the session manager is an actor, and most
// sessions live for seconds-to-minutes so polling cost is trivial.

@MainActor
final class SessionsObserver: ObservableObject {
    static let shared = SessionsObserver()

    @Published var sessions: [ShellSessionInfo] = []
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Fire once immediately, then poll.
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func refresh() {
        Task { @MainActor in
            let list = await ShellSessionManager.shared.listSessions()
            let sorted = list.sorted { $0.startedAt < $1.startedAt }
            if sorted.map(\.sessionId) != sessions.map(\.sessionId)
                || zip(sorted, sessions).contains(where: { $0.commandsRun != $1.commandsRun }) {
                sessions = sorted
            }
        }
    }

    func end(_ id: String) {
        Task {
            try? await ShellSessionManager.shared.end(sessionId: id)
            await MainActor.run { self.refresh() }
        }
    }
}

// MARK: - SessionsStrip
//
// Horizontal strip of live Grux shell sessions - one tab per session. Click a
// tab to open the log viewer sheet; click × to end the session. Hidden when
// no sessions are running so the chat UI stays clean during normal convos.

struct SessionsStrip: View {
    @StateObject private var observer = SessionsObserver.shared
    @State private var openSession: ShellSessionInfo?

    var body: some View {
        Group {
            if observer.sessions.isEmpty {
                EmptyView()
            } else {
                stripBody
            }
        }
        .onAppear { observer.start() }
        .sheet(item: $openSession) { info in
            SessionLogSheet(info: info) {
                openSession = nil
            }
        }
    }

    private var stripBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(GruxTheme.accentPrimary)
            Text("GRUX SESSIONS")
                .font(GruxTheme.Font.microCaps)
                .kerning(1.2)
                .foregroundStyle(GruxTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(observer.sessions, id: \.sessionId) { s in
                        sessionChip(s)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.20))
                Rectangle().fill(GruxTheme.accentPrimary.opacity(0.05))
            }
        )
    }

    private func sessionChip(_ s: ShellSessionInfo) -> some View {
        HStack(spacing: 6) {
            Button {
                openSession = s
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(GruxTheme.successMint)
                        .frame(width: 6, height: 6)
                        .shadow(color: GruxTheme.successMint.opacity(0.5), radius: 3)
                    Text((s.rootDir as NSString).lastPathComponent)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(s.commandsRun)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(GruxTheme.accentPrimary.opacity(0.14))
                        .overlay(Capsule().strokeBorder(GruxTheme.accentPrimary.opacity(0.35), lineWidth: 0.8))
                )
            }
            .buttonStyle(.plain)
            .help("\(s.sessionId) · \(s.rootDir) · \(s.commandsRun) cmds")

            Button {
                observer.end(s.sessionId)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(4)
                    .background(
                        Circle().fill(Color.white.opacity(0.05))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
                    )
            }
            .buttonStyle(.plain)
            .help("End session \(s.sessionId)")
        }
    }
}

// MARK: - SessionLogSheet
//
// Pops up on tab click. Tails the mirror log file (/tmp/grux-session-<id>.log)
// so the user can watch commands land in near-real-time. Includes a small
// metadata header (cwd, mode, commandsRun) and an "End session" button.

struct SessionLogSheet: View {
    let info: ShellSessionInfo
    let onDismiss: () -> Void
    @State private var log: String = ""
    @State private var timer: Timer?
    @State private var autoScroll: Bool = true

    private var logPath: String { "/tmp/grux-session-\(info.sessionId).log" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            logScroll
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { startTailing() }
        .onDisappear { stopTailing() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.sessionId).font(.headline.monospaced())
                Text(info.rootDir)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("mode: \(info.mode.rawValue) · undo: \(info.undoMode.rawValue) · cwd: \(info.cwd) · \(info.commandsRun) cmds · \(info.snapshotsTaken) snaps")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll).controlSize(.small)
            Button("Close") { onDismiss() }
        }
        .padding(14)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "(waiting for output…)" : log)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("log-tail")
            }
            .background(Color.black.opacity(0.85))
            .foregroundStyle(Color.green.opacity(0.9))
            .onChange(of: log) { _, _ in
                guard autoScroll else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("log-tail", anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(logPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("End session") {
                SessionsObserver.shared.end(info.sessionId)
                onDismiss()
            }
            .tint(.red)
        }
        .padding(12)
    }

    // Poll the mirror log file every 500ms. Cheap - typical sessions produce
    // tens of lines total, and we read-then-replace the full file each tick.
    private func startTailing() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refresh()
        }
    }

    private func stopTailing() {
        timer?.invalidate(); timer = nil
    }

    private func refresh() {
        if FileManager.default.fileExists(atPath: logPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let s = String(data: data, encoding: .utf8) {
            if s != log { log = s }
        }
    }
}

extension ShellSessionInfo: Identifiable {
    public var id: String { sessionId }
}
