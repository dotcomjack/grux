import Foundation

// Streaming extractor for the Design Studio generation loop. The model is
// instructed to wrap each file it writes in a delimiter pair:
//
//     <grux-artifact path="site/index.html">
//     ...file bytes...
//     </grux-artifact>
//
// and to speak normally (progress notes, explanations) outside those blocks.
// This class turns the model's raw text deltas into a clean event stream so the
// engine can write files mid-generation and keep the chat transcript readable.
//
// It is PURE: no disk, no engine, no UI. The engine wires the file writes; this
// only decides "this text is file bytes for path X" vs "this text is chat prose".
//
// Chunk-boundary safe. A delta can split an opening tag ("<grux-art" | "ifact
// ...>"), a path attribute, or a closing tag ("</grux-" | "artifact>"); the
// residual-buffer + held-back-suffix approach (mirrors
// GruxAgentCore.StreamJSONParser.parseChunk) never emits a partial tag as
// content and never writes to a rejected path.
//
// Path rules: project-relative, must live under site/, no traversal, no
// absolute paths. A block whose path fails validation is swallowed whole (its
// content is dropped, no file events fire) so a traversal path can never reach
// the store.

enum DesignArtifactEvent: Equatable {
    case fileStarted(path: String)
    case fileChunk(path: String, text: String)
    case fileCompleted(path: String, fullText: String)
    case passthroughText(String)
}

final class DesignArtifactParser {

    // The delimiter vocabulary. Kept as constants so the boundary math reads
    // against named values, not magic strings.
    static let openPrefix = "<grux-artifact"
    static let closeTag = "</grux-artifact>"

    private enum State {
        case idle          // outside any artifact, text is chat prose
        case inside        // inside a valid artifact, text is file bytes
        case skipping      // inside a rejected-path artifact, swallow to close
    }

    private var buffer = ""
    private var state: State = .idle
    private var currentPath = ""
    private var currentText = ""

    // Feed one text delta. Returns every event the buffer can now fully commit;
    // anything that might still be a partial tag stays buffered for the next
    // call.
    func parse(_ chunk: String) -> [DesignArtifactEvent] {
        buffer += chunk
        var events: [DesignArtifactEvent] = []
        drain(&events)
        return coalesce(events)
    }

    // Call once when the model stream ends. Flushes residual prose, and salvages
    // an unterminated artifact so a truncated-but-usable file still lands (a
    // dangling partial close tag is dropped, not written into the file).
    func finish() -> [DesignArtifactEvent] {
        var events: [DesignArtifactEvent] = []
        drain(&events)
        switch state {
        case .idle:
            if !buffer.isEmpty {
                events.append(.passthroughText(buffer))
                buffer = ""
            }
        case .inside:
            if !buffer.isEmpty && !Self.closeTag.hasPrefix(buffer) {
                currentText += buffer
                events.append(.fileChunk(path: currentPath, text: buffer))
            }
            buffer = ""
            events.append(.fileCompleted(path: currentPath, fullText: currentText))
            resetToIdle()
        case .skipping:
            buffer = ""
            resetToIdle()
        }
        return coalesce(events)
    }

    // MARK: - Core loop

    private func drain(_ events: inout [DesignArtifactEvent]) {
        var progress = true
        while progress {
            switch state {
            case .idle: progress = drainIdle(&events)
            case .inside: progress = drainInside(&events)
            case .skipping: progress = drainSkipping(&events)
            }
        }
    }

    // Returns true when it made progress and the loop should run again.
    private func drainIdle(_ events: inout [DesignArtifactEvent]) -> Bool {
        guard let lt = buffer.firstIndex(of: "<") else {
            if !buffer.isEmpty {
                events.append(.passthroughText(buffer))
                buffer = ""
            }
            return false
        }
        // Commit prose before the "<".
        if lt > buffer.startIndex {
            events.append(.passthroughText(String(buffer[..<lt])))
            buffer = String(buffer[lt...])
        }
        // buffer now starts with "<".
        let prefix = Self.openPrefix
        if buffer.count < prefix.count {
            // Might still grow into an opening tag; wait unless it already
            // diverges (a literal "<" in prose).
            return prefix.hasPrefix(buffer) ? false : emitLiteralLessThan(&events)
        }
        guard buffer.hasPrefix(prefix) else {
            return emitLiteralLessThan(&events)
        }
        // Need at least one character after the prefix to judge the tag
        // boundary; when the buffer is exactly "<grux-artifact" wait for more.
        guard buffer.count > prefix.count else { return false }
        // Confirm a tag boundary follows "<grux-artifact" (space or ">"), so we
        // do not match "<grux-artifacts".
        let afterIdx = buffer.index(buffer.startIndex, offsetBy: prefix.count)
        let after = buffer[afterIdx]
        guard after == ">" || after == " " || after == "\n" || after == "\t" || after == "\r" else {
            return emitLiteralLessThan(&events)
        }
        // Need the whole opening tag before we can read its path.
        guard let gt = buffer.firstIndex(of: ">") else { return false }
        let openTag = String(buffer[buffer.startIndex...gt])
        buffer = String(buffer[buffer.index(after: gt)...])
        if let raw = Self.parsePathAttribute(openTag), let valid = Self.validate(path: raw) {
            state = .inside
            currentPath = valid
            currentText = ""
            events.append(.fileStarted(path: valid))
        } else {
            // Bad or missing path: swallow the block so it never reaches disk.
            state = .skipping
        }
        return true
    }

    private func drainInside(_ events: inout [DesignArtifactEvent]) -> Bool {
        if let range = buffer.range(of: Self.closeTag) {
            let content = String(buffer[..<range.lowerBound])
            if !content.isEmpty {
                currentText += content
                events.append(.fileChunk(path: currentPath, text: content))
            }
            events.append(.fileCompleted(path: currentPath, fullText: currentText))
            buffer = String(buffer[range.upperBound...])
            resetToIdle()
            return true
        }
        // No full close tag yet. Emit everything except a trailing suffix that
        // could still grow into the close tag.
        let hold = Self.heldBackSuffixLength(buffer, closing: Self.closeTag)
        let safeCount = buffer.count - hold
        if safeCount > 0 {
            let content = String(buffer.prefix(safeCount))
            currentText += content
            events.append(.fileChunk(path: currentPath, text: content))
            buffer = String(buffer.dropFirst(safeCount))
        }
        return false
    }

    private func drainSkipping(_ events: inout [DesignArtifactEvent]) -> Bool {
        if let range = buffer.range(of: Self.closeTag) {
            buffer = String(buffer[range.upperBound...])
            resetToIdle()
            return true
        }
        let hold = Self.heldBackSuffixLength(buffer, closing: Self.closeTag)
        let dropCount = buffer.count - hold
        if dropCount > 0 { buffer = String(buffer.dropFirst(dropCount)) }
        return false
    }

    // MARK: - Helpers

    private func emitLiteralLessThan(_ events: inout [DesignArtifactEvent]) -> Bool {
        guard !buffer.isEmpty else { return false }
        let first = String(buffer.removeFirst())
        events.append(.passthroughText(first))
        return true
    }

    private func resetToIdle() {
        state = .idle
        currentPath = ""
        currentText = ""
    }

    // Merge adjacent passthrough events so a "<" split off from its prose does
    // not surface as a flurry of one-character events.
    private func coalesce(_ events: [DesignArtifactEvent]) -> [DesignArtifactEvent] {
        var out: [DesignArtifactEvent] = []
        for e in events {
            if case .passthroughText(let t) = e,
               case .passthroughText(let prev)? = out.last {
                out[out.count - 1] = .passthroughText(prev + t)
            } else {
                out.append(e)
            }
        }
        return out
    }

    // Length of the longest suffix of `s` that equals a prefix of `closing`
    // (shorter than the full tag; a full match is handled by range(of:)). This
    // is the amount we must hold back so a split close tag is never emitted as
    // file content.
    static func heldBackSuffixLength(_ s: String, closing: String) -> Int {
        let sChars = Array(s)
        let cChars = Array(closing)
        let maxLen = min(sChars.count, cChars.count - 1)
        var k = maxLen
        while k > 0 {
            var match = true
            for i in 0..<k where sChars[sChars.count - k + i] != cChars[i] {
                match = false
                break
            }
            if match { return k }
            k -= 1
        }
        return 0
    }

    // Read path="..." (or path='...') out of a full opening tag.
    static func parsePathAttribute(_ tag: String) -> String? {
        guard let r = tag.range(of: "path=") else { return nil }
        var rest = tag[r.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[..<end])
    }

    // Project-relative, under site/, no traversal, no absolute paths.
    static func validate(path raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        guard !p.hasPrefix("/") else { return nil }
        guard !p.hasPrefix("site//") else { return nil }
        guard p.hasPrefix("site/") else { return nil }
        guard !p.hasSuffix("/") else { return nil }
        guard !p.contains("\\") else { return nil }
        guard !p.contains("..") else { return nil }
        // Reject empty path components (e.g. "site//x").
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        guard !comps.contains(where: { $0.isEmpty }) else { return nil }
        return p
    }
}
