import Foundation

/// The line under the composer, in words rather than in accounting.
///
/// Measured on the running app 2026-09-20, the footer read:
/// `llama3.2:3b | est $0.0294 for this send | i...ok | cheaper: qwen3.5:4b free`
/// Four pieces of internal bookkeeping on the most looked-at surface in the
/// app, including a raw model identifier and a token count that a person
/// cannot act on.
///
/// What survives is what a person can act on: which model is answering, in its
/// own display name, and what this send costs. The cheaper-alternative nudge
/// moves to the model picker, which is the place you would go to take it up.
enum ComposerFooter {
    /// Prices below this read as a phrase rather than as a number, because
    /// four decimal places on the face is accounting, not information.
    static let subCentThreshold = 0.01

    static func line(modelDisplayName: String,
                     estimatedUSD: Double?) -> String {
        var parts = [modelDisplayName]
        if let usd = estimatedUSD { parts.append(cost(usd)) }
        return parts.joined(separator: "  |  ")
    }

    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "free" }
        if usd < subCentThreshold { return "under a cent" }
        return "about $" + String(format: "%.2f", usd)
    }

    /// A model's own name, never its identifier. `llama3.2:3b` is a string the
    /// app needs and a person does not.
    static func displayName(id: String, registryName: String?) -> String {
        if let registryName, !registryName.isEmpty { return registryName }
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: "-", with: " ")
        guard !s.isEmpty else { return id }
        return s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
