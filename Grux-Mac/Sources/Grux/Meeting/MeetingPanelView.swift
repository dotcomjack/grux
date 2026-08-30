import SwiftUI

struct MeetingPanelView: View {
    @EnvironmentObject var service: MeetingCaptureService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if service.isCapturing {
                transcriptStream
            } else if let rec = service.activeMeeting {
                summaryView(rec: rec)
            } else {
                idleView
            }
            Divider()
            controls
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Material.regular)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(service.isCapturing ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.red.opacity(service.isCapturing ? 0.6 : 0), lineWidth: 2)
                        .scaleEffect(service.isCapturing ? 1.6 : 1.0)
                        .opacity(service.isCapturing ? 0.3 : 0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: service.isCapturing)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("MEETING")
                    .font(.caption.bold()).kerning(2)
                Text(service.isCapturing
                     ? "capturing · \(service.elapsedDisplay)"
                     : (service.activeMeeting?.displayTitle ?? "Idle"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if let rec = service.activeMeeting, let app = rec.sourceAppName {
                Text(app)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(Color.purple)
                    .clipShape(Capsule())
            }
        }
    }

    private var transcriptStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(service.liveUtterances) { u in
                        utteranceRow(u)
                            .id(u.id)
                    }
                    if service.liveUtterances.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Listening for the first phrase…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 18)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: service.liveUtterances.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
        }
    }

    private func utteranceRow(_ u: MeetingUtterance) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString(u.t))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let label = u.speakerLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption2.bold())
                        .kerning(0.4)
                        .foregroundStyle(u.speakerProfileId != nil ? Color.purple : .secondary)
                }
                Text(u.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func summaryView(rec: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = rec.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SUMMARY").font(.caption2.bold()).kerning(1.5).foregroundStyle(.secondary)
                        Text(summary).font(.callout)
                    }
                }
                if !rec.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ACTION ITEMS").font(.caption2.bold()).kerning(1.5).foregroundStyle(.secondary)
                        ForEach(rec.actionItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(Color.purple)
                                Text(item).font(.callout)
                            }
                        }
                    }
                }
                exportAudioRow(rec: rec)
                if !rec.utterances.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TRANSCRIPT").font(.caption2.bold()).kerning(1.5).foregroundStyle(.secondary)
                        ForEach(rec.utterances) { u in
                            utteranceRow(u)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // Per-meeting "Export audio" row. Shown in the summary view after a
    // capture ends. Disabled + labeled appropriately when the meeting was
    // captured with crash-safe audio off (no WAV on disk). Fetches the
    // meeting-audio URL at render time so exists-check stays fresh across
    // summary re-displays.
    private func exportAudioRow(rec: MeetingRecord) -> some View {
        let audioURL = AudioExportStore.meetingAudioURL(for: rec.id)
        let hasAudio = FileManager.default.fileExists(atPath: audioURL.path)
        return VStack(alignment: .leading, spacing: 6) {
            Text("AUDIO").font(.caption2.bold()).kerning(1.5).foregroundStyle(.secondary)
            if hasAudio {
                HStack(spacing: 10) {
                    Button {
                        if let url = AudioExportStore.exportMeetingAudio(meetingId: rec.id, title: rec.title) {
                            AudioExportStore.reveal(url)
                        }
                    } label: {
                        Label("Export WAV", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        AudioExportStore.reveal(audioURL)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Audio not available. Capture was run with local recording off.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No active meeting.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Press ⌘⇧M, click Start below, or auto-start when Zoom / Meet / FaceTime becomes frontmost.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if service.isCapturing {
                Button(role: .destructive) {
                    Task { await service.stop() }
                } label: {
                    Label("Stop & summarize", systemImage: "stop.circle.fill")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await service.start() }
                } label: {
                    Label("Start meeting capture", systemImage: "record.circle")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(service.isInitializing)
            }
            Spacer()
            if let err = service.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
