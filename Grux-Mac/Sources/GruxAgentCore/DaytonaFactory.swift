import Foundation

public struct FactoryRefusal: Error, Equatable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public struct FactoryJob: Sendable, Equatable {
    public var diff: String
    public var scoreCommand: String
    public var timeoutSec: Int

    public init(diff: String, scoreCommand: String, timeoutSec: Int) {
        self.diff = diff
        self.scoreCommand = scoreCommand
        self.timeoutSec = timeoutSec
    }
}

public struct FactoryScore: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var sandboxId: String

    public init(exitCode: Int32, stdout: String, sandboxId: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.sandboxId = sandboxId
    }
}

public struct DaytonaEndpoints: Sendable, Equatable {
    public var createURL: String
    public var execURLTemplate: String
    public var deleteURLTemplate: String
    public var listURL: String
    public var authHeaderName: String

    public init(createURL: String, execURLTemplate: String, deleteURLTemplate: String, listURL: String, authHeaderName: String) {
        self.createURL = createURL
        self.execURLTemplate = execURLTemplate
        self.deleteURLTemplate = deleteURLTemplate
        self.listURL = listURL
        self.authHeaderName = authHeaderName
    }

    /// Documented shapes. Task 1's probe doc replaces these if a live call differs.
    public static let documented = DaytonaEndpoints(
        createURL: "https://app.daytona.io/api/sandbox",
        execURLTemplate: "https://proxy.app.daytona.io/toolbox/{id}/process/execute",
        deleteURLTemplate: "https://app.daytona.io/api/sandbox/{id}",
        listURL: "https://app.daytona.io/api/sandbox",
        authHeaderName: "Authorization"
    )
}

public protocol DaytonaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Int, Data)
}

public struct DaytonaFactory {
    private let transport: any DaytonaTransport
    private let endpoints: DaytonaEndpoints
    private let now: () -> Date

    public init(transport: any DaytonaTransport, endpoints: DaytonaEndpoints, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.endpoints = endpoints
        self.now = now
    }

    public func score(_ job: FactoryJob) async throws -> FactoryScore {
        let verdict = FactoryPrivacy.check(diff: job.diff, scoreCommand: job.scoreCommand, env: [:])
        if case .refuse(let reason) = verdict {
            throw FactoryRefusal(reason: reason)
        }
        let id = try await create()
        let ran: FactoryScore
        do {
            ran = try await exec(id: id, diff: job.diff, timeoutSec: job.timeoutSec)
        } catch {
            try? await delete(id: id)
            throw error
        }
        try? await delete(id: id)
        return ran
    }

    public func reap(olderThan seconds: TimeInterval) async throws -> [String] {
        let list = try await send(method: "GET", url: endpoints.listURL, json: nil)
        let rows = Self.rows(in: list.1)
        var deleted: [String] = []
        let clock = now()
        for row in rows {
            guard let id = row["id"] as? String, Self.isFactory(row) else { continue }
            guard Self.isOlder(row, than: seconds, now: clock) else { continue }
            try await delete(id: id)
            deleted.append(id)
        }
        return deleted
    }

    /// The sandbox always clones the public repo and runs factory/score.sh.
    /// `job.scoreCommand` is scanned by FactoryPrivacy and is not interpolated.
    static func remoteCommand(diff: String) -> String {
        let b64 = Data(diff.utf8).base64EncodedString()
        return "printf '%s' '\(b64)' | base64 -d > /tmp/job.diff && git clone --depth 1 https://github.com/dotcomjack/grux.git repo && cd repo && git apply --check /tmp/job.diff && git apply /tmp/job.diff && bash factory/score.sh"
    }

    private func create() async throws -> String {
        let payload: [String: Any] = [
            "snapshot": "daytona-small",
            "labels": ["grux.factory": "1"],
            "autoStopInterval": 30,
        ]
        let response = try await send(method: "POST", url: endpoints.createURL, json: payload)
        let obj = (try? JSONSerialization.jsonObject(with: response.1)) as? [String: Any]
        guard let id = obj?["id"] as? String, !id.isEmpty else {
            throw FactoryRefusal(reason: "create-shape")
        }
        return id
    }

    private func exec(id: String, diff: String, timeoutSec: Int) async throws -> FactoryScore {
        let url = endpoints.execURLTemplate.replacingOccurrences(of: "{id}", with: id)
        let payload: [String: Any] = [
            "command": Self.remoteCommand(diff: diff),
            "timeout": timeoutSec,
        ]
        let response = try await send(method: "POST", url: url, json: payload)
        let obj = (try? JSONSerialization.jsonObject(with: response.1)) as? [String: Any] ?? [:]
        let code = (obj["exitCode"] as? NSNumber)?.int32Value ?? 0
        let stdout = obj["result"] as? String ?? ""
        return FactoryScore(exitCode: code, stdout: stdout, sandboxId: id)
    }

    private func delete(id: String) async throws {
        let url = endpoints.deleteURLTemplate.replacingOccurrences(of: "{id}", with: id)
        _ = try await send(method: "DELETE", url: url, json: nil)
    }

    private func send(method: String, url: String, json: Any?) async throws -> (Int, Data) {
        guard let parsed = URL(string: url) else {
            throw FactoryRefusal(reason: "bad-url")
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var raw = try JSONSerialization.data(withJSONObject: json, options: [])
            if var text = String(data: raw, encoding: .utf8) {
                text = text.replacingOccurrences(of: "\\/", with: "/")
                raw = Data(text.utf8)
            }
            request.httpBody = raw
        }
        return try await transport.send(request)
    }

    private static func rows(in data: Data) -> [[String: Any]] {
        let obj = try? JSONSerialization.jsonObject(with: data)
        if let rows = obj as? [[String: Any]] { return rows }
        if let dict = obj as? [String: Any] {
            // Live list is {items, nextCursor}. Tests still send sandboxes.
            if let rows = dict["items"] as? [[String: Any]] { return rows }
            if let rows = dict["sandboxes"] as? [[String: Any]] { return rows }
        }
        return []
    }

    private static func isFactory(_ row: [String: Any]) -> Bool {
        let labels = row["labels"] as? [String: Any]
        if let value = labels?["grux.factory"] as? String { return value == "1" }
        if let value = labels?["grux.factory"] as? NSNumber { return value.intValue == 1 }
        return false
    }

    private static func isOlder(_ row: [String: Any], than seconds: TimeInterval, now: Date) -> Bool {
        guard let text = row["createdAt"] as? String else { return true }
        let formatter = ISO8601DateFormatter()
        guard let created = formatter.date(from: text) else { return true }
        return now.timeIntervalSince(created) > seconds
    }
}
