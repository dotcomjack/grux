import Foundation

// MARK: - ShellSessionManager
//
// Global registry of active sessions keyed by sessionId. One instance per app
// (singleton). Responsible for:
//   - allocating new sessions + their ids
//   - routing commands to the right session
//   - tearing down sessions on end / on app quit
//
// Lives as an actor so all lookups / mutations are serialized. Every call from
// the tool dispatch path goes through `withSession(id: …)` which resolves the
// session or throws a clear "session not found" error for Claude to read.

public actor ShellSessionManager {
    public static let shared = ShellSessionManager()

    private var sessions: [String: ShellSession] = [:]

    private init() {}

    public func startSession(rootDir: String, mode: ShellMode, undoMode: ShellUndoMode, openMirror: Bool) async throws -> ShellSessionInfo {
        let std = ShellAllowlist.standardize(rootDir)
        let id = Self.newId()
        let mirror: ShellTerminalMirror? = openMirror ? ShellTerminalMirror(sessionId: id, logPath: "/tmp/grux-session-\(id).log") : nil
        let session = ShellSession(id: id, rootDir: std, mode: mode, undoMode: undoMode, mirror: mirror)
        try await session.start()
        if let mirror = mirror {
            await mirror.open(rootDir: std, mode: mode, undoMode: undoMode)
        }
        sessions[id] = session
        return await session.info()
    }

    public func run(sessionId: String, command: String, timeoutSec: Int = 120) async throws -> ShellRunResult {
        let s = try resolve(sessionId)
        return try await s.run(command: command, timeoutSec: timeoutSec)
    }

    public func runConfirmed(sessionId: String, command: String, timeoutSec: Int = 120) async throws -> ShellRunResult {
        let s = try resolve(sessionId)
        return try await s.runConfirmed(command: command, timeoutSec: timeoutSec)
    }

    public func undo(sessionId: String, to snapshotId: String?) async throws -> (restoredTo: String, changed: [String]) {
        let s = try resolve(sessionId)
        return try await s.undo(to: snapshotId)
    }

    public func status(sessionId: String) async throws -> ShellSessionInfo {
        let s = try resolve(sessionId)
        return await s.info()
    }

    public func listSnapshots(sessionId: String) async throws -> [ShellSnapshotRecord] {
        let s = try resolve(sessionId)
        return await s.snapshots.list()
    }

    public func end(sessionId: String) async throws {
        let s = try resolve(sessionId)
        await s.end()
        sessions.removeValue(forKey: sessionId)
    }

    public func listSessions() async -> [ShellSessionInfo] {
        var out: [ShellSessionInfo] = []
        for (_, s) in sessions {
            out.append(await s.info())
        }
        return out
    }

    // MARK: - Internals

    private func resolve(_ id: String) throws -> ShellSession {
        guard let s = sessions[id] else { throw ShellToolError.sessionNotFound(id) }
        return s
    }

    private static func newId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let ts = fmt.string(from: Date())
        let rand = String(UUID().uuidString.prefix(6)).lowercased()
        return "sh-\(ts)-\(rand)"
    }
}
