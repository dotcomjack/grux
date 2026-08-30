import Foundation

// Export / import of Grux's full durable memory as one schema-versioned
// JSON file: semantic entries, profile slang, profile facts, and learned
// skills. Lets the user back memory up, move it to another Mac, or hand-edit
// it offline. Files land under ~/Documents/Grux/exports/.
//
// Vectors are deliberately NOT exported. They are derived data: import
// re-embeds each entry through SemanticMemory.store, which keeps export
// files small and portable across NLEmbedding model revisions.
//
// Import is a MERGE, never a wipe: semantic entries dedupe on (kind, text),
// slang upserts by term, facts dedupe on text, skills upsert by name. The
// original timestamp of an imported semantic entry is preserved inside
// metadata["imported_original_timestamp"] because SemanticMemory.store
// stamps entries with the time of import.

struct GruxMemoryExport: Codable {
    static let currentSchemaVersion = 1

    struct PortableSemanticEntry: Codable {
        let kind: String
        let text: String
        let timestamp: Date
        let metadata: [String: String]
    }

    struct PortableSlang: Codable {
        let term: String
        let meaning: String
    }

    struct PortableSkill: Codable {
        let name: String
        let trigger: String
        let procedure: String
        let usageCount: Int
    }

    var schemaVersion: Int
    var exportedAt: Date
    var semanticEntries: [PortableSemanticEntry]
    var slang: [PortableSlang]
    var facts: [String]
    var skills: [PortableSkill]
}

enum MemoryPortabilityError: Error, LocalizedError {
    case fileNotFound(String)
    case unreadable(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "No file at \(path)"
        case .unreadable(let detail): return "Could not decode memory export: \(detail)"
        case .unsupportedSchema(let v): return "Unsupported schema version \(v) (this build reads <= \(GruxMemoryExport.currentSchemaVersion))"
        }
    }
}

enum MemoryPortability {

    struct ImportSummary {
        var semanticImported = 0
        var semanticSkipped = 0
        var slangUpserted = 0
        var factsAdded = 0
        var skillsUpserted = 0

        var description: String {
            "memories +\(semanticImported) (skipped \(semanticSkipped) dupes), slang +\(slangUpserted), facts +\(factsAdded), skills +\(skillsUpserted)"
        }
    }

    /// The same folder `Persistence.exportsDir` names, and now literally the same code
    /// rather than a second copy of the path. Two owners of one directory is how they end up
    /// disagreeing, and this one also carried the createDirectory that put `~/Documents/Grux`
    /// on a Mac where nobody had exported anything.
    static var exportsDir: URL { Persistence.exportsDir }

    // MARK: - Export

    @MainActor
    static func exportAll(to directory: URL = exportsDir) throws -> URL {
        // CREATED HERE, at the point somebody actually asked for an export.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SkillStore.shared.flush()

        let payload = GruxMemoryExport(
            schemaVersion: GruxMemoryExport.currentSchemaVersion,
            exportedAt: Date(),
            semanticEntries: SemanticMemory.shared.entries.map {
                GruxMemoryExport.PortableSemanticEntry(
                    kind: $0.kind.rawValue,
                    text: $0.text,
                    timestamp: $0.timestamp,
                    metadata: $0.metadata
                )
            },
            slang: ProfileMemoryStore.shared.slang.map {
                GruxMemoryExport.PortableSlang(term: $0.term, meaning: $0.meaning)
            },
            facts: ProfileMemoryStore.shared.facts.map { $0.text },
            skills: SkillStore.shared.skills.map {
                GruxMemoryExport.PortableSkill(name: $0.name, trigger: $0.trigger, procedure: $0.procedure, usageCount: $0.usageCount)
            }
        )

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appendingPathComponent("grux-memory-\(df.string(from: Date())).json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(payload)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Import

    @MainActor
    static func importAll(from url: URL) throws -> ImportSummary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MemoryPortabilityError.fileNotFound(url.path)
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw MemoryPortabilityError.unreadable(error.localizedDescription) }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let payload: GruxMemoryExport
        do { payload = try dec.decode(GruxMemoryExport.self, from: data) }
        catch { throw MemoryPortabilityError.unreadable(String(describing: error)) }

        guard payload.schemaVersion <= GruxMemoryExport.currentSchemaVersion else {
            throw MemoryPortabilityError.unsupportedSchema(payload.schemaVersion)
        }

        var summary = ImportSummary()
        let mem = SemanticMemory.shared

        // Dedupe key set for existing semantic entries: kind + text.
        var existing = Set(mem.entries.map { "\($0.kind.rawValue)\u{1F}\($0.text)" })

        let isoStamp = ISO8601DateFormatter()
        // Suppress the per-write companion mirror during the bulk import so we do not
        // fire one index POST per imported entry; backfill the whole batch in
        // chunked POSTs once at the end instead.
        let priorSuppress = mem.suppressMiniMirror
        mem.suppressMiniMirror = true
        for e in payload.semanticEntries {
            guard let kind = SemanticMemoryKind(rawValue: e.kind) else {
                summary.semanticSkipped += 1
                continue
            }
            let key = "\(e.kind)\u{1F}\(e.text)"
            guard !existing.contains(key) else {
                summary.semanticSkipped += 1
                continue
            }
            var meta = e.metadata
            meta["imported_original_timestamp"] = isoStamp.string(from: e.timestamp)
            mem.store(kind: kind, text: e.text, metadata: meta)
            existing.insert(key)
            summary.semanticImported += 1
        }
        mem.suppressMiniMirror = priorSuppress
        // backfillMiniMirror is now async (returns sent/failed). importAll is a
        // synchronous @MainActor throwing function, so wrap the call in a Task to
        // await it; the bulk import does not depend on the backfill outcome here,
        // so this stays fire-and-forget (best-effort, same as before).
        if summary.semanticImported > 0 {
            Task { _ = await mem.backfillMiniMirror() }
        }

        for s in payload.slang {
            ProfileMemoryStore.shared.addSlang(term: s.term, meaning: s.meaning)
            summary.slangUpserted += 1
        }

        let knownFacts = Set(ProfileMemoryStore.shared.facts.map { $0.text.lowercased() })
        for f in payload.facts {
            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !knownFacts.contains(t.lowercased()) else { continue }
            ProfileMemoryStore.shared.addFact(t)
            summary.factsAdded += 1
        }

        for sk in payload.skills {
            SkillStore.shared.upsert(name: sk.name, trigger: sk.trigger, procedure: sk.procedure)
            summary.skillsUpserted += 1
        }

        return summary
    }

    // MARK: - Claude tools

    nonisolated static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "export_memory",
                description: "Export Grux's ENTIRE durable memory (semantic memories, slang glossary, long-term facts, learned skills) to a schema-versioned JSON file under ~/Documents/Grux/exports/. Use when the user says 'back up your memory', 'export your memory', 'dump everything you know to a file'. Returns the file path.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            ClaudeTool(
                name: "import_memory",
                description: "Import a Grux memory export JSON file and MERGE it into live memory (deduped, nothing is wiped). Use when the user says 'import this memory file', 'restore your memory from X', 'load the backup'. Pass the absolute path to the .json file.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path to a grux-memory-*.json export file. '~' is expanded."]
                    ],
                    "required": ["path"]
                ]
            )
        ]
    }

    // Tool dispatch. Returns nil for unrelated names so ChatService can
    // fall through to its own default case.
    @MainActor
    static func executeTool(name: String, input: [String: Any]) -> String? {
        switch name {
        case "export_memory":
            do {
                let url = try exportAll()
                let counts = "memories \(SemanticMemory.shared.entries.count), slang \(ProfileMemoryStore.shared.slang.count), facts \(ProfileMemoryStore.shared.facts.count), skills \(SkillStore.shared.skills.count)"
                return "ok: exported \(counts) to \(url.path)"
            } catch {
                return "error: export failed: \(error.localizedDescription)"
            }

        case "import_memory":
            let raw = (input["path"] as? String) ?? ""
            guard !raw.isEmpty else { return "error: import_memory needs a path" }
            let path = (raw as NSString).expandingTildeInPath
            do {
                let summary = try importAll(from: URL(fileURLWithPath: path))
                return "ok: imported \(summary.description)"
            } catch {
                return "error: import failed: \(error.localizedDescription)"
            }

        default:
            return nil
        }
    }
}
