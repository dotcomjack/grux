import Foundation

// MARK: - Document models
//
// Data layer for the document library (roadmap items 11 + 12). Mirrors the
// ChatThread / MeetingRecord convention: lightweight Codable structs whose
// heavy content lives in separate files on disk, with a compact index.json
// for fast listings. Content files + version snapshots are owned by
// DocumentStore.

// What kind of file a document is. Drives which editor surface opens it,
// which extractor produces the text preview, and the on-disk file extension.
enum DocumentKind: String, Codable, CaseIterable {
    case markdown
    case plainText
    case rtf
    case pdf
    case word
    case other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown", "mdown": self = .markdown
        case "txt", "text", "log": self = .plainText
        case "rtf", "rtfd": self = .rtf
        case "pdf": self = .pdf
        case "docx", "doc": self = .word
        default: self = .other
        }
    }

    // Extension used when DocumentStore writes the content file.
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .rtf: return "rtf"
        case .pdf: return "pdf"
        case .word: return "docx"
        case .other: return "dat"
        }
    }

    // Kinds whose content is UTF-8 text Grux can edit in place. Binary kinds
    // (pdf / word / rtf imports) are read-only in the editor; their text is
    // surfaced via TextExtract for search + AI context.
    var isEditable: Bool {
        switch self {
        case .markdown, .plainText: return true
        case .rtf, .pdf, .word, .other: return false
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain text"
        case .rtf: return "Rich text"
        case .pdf: return "PDF"
        case .word: return "Word"
        case .other: return "File"
        }
    }

    var iconName: String {
        switch self {
        case .markdown: return "doc.richtext"
        case .plainText: return "doc.plaintext"
        case .rtf: return "doc.text"
        case .pdf: return "doc.viewfinder"
        case .word: return "doc.fill"
        case .other: return "doc"
        }
    }
}

// One library document. Content is NOT embedded, it lives at
// documents/<id>/content.<ext> and is read/written by DocumentStore so the
// index stays tiny even with hundreds of large files.
struct GruxDocument: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var kind: DocumentKind
    var tags: [String]
    var starred: Bool
    var createdAt: Date
    var updatedAt: Date
    // First ~200 chars of extracted text, shown on library cards.
    var preview: String?
    // Original filename for imported files (nil for docs created in Grux).
    var sourceFileName: String?

    init(
        id: UUID = UUID(),
        title: String,
        kind: DocumentKind = .markdown,
        tags: [String] = [],
        starred: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        preview: String? = nil,
        sourceFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tags = tags
        self.starred = starred
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.sourceFileName = sourceFileName
    }
}

// One saved version snapshot. The snapshot's content file lives at
// documents/<docId>/versions/<versionId>.<ext>. DocumentStore keeps the most
// recent `DocumentStore.maxVersions` snapshots per document (ShellSnapshotStore
// keeps a commit per write; we keep a file per save, capped at 20).
struct DocumentVersion: Codable, Identifiable, Equatable {
    let id: UUID
    let savedAt: Date
    var label: String
    var byteCount: Int

    init(id: UUID = UUID(), savedAt: Date = Date(), label: String, byteCount: Int) {
        self.id = id
        self.savedAt = savedAt
        self.label = label
        self.byteCount = byteCount
    }
}

// AcroForm field descriptor returned by PDFSupport.listFormFields. `type` is
// a plain string ("text" / "checkbox" / "other") so it round-trips through
// tool JSON without an enum dance.
struct PDFFormFieldInfo: Codable, Equatable {
    let name: String
    let type: String
    let value: String
    let pageIndex: Int
}
