import Foundation

// SymbolCollisionScanner: the offline, deterministic half of the quality gate's
// duplication defense. It catches the failure that produced "CognitiveMap" vs
// "Cognition Map" and the duplicate ProductCatalog: a staged feature that
// reimplements something the codebase already has under a near-identical name.
//
// Why near-name and not exact-name: Swift already refuses to compile two
// top-level types with the same name in one module, so an EXACT collision is
// caught for free by the build-green gate. The dangerous case is DIVERGENT
// names for the same concept (CognitiveMapView vs CognitionMapView), which
// compiles fine and quietly forks the codebase. This scanner flags those.
//
// Pure + nonisolated so it runs offline (no model, no network) and is unit
// testable without git. The git-backed harvest is a thin wrapper around the
// pure core.
enum SymbolCollisionScanner {

    // A suspected duplicate: a type the staged diff introduces whose name is
    // suspiciously close to a type that already exists elsewhere in the tree.
    struct DupFinding: Codable, Equatable, Identifiable {
        var id: String { newSymbol + "~" + existingSymbol }
        let kind: String          // "struct" | "class" | "enum" | "protocol" | "actor"
        let newSymbol: String     // the name the diff adds
        let existingSymbol: String// the pre-existing name it collides with
        let existingFile: String  // where the existing one lives
        let distance: Int         // edit distance between normalized roots (0 = same concept)
        var note: String { "New \(kind) \"\(newSymbol)\" looks like existing \"\(existingSymbol)\" (\(existingFile)). Possible duplicate or divergent reimplementation." }
    }

    private static let declKinds = ["struct", "class", "enum", "protocol", "actor"]
    // Role suffixes stripped before comparison so "CognitionMapView" and
    // "CognitiveMapView" compare on their concept roots, not their shared role.
    private static let roleSuffixes = ["View", "Engine", "Manager", "Store", "Model", "Service",
                                       "Gate", "Client", "Controller", "Coordinator", "Provider",
                                       "Section", "Card", "Row", "Cell", "Sheet", "Panel"]

    // MARK: Pure core (unit testable, no IO)

    // Extract declared type names from added (+) lines of a unified diff.
    nonisolated static func declaredTypes(inDiff diff: String) -> [(kind: String, name: String)] {
        var out: [(String, String)] = []
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { continue }
            let body = String(line.dropFirst())
            if let hit = matchDecl(body) { out.append(hit) }
        }
        // de-dup, preserve order
        var seen = Set<String>()
        return out.filter { seen.insert($0.1).inserted }
    }

    // Match a single source line for a top-level type declaration, returning
    // (kind, Name). Tolerates leading modifiers (public/final/@MainActor/etc.).
    nonisolated static func matchDecl(_ line: String) -> (kind: String, name: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for kind in declKinds {
            // " <kind> Name" with a word boundary before kind
            guard let r = trimmed.range(of: "\(kind) ") else { continue }
            // ensure the token before <kind> is a modifier or start, not part of another word
            let before = trimmed[trimmed.startIndex..<r.lowerBound]
            if let last = before.last, !(last == " " || before.isEmpty) { continue }
            if !before.isEmpty {
                // everything before must be modifiers (letters/@/spaces), not e.g. "myenum"
                let allowed = before.allSatisfy { $0.isLetter || $0 == "@" || $0 == " " || $0 == "(" || $0 == ")" }
                if !allowed { continue }
            }
            let after = trimmed[r.upperBound...]
            var name = ""
            for ch in after {
                if ch.isLetter || ch.isNumber || ch == "_" { name.append(ch) } else { break }
            }
            guard let first = name.first, first.isUppercase else { continue }
            return (kind, name)
        }
        return nil
    }

    // Concept root: lowercase, drop one trailing role suffix. So CognitionMapView
    // and CognitiveMapView both reduce toward "cognitionmap"/"cognitivemap".
    nonisolated static func conceptRoot(_ name: String) -> String {
        var n = name
        for suf in roleSuffixes where n.count > suf.count && n.hasSuffix(suf) {
            n = String(n.dropLast(suf.count)); break
        }
        return n.lowercased()
    }

    // Levenshtein edit distance, capped reasoning kept simple (names are short).
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i-1] == t[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    // The pure scan: given the new declared types and the existing universe of
    // (name, file) declarations, return near-name collisions. A finding fires
    // when the concept roots are close (edit distance <= maxDistance) but the
    // names are NOT identical (identical top-level types are a compile error the
    // build gate already catches, so reporting them here is noise).
    nonisolated static func scan(newTypes: [(kind: String, name: String)],
                                 existing: [(name: String, file: String)],
                                 maxDistance: Int = 2) -> [DupFinding] {
        let newNameSet = Set(newTypes.map { $0.name })
        var findings: [DupFinding] = []
        for nt in newTypes {
            let newRoot = conceptRoot(nt.name)
            guard newRoot.count >= 4 else { continue } // skip tiny roots (Tab, Row) to avoid noise
            for ex in existing {
                if ex.name == nt.name { continue }          // exact dup: compiler's job
                if newNameSet.contains(ex.name) { continue } // the existing one is itself newly added
                let exRoot = conceptRoot(ex.name)
                guard exRoot.count >= 4 else { continue }
                let d = editDistance(newRoot, exRoot)
                if d <= maxDistance {
                    findings.append(DupFinding(kind: nt.kind, newSymbol: nt.name,
                                               existingSymbol: ex.name, existingFile: ex.file, distance: d))
                }
            }
        }
        // strongest (smallest distance) first, de-dup pairs
        var seen = Set<String>()
        return findings.sorted { $0.distance < $1.distance }.filter { seen.insert($0.id).inserted }
    }

    // MARK: git-backed harvest (the IO wrapper around the pure core)

    // Harvest every top-level type declaration in the package source tree as
    // (name, relativeFile). Uses git grep for speed; soft-fails to [] so the
    // gate degrades to "no structural dup signal" rather than blocking.
    nonisolated static func harvestExisting(repoDir: String) -> [(name: String, file: String)] {
        let pattern = "^[[:space:]]*(public |private |internal |fileprivate |open |final |@MainActor |@objc |indirect )*(struct|class|enum|protocol|actor) [A-Z]"
        let out = runGit(["-C", repoDir, "grep", "-nE", pattern, "--", "Grux-Mac/Sources/*.swift", "Grux-Mac/Sources/**/*.swift"])
        var result: [(String, String)] = []
        for line in out.split(separator: "\n") {
            // format: <file>:<lineno>:<code>
            let parts = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            if let hit = matchDecl(parts[2]) { result.append((hit.name, parts[0])) }
        }
        return result
    }

    // Convenience: scan a diff against the live tree in one call.
    nonisolated static func scanDiff(_ diff: String, repoDir: String, maxDistance: Int = 2) -> [DupFinding] {
        let newTypes = declaredTypes(inDiff: diff)
        guard !newTypes.isEmpty else { return [] }
        let existing = harvestExisting(repoDir: repoDir)
        return scan(newTypes: newTypes, existing: existing, maxDistance: maxDistance)
    }

    nonisolated private static func runGit(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
