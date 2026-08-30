import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - DocumentLibraryView
//
// The Documents tab: card grid with previews, tag filter, search, star
// toggle, NSOpenPanel import, and new-document creation. Clicking a card
// opens DocumentEditorView (markdown / plain text) or the PDF detail pane
// in a sheet. Tight scale throughout, small paddings, 11-13pt type.
struct DocumentLibraryView: View {
    @ObservedObject private var store = DocumentStore.shared

    @State private var searchText = ""
    @State private var activeTag: String? = nil
    @State private var starredOnly = false
    @State private var openDocument: OpenDocumentSelection? = nil

    private var rows: [GruxDocument] {
        store.list(
            tag: activeTag,
            starredOnly: starredOnly,
            query: searchText.isEmpty ? nil : searchText
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if rows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(GruxTheme.base)
        .sheet(item: $openDocument) { selection in
            DocumentEditorView(documentId: selection.id)
                .frame(minWidth: 760, minHeight: 520)
        }
    }

    // MARK: - Header

    private var header: some View {
        GruxToolbar("Documents") {
            GruxSearchField(placeholder: "Search documents", text: $searchText, width: 220)

            tagFilterMenu

            Button {
                starredOnly.toggle()
            } label: {
                Image(systemName: starredOnly ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(starredOnly ? GruxTheme.warnAmber : GruxTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(starredOnly ? "Showing starred only" : "Show starred only")

            Spacer()

            GruxToolbarButton(title: "Import", systemImage: "square.and.arrow.down",
                              action: importDocuments)
            GruxToolbarButton(title: "New", systemImage: "plus",
                              prominent: true, action: createDocument)
        }
    }

    private var tagFilterMenu: some View {
        Menu {
            Button("All tags") { activeTag = nil }
            if !store.allTags.isEmpty {
                Divider()
                ForEach(store.allTags, id: \.self) { tag in
                    Button {
                        activeTag = tag
                    } label: {
                        if activeTag == tag {
                            Label(tag, systemImage: "checkmark")
                        } else {
                            Text(tag)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 10, weight: .semibold))
                Text(activeTag ?? "Tags")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(activeTag == nil ? GruxTheme.textSecondary : GruxTheme.accentPrimaryLight)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: GruxSpacing.m)],
                spacing: GruxSpacing.m
            ) {
                ForEach(rows) { doc in
                    DocumentCard(document: doc) {
                        openDocument = OpenDocumentSelection(id: doc.id)
                    }
                }
            }
            .padding(GruxSpacing.l)
        }
    }

    /// The grid's copy, static so it can be asserted on.
    ///
    /// Two different states share this pane and they must not share a sentence:
    /// nothing has been added yet, and a filter is hiding everything that has.
    /// The second one names the filters, because a reader looking at an empty
    /// grid they filled themselves needs to be told what is hiding it.
    static func emptyCopy(unfiltered: Bool) -> String {
        unfiltered
            ? "No documents yet. Create one, or import files you already have."
            : "Nothing matched the current filters. Clear the search, tag, or star filter above."
    }

    private var emptyState: some View {
        let unfiltered = searchText.isEmpty && activeTag == nil && !starredOnly
        return GruxEmptyState(
            icon: "tray",
            line: Self.emptyCopy(unfiltered: unfiltered),
            ctaTitle: unfiltered ? "New document" : nil,
            ctaAction: unfiltered ? createDocument : nil,
            voiceHint: unfiltered ? "Grux, draft a document about..." : nil
        )
    }

    // MARK: - Actions

    private func createDocument() {
        let doc = DocumentStore.shared.create(title: "Untitled document", content: "")
        openDocument = OpenDocumentSelection(id: doc.id)
    }

    private func importDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Import documents"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .pdf, .plainText, .rtf,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "docx") ?? .data
        ]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = DocumentStore.shared.importFile(from: url)
        }
    }
}

// Sheet(item:) needs an Identifiable payload. A tiny wrapper avoids a
// retroactive `UUID: Identifiable` conformance that could collide with
// other modules.
private struct OpenDocumentSelection: Identifiable {
    let id: UUID
}

// MARK: - DocumentCard

private struct DocumentCard: View {
    let document: GruxDocument
    let open: () -> Void

    @State private var thumbnail: NSImage? = nil
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: GruxSpacing.s) {
                previewArea
                titleRow
                if !document.tags.isEmpty {
                    tagRow
                }
                Text(Self.dateFormatter.string(from: document.updatedAt))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(GruxSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                    .stroke(hovering ? GruxTheme.accentPrimary.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(document.starred ? "Unstar" : "Star") {
                _ = DocumentStore.shared.toggleStar(id: document.id)
            }
            DestructiveMenuButton(
                "Delete",
                question: "Delete this document?",
                detail: "The document and its version history are removed. This cannot be undone.",
                confirmLabel: "Delete document"
            ) {
                DocumentStore.shared.delete(id: document.id)
            }
        }
        .task(id: document.id) {
            loadThumbnailIfPDF()
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.30))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(GruxSpacing.s - 2)
            } else if let preview = document.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(6)
                    .padding(GruxSpacing.m - 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Image(systemName: document.kind.iconName)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .frame(height: 110)
        .clipped()
    }

    private var titleRow: some View {
        HStack(spacing: GruxSpacing.s - 2) {
            Image(systemName: document.kind.iconName)
                .font(.system(size: 11))
                .foregroundStyle(GruxTheme.accentPrimaryLight)
            Text(document.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                _ = DocumentStore.shared.toggleStar(id: document.id)
            } label: {
                Image(systemName: document.starred ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(document.starred ? GruxTheme.warnAmber : GruxTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var tagRow: some View {
        HStack(spacing: GruxSpacing.xs) {
            ForEach(document.tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GruxTheme.accentPrimaryLight)
                    .padding(.horizontal, GruxSpacing.s - 1).padding(.vertical, GruxSpacing.xs - 2)
                    .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.14)))
            }
            if document.tags.count > 3 {
                Text("+\(document.tags.count - 3)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
    }

    private func loadThumbnailIfPDF() {
        guard document.kind == .pdf, thumbnail == nil else { return }
        guard let url = DocumentStore.shared.contentURL(id: document.id) else { return }
        // Thumbnail render is quick (single page) but keep it off the next
        // run-loop tick so grid scrolling never hitches on first paint.
        DispatchQueue.global(qos: .userInitiated).async {
            let image = PDFSupport.thumbnail(url: url, page: 0, maxDimension: 280)
            DispatchQueue.main.async {
                self.thumbnail = image
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm a"
        // Whatever zone this Mac is set to. A document's timestamp should read
        // the way the clock in the menu bar reads.
        df.timeZone = .current
        return df
    }()
}
