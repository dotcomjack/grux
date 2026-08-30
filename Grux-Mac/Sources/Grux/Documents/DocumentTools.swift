import Foundation

// Claude-tool adapter for the document library. Registered by
// ChatService.allTools() and dispatched by ChatService.dispatchTool() (see
// integration snippet in this module's PR notes). Thin switch that calls into
// DocumentStore / PDFSupport on the main actor, same shape as FolderTool.
enum DocumentTools {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "documents_list",
                description: "List the user's document library (ids, titles, kinds, tags, starred, updated dates, preview lines). Use whenever they mention 'my documents', 'that doc about X', 'what files do I have', or before creating a doc to avoid duplicates. Supports filtering by tag, starred, or a search query.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional search over titles, previews, and tags."],
                        "tag": ["type": "string", "description": "Optional exact tag filter."],
                        "starred": ["type": "boolean", "description": "Only starred documents when true."],
                        "limit": ["type": "integer", "description": "Max rows. Default 20, max 50."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "documents_read",
                description: "Read a document's text content by id or title. Editable docs (markdown / plain text) return raw text; PDFs / Word / RTF return extracted text. Long documents are truncated to ~12000 chars with a marker. Use before edit_document so you patch against the real current content.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "document": ["type": "string", "description": "Document id OR exact title OR title substring."]
                    ],
                    "required": ["document"]
                ]
            ),
            ClaudeTool(
                name: "documents_create",
                description: "Create a new document in the user's library. Default kind is markdown. Use when they say 'draft a doc', 'write that up and save it', 'make a note document about X'. Returns the new document's id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Document title, <80 chars."],
                        "content": ["type": "string", "description": "Initial body text (markdown welcome)."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tags like 'work', 'legal', 'ideas'."],
                        "kind": ["type": "string", "enum": ["markdown", "plainText"], "description": "Default markdown."]
                    ],
                    "required": ["title"]
                ]
            ),
            ClaudeTool(
                name: "edit_document",
                description: "Edit an editable document (markdown / plain text). Two modes: pass `find` + `replace` to patch one exact occurrence (preferred for surgical edits; errors if `find` matches more than once, so include enough surrounding context to make it unique), or pass `content` alone to replace the whole body. Every save snapshots the prior version (last 20 kept), so edits are reversible from the editor's history drawer. Read the doc first with documents_read.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "document": ["type": "string", "description": "Document id OR exact title OR title substring."],
                        "find": ["type": "string", "description": "Exact text to find (patch mode). Must occur in the document."],
                        "replace": ["type": "string", "description": "Replacement text (patch mode). Pairs with `find`."],
                        "content": ["type": "string", "description": "Full new body (replace mode). Ignored when `find` is set."]
                    ],
                    "required": ["document"]
                ]
            ),
            ClaudeTool(
                name: "pdf_form_fill",
                description: "Inspect or fill a PDF form (AcroForm). With no `values`, lists the form's fields (name, type, current value, page). With `values` (field name to value map), writes a FILLED COPY next to the original (or at output_path), the source PDF is never mutated. Checkbox truthy values: 'true' / 'yes' / 'on' / '1'. The pdf can be a library document (id / title) or an absolute file path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "pdf": ["type": "string", "description": "Library document id / title, OR absolute path to a .pdf file."],
                        "values": ["type": "object", "description": "Map of field name to value. Omit to just list the fields."],
                        "output_path": ["type": "string", "description": "Optional absolute path for the filled copy. Default: '<original>-filled.pdf' next to the source."]
                    ],
                    "required": ["pdf"]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = [
        "documents_list", "documents_read", "documents_create", "edit_document", "pdf_form_fill"
    ]

    // Truncation cap for documents_read, generous enough for real docs,
    // small enough to not blow the context window.
    private static let readCap = 12_000

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "documents_list":
            let query = input["query"] as? String
            let tag = input["tag"] as? String
            let starred = (input["starred"] as? Bool) ?? false
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 20))
            return await MainActor.run { () -> String in
                let rows = DocumentStore.shared.list(tag: tag, starredOnly: starred, query: query)
                if rows.isEmpty { return "(no documents matched)" }
                return rows.prefix(limit).map { formatRow($0) }.joined(separator: "\n")
            }

        case "documents_read":
            let hint = (input["document"] as? String) ?? ""
            return await MainActor.run { () -> String in
                guard let doc = DocumentStore.shared.resolve(hint) else {
                    return "error: no document matched '\(hint)'"
                }
                guard let text = DocumentStore.shared.content(id: doc.id) else {
                    return "error: couldn't read content of '\(doc.title)' (missing or non-text file)"
                }
                let header = "title: \(doc.title)\nid: \(doc.id.uuidString)\nkind: \(doc.kind.displayName)\n---\n"
                if text.count > readCap {
                    return header + String(text.prefix(readCap)) + "\n[... truncated, \(text.count) chars total]"
                }
                return header + text
            }

        case "documents_create":
            let title = (input["title"] as? String) ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: empty title"
            }
            let content = (input["content"] as? String) ?? ""
            let tags = (input["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
            let kindRaw = (input["kind"] as? String) ?? "markdown"
            let kind: DocumentKind = kindRaw == "plainText" ? .plainText : .markdown
            return await MainActor.run { () -> String in
                // POST-vet model-authored content before persisting. This arrives
                // as tool input during the chat hop loop, not as visible reply
                // text, so the chat reply vet does not cover it: a model could
                // write '$18' into a saved doc while the reply stays clean.
                let createVerdict = GroundingGate.vet(draft: content, brief: title)
                guard createVerdict.surfaceable else {
                    return "error: not creating '\(title)'. \(createVerdict.refusalLine)"
                }
                let doc = DocumentStore.shared.create(title: title, content: content, kind: kind, tags: tags)
                return "ok: created '\(doc.title)' id=\(doc.id.uuidString)"
            }

        case "edit_document":
            let hint = (input["document"] as? String) ?? ""
            let find = input["find"] as? String
            let replace = input["replace"] as? String
            let fullContent = input["content"] as? String
            return await MainActor.run { () -> String in
                guard let doc = DocumentStore.shared.resolve(hint) else {
                    return "error: no document matched '\(hint)'"
                }
                guard doc.kind.isEditable else {
                    return "error: '\(doc.title)' is \(doc.kind.displayName) and can't be edited in place (only markdown / plain text can)"
                }
                if let find, !find.isEmpty {
                    guard let current = DocumentStore.shared.content(id: doc.id) else {
                        return "error: couldn't read current content"
                    }
                    guard let range = current.range(of: find) else {
                        return "error: `find` text not present in '\(doc.title)'. Read it with documents_read and retry with exact text."
                    }
                    // The tool contract is "patch one exact occurrence". A
                    // repeated `find` (a short heading, a price, a date)
                    // must error rather than silently rewrite unrelated
                    // parts of the document.
                    let occurrences = current.components(separatedBy: find).count - 1
                    guard occurrences == 1 else {
                        return "error: `find` occurs \(occurrences) times in '\(doc.title)'. Include more surrounding context so it matches exactly once."
                    }
                    // A surgical patch can still introduce a product claim (a
                    // price-line edit), so vet the replacement against the catalog.
                    let patchVerdict = GroundingGate.vet(draft: replace ?? "", brief: doc.title)
                    guard patchVerdict.surfaceable else {
                        return "error: not patching '\(doc.title)'. \(patchVerdict.refusalLine)"
                    }
                    let patched = current.replacingCharacters(in: range, with: replace ?? "")
                    _ = DocumentStore.shared.update(id: doc.id, content: patched, versionLabel: "ai patch")
                    return "ok: patched '\(doc.title)' (version snapshot saved)"
                }
                guard let fullContent else {
                    return "error: pass either `find`+`replace` or `content`"
                }
                // POST-vet the model-authored replacement body before persisting.
                let editVerdict = GroundingGate.vet(draft: fullContent, brief: doc.title)
                guard editVerdict.surfaceable else {
                    return "error: not replacing '\(doc.title)'. \(editVerdict.refusalLine)"
                }
                _ = DocumentStore.shared.update(id: doc.id, content: fullContent, versionLabel: "ai rewrite")
                return "ok: replaced content of '\(doc.title)' (version snapshot saved)"
            }

        case "pdf_form_fill":
            let hint = (input["pdf"] as? String) ?? ""
            let rawValues = input["values"] as? [String: Any]
            let outputPath = input["output_path"] as? String
            // Resolve to a concrete file URL: absolute path first, library doc second.
            let pdfURL: URL? = await MainActor.run { () -> URL? in
                if hint.hasPrefix("/"), hint.lowercased().hasSuffix(".pdf"),
                   FileManager.default.fileExists(atPath: hint) {
                    return URL(fileURLWithPath: hint)
                }
                guard let doc = DocumentStore.shared.resolve(hint), doc.kind == .pdf else { return nil }
                return DocumentStore.shared.contentURL(id: doc.id)
            }
            guard let url = pdfURL else {
                return "error: no PDF matched '\(hint)' (pass a library doc id/title or an absolute .pdf path)"
            }
            guard let values = rawValues, !values.isEmpty else {
                let fields = PDFSupport.listFormFields(url: url)
                if fields.isEmpty { return "(no form fields found in this PDF)" }
                return fields.map { f in
                    "- \(f.name) · \(f.type) · page \(f.pageIndex + 1)\(f.value.isEmpty ? "" : " · current: \(f.value)")"
                }.joined(separator: "\n")
            }
            let stringValues = values.reduce(into: [String: String]()) { acc, pair in
                acc[pair.key] = "\(pair.value)"
            }
            let outURL: URL = {
                if let outputPath, outputPath.hasPrefix("/") {
                    return URL(fileURLWithPath: outputPath)
                }
                let base = url.deletingPathExtension().lastPathComponent
                return url.deletingLastPathComponent().appendingPathComponent(base + "-filled.pdf")
            }()
            do {
                let filled = try PDFSupport.fillForm(at: url, values: stringValues, outputURL: outURL)
                if filled.isEmpty {
                    return "warning: no matching field names, run pdf_form_fill without values to list them"
                }
                return "ok: filled \(filled.count) field\(filled.count == 1 ? "" : "s") (\(filled.joined(separator: ", "))) → \(outURL.path)"
            } catch {
                return "error: \(error.localizedDescription)"
            }

        default:
            return "error: unknown documents tool '\(name)'"
        }
    }

    // MARK: - Formatting

    @MainActor
    private static func formatRow(_ doc: GruxDocument) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d h:mm a"
        df.timeZone = .current
        var flags: [String] = [doc.kind.displayName]
        if doc.starred { flags.append("starred") }
        if !doc.tags.isEmpty { flags.append("tags: " + doc.tags.joined(separator: ", ")) }
        let tail = doc.preview.map { "\n  → \($0.prefix(110))" } ?? ""
        return "- id=\(doc.id.uuidString) · \(doc.title) · \(df.string(from: doc.updatedAt)) · \(flags.joined(separator: " · "))\(tail)"
    }
}
