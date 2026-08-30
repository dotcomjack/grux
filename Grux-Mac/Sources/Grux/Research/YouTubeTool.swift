import Foundation

// Claude tool surface for YouTube transcript ingestion. Registered into
// ChatService.allTools() and dispatched from ChatService.dispatchTool(),
// mirroring the AgentTools pattern (toolNames set + claudeTools() +
// dispatch(name:input:)).
//
// Opt in: `YouTubeTranscript.fetch` refuses on `step.youtube_transcripts_enabled`
// before it constructs anything, and the refusal arrives here as an ordinary
// error, so the sentence the user reads is the capability's own. The tool stays
// registered either way, which is the point: somebody who asks about a video is
// told what this is and where to switch it on rather than watching the request
// quietly do nothing.
//
// Side effect: every successful fetch chunk-ingests the transcript into
// SemanticMemory (kind .web) so "what was that video about X" recalls it
// later without re-fetching.

enum YouTubeTool {

    static let toolNames: Set<String> = ["youtube_transcript"]

    // Tool output cap. Past this we truncate gracefully on a line boundary.
    static let outputCharLimit = 50_000

    // SemanticMemory ingest shape: chunked so retrieval hits mid-video
    // content (the embedder only reads ~800 chars per entry), capped so a
    // 3-hour video cannot flood the .web store.
    static let ingestChunkChars = 700
    static let ingestMaxChunks = 16

    static func claudeTools() -> [ClaudeTool] {
        return [
            ClaudeTool(
                name: "youtube_transcript",
                description: "Fetch the full transcript of a YouTube video from its URL or video ID. Use when the user pastes a YouTube link and asks 'what does this video say', 'summarize this video', 'pull the transcript', 'what did they say about X in this video', or wants to remember / reference a video's content later. Returns the video title plus a timestamped transcript (truncated past ~50k characters). The transcript is also saved into Grux's semantic memory automatically, so after one ingest they can ask about the video in future sessions without re-fetching. Videos with no captions (music, some live streams, captions disabled) return a clear error; say so plainly instead of retrying. Transcript fetching is off until the user turns it on; if the error says so, relay that sentence to them and do not look for another way to get the video's contents.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "YouTube video URL (youtube.com/watch?v=..., youtu.be/..., /shorts/...) or a bare 11-character video ID."
                        ]
                    ],
                    "required": ["url"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "youtube_transcript":
            let url = ((input["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return "error: url is required" }
            return await fetchAndIngest(urlOrId: url)
        default:
            return "error: unknown youtube tool '\(name)'"
        }
    }

    // MARK: - Fetch + ingest

    private static func fetchAndIngest(urlOrId: String) async -> String {
        // Network feature: respect offline mode like WebResearch does.
        let offline = await MainActor.run { AppState.shared.offlineMode }
        guard !offline else {
            return "error: youtube transcript fetch unavailable in offline mode."
        }

        let result: YouTubeTranscriptResult
        do {
            result = try await YouTubeTranscript.fetch(urlOrId: urlOrId)
        } catch {
            return "error: \(error.localizedDescription)"
        }

        await ingestIntoMemory(result)

        let stamped = result.textWithTimestamps
        let body = YouTubeTranscript.truncated(stamped, limit: outputCharLimit)
        let minutes = result.segments.last.map { Int(($0.start + $0.duration) / 60.0) } ?? 0
        let header = """
        title: \(result.title)
        video_id: \(result.videoId)
        length: ~\(minutes) min, \(result.segments.count) caption segments (source: \(result.source))
        saved: transcript ingested into semantic memory for future recall
        """
        return header + "\n\ntranscript:\n" + body
    }

    // Chunk the plain transcript into embeddable pieces and store each under
    // kind .web with video metadata, plus one header entry that anchors
    // title-based recall.
    private static func ingestIntoMemory(_ result: YouTubeTranscriptResult) async {
        let enabled = await MainActor.run { AppState.shared.config.memoryEnabled }
        guard enabled else { return }

        let chunks = chunkTranscript(result.plainText, chunkChars: ingestChunkChars, maxChunks: ingestMaxChunks)
        let videoUrl = "https://www.youtube.com/watch?v=\(result.videoId)"
        let baseMeta: [String: String] = [
            "videoId": result.videoId,
            "videoUrl": videoUrl,
            "title": result.title
        ]

        await MainActor.run {
            let memory = SemanticMemory.shared
            memory.store(
                kind: .web,
                text: "YouTube video ingested: \"\(result.title)\" (\(videoUrl)). Transcript stored in \(chunks.count) chunks.",
                metadata: baseMeta
            )
            for (i, chunk) in chunks.enumerated() {
                var meta = baseMeta
                meta["chunk"] = "\(i + 1)/\(chunks.count)"
                memory.store(
                    kind: .web,
                    text: "[\(result.title)] \(chunk)",
                    metadata: meta
                )
            }
        }
    }

    // MARK: - Chunking (pure, testable)

    // Split flowing prose into ~chunkChars pieces on word boundaries, capped
    // at maxChunks. The cap drops the TAIL of very long videos rather than
    // sampling, keeping chunk text contiguous and quotable.
    static func chunkTranscript(_ text: String, chunkChars: Int, maxChunks: Int) -> [String] {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for w in words {
            if current.isEmpty {
                current = String(w)
            } else if current.count + 1 + w.count > chunkChars {
                chunks.append(current)
                if chunks.count >= maxChunks { return chunks }
                current = String(w)
            } else {
                current += " " + w
            }
        }
        if !current.isEmpty && chunks.count < maxChunks {
            chunks.append(current)
        }
        return chunks
    }
}
