import Foundation

/// Import a custom endpoint's API key from a file the person (or their
/// script) drops at `~/.grux/fire-endpoint-key`: two lines, the endpoint id
/// then the key. Grux writes the key into the Keychain ITSELF, which is the
/// whole point: an item created by the `security` tool carries a partition
/// that makes every read from this app raise a login-password prompt, and a
/// read that prompts freezes the main thread for as long as the prompt sits.
/// Same posture as inject-chat.txt: the file is 0600, read once, overwritten
/// with zeros and deleted before anything else happens.
enum EndpointKeyImport {
    enum Target: Equatable { case endpoint(UUID), typesafe }

    static func parse(_ text: String) -> (target: Target, key: String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        if lines[0].lowercased() == "typesafe" { return (.typesafe, lines[1]) }
        guard let id = UUID(uuidString: lines[0]) else { return nil }
        return (.endpoint(id), lines[1])
    }

    /// Reads and shreds the file, then stores the key. Returns a one-line
    /// result for the log; never the key.
    @MainActor
    static func consume(fileURL: URL, store: CustomEndpointStore? = nil) -> String {
        let store = store ?? CustomEndpointStore.shared
        guard let data = try? Data(contentsOf: fileURL) else { return "endpoint key import: no file" }
        shred(fileURL, length: data.count)
        guard let text = String(data: data, encoding: .utf8), let parsed = parse(text) else {
            return "endpoint key import: file did not hold an endpoint id (or typesafe) and a key"
        }
        switch parsed.target {
        case .typesafe:
            let ok = KeychainStore.set(.typesafeApiKey, parsed.key)
                && KeychainStore.get(.typesafeApiKey) == parsed.key
            return ok ? "endpoint key import: stored the decision provider key" : "endpoint key import: Keychain write failed"
        case .endpoint(let id):
            guard store.endpoint(id: id) != nil else {
                return "endpoint key import: no endpoint with id \(id.uuidString)"
            }
            let ok = store.setAPIKey(parsed.key, for: id)
            return ok ? "endpoint key import: stored for \(id.uuidString)" : "endpoint key import: Keychain write failed"
        }
    }

    private static func shred(_ url: URL, length: Int) {
        if length > 0, let h = try? FileHandle(forWritingTo: url) {
            h.write(Data(repeating: 0, count: length)); try? h.close()
        }
        try? FileManager.default.removeItem(at: url)
    }
}
