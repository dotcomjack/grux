import Foundation

// Claude-tool adapter for audio export. Mirrors MeetingTool's shape:
// ChatService.allTools() appends this tool-set; ChatService.dispatchTool()
// routes the named calls here. Kept intentionally small - one tool,
// two modes (ambient tail and meeting full-session).
enum AudioExportTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "export_audio",
                description:
                    "Save captured audio to a .wav file on disk and reveal it in Finder. Two modes:\n" +
                    "- mode='ambient_recent' saves the newest `seconds` of ambient audio (default 900 = 15 min). Capped to what's in the rolling buffer.\n" +
                    "- mode='meeting' saves the full-session WAV for a specific captured meeting (requires meeting_id from list_meetings).\n" +
                    "Use when the user says 'save that', 'export the audio', 'download the last X minutes', 'grab the wav', etc. Returns the file path.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "mode": [
                            "type": "string",
                            "enum": ["ambient_recent", "meeting"],
                            "description": "Which audio source to export."
                        ],
                        "seconds": [
                            "type": "integer",
                            "description": "For mode='ambient_recent'. How many seconds from the tail to export. Default 900 (15 min). Ceilinged by the ring window."
                        ],
                        "meeting_id": [
                            "type": "string",
                            "description": "For mode='meeting'. The meeting's UUID from list_meetings."
                        ],
                        "reveal": [
                            "type": "boolean",
                            "description": "Whether to reveal the file in Finder after writing. Default true."
                        ]
                    ],
                    "required": ["mode"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        guard name == "export_audio" else {
            return "error: unknown audio export tool '\(name)'"
        }
        let mode = ((input["mode"] as? String) ?? "").lowercased()
        let reveal = (input["reveal"] as? Bool) ?? true

        switch mode {
        case "ambient_recent":
            let rawSeconds = (input["seconds"] as? Int) ?? AmbientAudioRing.defaultMaxSeconds
            let seconds = max(5, min(rawSeconds, AmbientAudioRing.shared.windowSeconds))
            let available = AmbientAudioRing.shared.availableSeconds
            guard available > 0.5 else {
                return "error: ambient ring buffer is empty - nothing to export. Is ambient listening on?"
            }
            guard let url = AudioExportStore.exportAmbientTail(seconds: Double(seconds)) else {
                return "error: ambient export failed - see wake.log for details"
            }
            if reveal { await MainActor.run { AudioExportStore.reveal(url) } }
            let mins = Int(min(Double(seconds), available) / 60.0 + 0.5)
            return "ok: wrote \(url.lastPathComponent) (~\(max(1, mins)) min mono 16 kHz WAV) at \(url.path)"

        case "meeting":
            guard let idStr = input["meeting_id"] as? String, let id = UUID(uuidString: idStr) else {
                return "error: meeting_id must be a valid UUID. Call list_meetings first."
            }
            let title: String? = await MainActor.run { MeetingStore.shared.loadRecord(id: id)?.title }
            guard let url = AudioExportStore.exportMeetingAudio(meetingId: id, title: title) else {
                return "error: no audio found for that meeting. Meeting may have been captured before audio export was enabled, or was recorded with meetingAudioKeepWAV off."
            }
            if reveal { await MainActor.run { AudioExportStore.reveal(url) } }
            return "ok: wrote \(url.lastPathComponent) at \(url.path)"

        default:
            return "error: mode must be 'ambient_recent' or 'meeting' (got '\(mode)')"
        }
    }
}
