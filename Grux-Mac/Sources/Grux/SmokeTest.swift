import Foundation
import AppKit
import AVFoundation
import CoreGraphics

// Deterministic PRNG for reproducible audio test signals. Seeded so CI /
// rerun behavior is stable. Not cryptographically strong - it's a test RNG.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Returns a uniform Float in [0, 1).
    mutating func nextFloat() -> Float {
        // Top 24 bits for a float mantissa; divide by 2^24.
        let u = next() >> 40
        return Float(u) / Float(1 << 24)
    }
}

enum SmokeTest {
    @MainActor
    static func runAndWriteReport() async {
        var lines: [String] = []
        var pass = 0
        var fail = 0

        func record(_ name: String, _ ok: Bool, _ detail: String) {
            let tag = ok ? "PASS" : "FAIL"
            if ok { pass += 1 } else { fail += 1 }
            lines.append("[\(tag)] \(name) - \(detail)")
        }

        lines.append("Grux smoke test - \(ISO8601DateFormatter().string(from: Date()))")
        lines.append(String(repeating: "=", count: 60))

        // 1. fs_read on allowed path
        let allowedPath = NSHomeDirectory() + "/Projects/package.json"
        let r1 = await FilesystemTool.dispatch(name: "fs_read", input: ["path": allowedPath])
        record(
            "fs_read allowed path (Projects/package.json)",
            !r1.hasPrefix("error:") && r1.count > 10,
            "returned \(r1.count) bytes; preview: \(String(r1.prefix(60)).replacingOccurrences(of: "\n", with: " "))"
        )

        // 2. fs_read on denied path (~/.ssh) must be blocked
        let deniedSsh = NSHomeDirectory() + "/.ssh/config"
        let r2 = await FilesystemTool.dispatch(name: "fs_read", input: ["path": deniedSsh])
        record(
            "fs_read denied .ssh",
            r2.hasPrefix("error:") && (r2.contains("denylist") || r2.contains("allowlist") || r2.contains("blocked") || r2.contains("denied")),
            "response: \(r2)"
        )

        // 3. fs_read on .env inside an allowed root must still be denied by denylist
        let envProbe = NSHomeDirectory() + "/Projects/.env"
        let r3 = await FilesystemTool.dispatch(name: "fs_read", input: ["path": envProbe])
        record(
            "fs_read denied .env inside allowed root",
            r3.hasPrefix("error:"),
            "response: \(r3)"
        )

        // 4. Rate limit - fire 12 fs_list calls, expect at least one rate_limit error
        var rateLimited = false
        for _ in 0..<12 {
            let resp = await FilesystemTool.dispatch(
                name: "fs_list",
                input: ["path": NSHomeDirectory() + "/Projects"]
            )
            if resp.contains("rate_limit") || resp.contains("rate limit") { rateLimited = true }
        }
        record(
            "rate limit trips after >10 calls/min",
            rateLimited,
            rateLimited ? "at least one call returned rate_limit error" : "no rate_limit error seen across 12 calls"
        )

        // 5. Redaction: fake Anthropic + AWS keys are stripped
        let dirty = """
        Here is a test Anthropic key: sk-ant-api03-FAKEKEYxyz12345678901234567890 and
        an AWS access key: AKIAFAKEKEY123456789 plus a PEM header:
        -----BEGIN PRIVATE KEY-----
        """
        let cleaned = SecretRedactor.redact(dirty)
        let redactedOK = !cleaned.contains("sk-ant-api03-FAKE")
            && !cleaned.contains("AKIAFAKEKEY")
            && cleaned.contains("[REDACTED:")
        record(
            "redaction strips seeded secrets",
            redactedOK,
            "cleaned preview: \(cleaned.replacingOccurrences(of: "\n", with: " ").prefix(140))"
        )

        // 6. Keychain holds a key AND config fields are blanked/sentinel
        let kcAnthropic = KeychainStore.get(.anthropicApiKey)
        let cfgAnthropic = AppState.shared.config.anthropicApiKey
        let kcHasKey = !kcAnthropic.isEmpty && kcAnthropic.hasPrefix("sk-ant-")
        let cfgBlank = cfgAnthropic.isEmpty || cfgAnthropic == "[MIGRATED]"
        record(
            "Keychain holds anthropic key; config blanked",
            kcHasKey && cfgBlank,
            "keychain_len=\(kcAnthropic.count) config_field=\(cfgAnthropic.prefix(12))…"
        )

        // 7. Audit log has entries
        let auditPath = NSHomeDirectory() + "/Library/Application Support/Grux/fs-audit.log"
        let auditExists = FileManager.default.fileExists(atPath: auditPath)
        let auditSize: Int = {
            if let attr = try? FileManager.default.attributesOfItem(atPath: auditPath),
               let s = attr[.size] as? Int { return s }
            return 0
        }()
        record(
            "audit log exists and has entries",
            auditExists && auditSize > 0,
            "path=\(auditPath) size=\(auditSize) bytes"
        )

        // 8. Migrator sentinel check - config file on disk should NOT leak real key
        let configPath = NSHomeDirectory() + "/Library/Application Support/Grux/config.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let s = String(data: data, encoding: .utf8) {
            let hasPlaintext = s.contains("sk-ant-api03-") && !s.contains("[MIGRATED]")
            record(
                "config.json on disk contains no plaintext key",
                !hasPlaintext,
                "file size \(s.count) chars"
            )
        } else {
            record("config.json readable", false, "could not read \(configPath)")
        }

        // 9. Workspace awareness - observer is live and returns fresh data.
        // Can't easily assert that lastNonGrux is populated (depends on what
        // the user had open before launching Grux), but we CAN assert the snapshot
        // is callable, isGruxFrontmost matches NSWorkspace.frontmostApplication,
        // and current app matches a live requery.
        let wsSnap = WorkspaceObserver.shared.snapshot()
        let liveFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let gruxBundle = Bundle.main.bundleIdentifier ?? "com.gruxai.grux"
        let expectedIsGrux = (liveFrontmost == gruxBundle)
        let frontMatches = (wsSnap.currentBundleId == liveFrontmost) || liveFrontmost.isEmpty
        let isGruxConsistent = (wsSnap.isGruxFrontmost == expectedIsGrux)
        record(
            "workspace observer snapshot is live + consistent",
            frontMatches && isGruxConsistent,
            "current=\(wsSnap.currentBundleId) live=\(liveFrontmost) isGrux=\(wsSnap.isGruxFrontmost) lastNonGrux=\(wsSnap.lastNonGruxBundleId.isEmpty ? "(empty)" : wsSnap.lastNonGruxBundleId)"
        )

        // 10. App catalog + fuzzy match: resolves "finder" → com.apple.finder
        // and "activity" → Activity Monitor without attempting to launch.
        AppCatalog.shared.buildIfNeeded()
        let catalogSize = AppCatalog.shared.entries.count
        let finderHit = AppCatalog.shared.match("finder")
        let activityHit = AppCatalog.shared.match("activity")
        let catalogOK = catalogSize >= 5
            && finderHit?.bundleId == "com.apple.finder"
            && (activityHit?.name.localizedCaseInsensitiveContains("activity") ?? false)
        record(
            "app catalog indexed + fuzzy match works",
            catalogOK,
            "indexed=\(catalogSize) finder=\(finderHit?.bundleId ?? "nil") activity=\(activityHit?.name ?? "nil")"
        )

        // 11. Voice macros: the registry loads, an empty registry is a valid
        // state, and every macro it holds is retrievable by its machine name.
        //
        // This check used to assert that a specific compiled-in macro existed
        // and that its four actions were in a canonical order. That macro was
        // one person's wake ritual and has been deleted, so the assertion now
        // fails by construction on every machine except the one that authored
        // the file. Worse, it was never really testing the registry: it was
        // testing that a seed had not changed. The mechanism is what matters,
        // and it is checkable with zero macros present.
        VoiceMacroRegistry.shared.load()
        let macroCount = VoiceMacroRegistry.shared.macros.count
        // A registry holding macros it cannot look up is the real failure mode,
        // and it is exactly what an empty-registry check would miss.
        let allFindable = VoiceMacroRegistry.shared.macros.allSatisfy {
            VoiceMacroRegistry.shared.find(name: $0.name) != nil
        }
        // ...and the lookup must MISS on a name that cannot exist, or
        // allFindable above is passing because find() returns something for
        // everything.
        let missesUnknown = VoiceMacroRegistry.shared
            .find(name: "grux-smoke-absent-\(UUID().uuidString)") == nil
        record(
            "voice macro registry loads, empty is valid, every macro findable by name",
            allFindable && missesUnknown,
            "count=\(macroCount) allFindable=\(allFindable) missesUnknown=\(missesUnknown)"
        )

        // 12. Tiler math: 2×2 quadrants cover the full visible frame with no
        // overlap and each is exactly ¼ of the visible area.
        let quads = TerminalGridTiler.axQuadrants(rows: 2, cols: 2)
        var tileOK = quads.count == 4
        if tileOK, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let expectedW = vf.width / 2
            let expectedH = vf.height / 2
            for q in quads {
                if abs(q.width - expectedW) > 0.5 || abs(q.height - expectedH) > 0.5 {
                    tileOK = false; break
                }
            }
            // Xs should be {originX, originX + w}; Ys should be two distinct values
            let xs = Set(quads.map { Int($0.minX.rounded()) })
            let ys = Set(quads.map { Int($0.minY.rounded()) })
            if xs.count != 2 || ys.count != 2 { tileOK = false }
        } else {
            tileOK = false
        }
        record(
            "2×2 tiler quadrants cover visible frame cleanly",
            tileOK,
            "quads=\(quads.count) frames=\(quads.map { "(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))×\(Int($0.height)))" }.joined(separator: " "))"
        )

        // 13. Browser tool AppleScript compiles (syntax valid). We don't
        // actually execute - that would open a Chrome tab mid-test.
        let sampleScript = NSAppleScript(source: """
        tell application "Google Chrome"
            if (count of windows) = 0 then
                return "empty"
            else
                tell front window
                    return "front"
                end tell
            end if
        end tell
        """)
        var errDict: NSDictionary?
        let compiled = sampleScript?.compileAndReturnError(&errDict) ?? false
        record(
            "Chrome AppleScript compiles (syntax valid, execution not run)",
            compiled && errDict == nil,
            "compiled=\(compiled) err=\(errDict?.description ?? "none")"
        )

        // 14. Coach sanitizer strips JSON envelopes, code fences, and
        // `{speech: ...}` wrappers that Claude sometimes emits around what
        // should be plain prose.
        let coachDirty = [
            "```json\n{speech: Focus mode is on, so get that prompt into the terminal and start.}\n```",
            "```json\n{\"speech\": \"get back to it.\"}\n```",
            "{speech:\"ship the damn thing.\"}",
            "\"just plain quoted text.\"",
            "plain prose, no wrapper"
        ]
        let coachExpected = [
            "Focus mode is on, so get that prompt into the terminal and start.",
            "get back to it.",
            "ship the damn thing.",
            "just plain quoted text.",
            "plain prose, no wrapper"
        ]
        var sanitizerOK = true
        var sanitizerDetails: [String] = []
        for (i, raw) in coachDirty.enumerated() {
            let out = AmbientCoach.sanitizeCoachReply(raw)
            if out != coachExpected[i] {
                sanitizerOK = false
                sanitizerDetails.append("[\(i)] got='\(out)' want='\(coachExpected[i])'")
            }
        }
        record(
            "AmbientCoach.sanitizeCoachReply strips JSON/fences/quotes",
            sanitizerOK,
            sanitizerOK ? "all 5 cases clean" : sanitizerDetails.joined(separator: " | ")
        )

        // 15. GruxMode enum: all four modes exist with distinct cooldowns +
        // distinct voice instructions + distinct menu-bar glyphs.
        let modes = GruxMode.allCases
        let uniqueCooldowns = Set(modes.map(\.coachCooldownSeconds))
        let uniqueInstructions = Set(modes.map(\.voiceInstructions))
        let uniqueGlyphs = Set(modes.map(\.menuBarGlyph))
        let modeEnumOK = modes.count == 4
            && uniqueCooldowns.count == 4
            && uniqueInstructions.count == 4
            && uniqueGlyphs.count == 4
            // Invariant: tighter modes have shorter cooldowns
            && GruxMode.sheesh.coachCooldownSeconds < GruxMode.grind.coachCooldownSeconds
            && GruxMode.grind.coachCooldownSeconds < GruxMode.normal.coachCooldownSeconds
            && GruxMode.normal.coachCooldownSeconds < GruxMode.chill.coachCooldownSeconds
        record(
            "GruxMode enum: 4 modes, distinct cooldowns + instructions, monotone cadence",
            modeEnumOK,
            "modes=\(modes.map(\.rawValue).joined(separator: ",")) cooldowns=\(modes.map { Int($0.coachCooldownSeconds) })"
        )

        // 16. set_mode tool: Claude can flip mode; change persists to config
        // and round-trips through the Codable layer.
        let originalMode = AppState.shared.config.currentMode
        let setGrind = await ChatService.dispatchTool(name: "set_mode", input: ["mode": "grind"])
        let afterGrind = AppState.shared.config.currentMode
        let setBogus = await ChatService.dispatchTool(name: "set_mode", input: ["mode": "ludicrous"])
        let afterBogus = AppState.shared.config.currentMode
        let setSheesh = await ChatService.dispatchTool(name: "set_mode", input: ["mode": "sheesh"])
        let afterSheesh = AppState.shared.config.currentMode
        // Restore so we don't leave the user stuck in sheesh.
        AppState.shared.config.currentMode = originalMode
        AppState.shared.saveConfig()
        let setModeOK = setGrind.hasPrefix("ok:")
            && afterGrind == .grind
            && setBogus.hasPrefix("error:")
            && afterBogus == .grind      // bogus call left mode untouched
            && setSheesh.hasPrefix("ok:")
            && afterSheesh == .sheesh
        record(
            "set_mode tool flips + persists, rejects unknown modes",
            setModeOK,
            "grind=\(setGrind.prefix(30)) bogus=\(setBogus.prefix(30)) sheesh=\(setSheesh.prefix(30))"
        )

        // 17-22 removed: EchoCanceller, SystemAudioTap, and HighPassFilter
        // were ripped out in favor of Apple's kAudioUnitSubType_VoiceProcessingIO
        // (FaceTime-grade hardware AEC + NS + AGC), which AmbientListener
        // enables on its mic input. The custom DSP layers were redundant with
        // VP-IO and were the source of the silent-playback class of bugs
        // (sys-audio-tap interrupts wedged SpeechEngine's AVAudioEngine).
        // Test #39 below still verifies VP-IO is available on this hardware.

        // 23. AdaptiveNoiseGate learns a fan-level floor and rejects it.
        // 80 frames of steady 0.004 RMS - exactly the regime where the old
        // hardcoded `rms > 0.006` threshold held, but a louder fan at ~0.008
        // RMS would still pass. We test 0.004 here because it must be gated
        // once the floor rises up through it.
        let fanGate = AdaptiveNoiseGate()
        let fanRms: Float = 0.004
        var fanTripsAsVoice = 0
        for _ in 0..<80 {
            if fanGate.classify(rms: fanRms) { fanTripsAsVoice += 1 }
        }
        record(
            "AdaptiveNoiseGate gates steady fan-level RMS as noise",
            fanTripsAsVoice == 0,
            String(format: "fanRms=%.4f trips=%d floor=%.4f",
                   Double(fanRms), fanTripsAsVoice, Double(fanGate.currentNoiseFloor))
        )

        // 24. Same gate still fires on voice-level RMS after learning the
        // floor - the whole point is rejecting fan but keeping voice.
        let voiceTestRms: Float = 0.020
        let voicedAfterFanTraining = fanGate.classify(rms: voiceTestRms)
        record(
            "AdaptiveNoiseGate fires on voice over learned fan floor",
            voicedAfterFanTraining,
            String(format: "rms=%.4f floor=%.4f ⇒ %@",
                   Double(voiceTestRms),
                   Double(fanGate.currentNoiseFloor),
                   voicedAfterFanTraining ? "VOICE" : "NOISE")
        )

        // 25. Louder ambient noise (0.008 RMS - the kind that defeated the
        // old static threshold) is also gated correctly once learned.
        let loudFanGate = AdaptiveNoiseGate()
        let loudFanRms: Float = 0.008
        var loudFanTrips = 0
        for _ in 0..<80 {
            if loudFanGate.classify(rms: loudFanRms) { loudFanTrips += 1 }
        }
        record(
            "AdaptiveNoiseGate gates 0.008 RMS ambient (old threshold killer)",
            loudFanTrips == 0,
            String(format: "rms=%.4f trips=%d floor=%.4f",
                   Double(loudFanRms), loudFanTrips, Double(loudFanGate.currentNoiseFloor))
        )

        // 26. speakAfterCurrent defers when Grux is thinking/speaking. Set
        // isThinking=true, queue a polite utterance with a tight timeout,
        // confirm it waits (hasPendingPoliteSpeak flips on) and then goes
        // stale (flips off) without ever calling through to speak(). This
        // is the core guarantee that coach never cuts in mid-thought.
        SpeechEngine.shared.stop(reason: "smoke test reset")
        let priorIsThinking = AppState.shared.isThinking
        AppState.shared.isThinking = true
        SpeechEngine.shared.speakAfterCurrent("smoke-test-nudge", maxWaitSeconds: 0.2)
        try? await Task.sleep(nanoseconds: 60_000_000) // 60ms - polite task has queued
        let sawPendingWhileBusy = SpeechEngine.shared.hasPendingPoliteSpeak
        try? await Task.sleep(nanoseconds: 600_000_000) // past the 0.2s timeout
        let pendingAfterTimeout = SpeechEngine.shared.hasPendingPoliteSpeak
        let stillQuiet = !SpeechEngine.shared.isSpeaking && !SpeechEngine.shared.isBuffering
        AppState.shared.isThinking = priorIsThinking
        record(
            "speakAfterCurrent defers while busy, drops when stale",
            sawPendingWhileBusy && !pendingAfterTimeout && stillQuiet,
            "queuedWhileBusy=\(sawPendingWhileBusy ? "Y" : "N") droppedAfterTimeout=\(!pendingAfterTimeout ? "Y" : "N") engineQuiet=\(stillQuiet ? "Y" : "N")"
        )

        // 27. speakAfterCurrent supersedes an older queued message - only
        // the most recent polite utterance should still be pending.
        AppState.shared.isThinking = true
        SpeechEngine.shared.speakAfterCurrent("older", maxWaitSeconds: 5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        SpeechEngine.shared.speakAfterCurrent("newer", maxWaitSeconds: 5)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let onePending = SpeechEngine.shared.hasPendingPoliteSpeak
        // Explicit cancel prevents the pending task from ever firing real
        // TTS when we restore isThinking.
        SpeechEngine.shared.cancelPendingPoliteSpeak()
        AppState.shared.isThinking = priorIsThinking
        SpeechEngine.shared.stop(reason: "smoke test cleanup")
        record(
            "speakAfterCurrent supersedes older queued message",
            onePending,
            "pendingAfterSupersede=\(onePending ? "Y" : "N")"
        )

        // 28. E2E lifecycle - polite enqueue waits while Grux is "thinking",
        // fires its action AFTER quiet arrives. Uses the closure-based
        // primitive so we can verify the fire happened without triggering
        // real ElevenLabs TTS. Timing accounts for the 250ms poll interval
        // + 150ms settle delay after quiet.
        AppState.shared.isThinking = true
        var e2eFired = false
        var e2eFiredAt: Date? = nil
        let e2eQueuedAt = Date()
        SpeechEngine.shared.enqueuePoliteAction(maxWaitSeconds: 5) {
            e2eFired = true
            e2eFiredAt = Date()
        }
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms - still "thinking"
        let e2eWaitingWhileBusy = !e2eFired && SpeechEngine.shared.hasPendingPoliteSpeak
        AppState.shared.isThinking = priorIsThinking
        // Give the polite task time to notice quiet + run settle + fire.
        // Max: 250ms (remaining poll) + 150ms settle + scheduling = ~450ms.
        try? await Task.sleep(nanoseconds: 800_000_000)
        let e2eFiredAfterQuiet = e2eFired
        let e2eFireDuration = e2eFiredAt.map { $0.timeIntervalSince(e2eQueuedAt) } ?? 0
        record(
            "polite E2E: waits while busy → fires after quiet",
            e2eWaitingWhileBusy && e2eFiredAfterQuiet && e2eFireDuration > 0.3 && e2eFireDuration < 2.0,
            String(format: "waitedWhileBusy=%@ firedAfterQuiet=%@ firedAt=%.2fs",
                   e2eWaitingWhileBusy ? "Y" : "N",
                   e2eFiredAfterQuiet ? "Y" : "N",
                   e2eFireDuration)
        )

        // 29. E2E supersede - older closure MUST never fire when a newer
        // enqueue arrives before quiet. Only the newer closure should fire.
        AppState.shared.isThinking = true
        var olderFired = false
        var newerFired = false
        SpeechEngine.shared.enqueuePoliteAction(maxWaitSeconds: 5) { olderFired = true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        SpeechEngine.shared.enqueuePoliteAction(maxWaitSeconds: 5) { newerFired = true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        AppState.shared.isThinking = priorIsThinking
        try? await Task.sleep(nanoseconds: 800_000_000)
        record(
            "polite E2E: supersede drops older, newer fires",
            !olderFired && newerFired,
            "older=\(olderFired ? "FIRED" : "dropped") newer=\(newerFired ? "FIRED" : "dropped")"
        )

        // 30. E2E stale - if quiet never arrives within the wait window,
        // the closure must NEVER fire. Exercises the timeout path with a
        // closure so we can confirm nothing ran silently.
        AppState.shared.isThinking = true
        var stalePoliteFired = false
        SpeechEngine.shared.enqueuePoliteAction(maxWaitSeconds: 0.3) { stalePoliteFired = true }
        // Stay busy past the timeout, plus buffer for the poll-tick.
        try? await Task.sleep(nanoseconds: 900_000_000)
        let stillPendingAfterStale = SpeechEngine.shared.hasPendingPoliteSpeak
        AppState.shared.isThinking = priorIsThinking
        // Extra headroom in case the task was mid-sleep when timeout passed.
        try? await Task.sleep(nanoseconds: 500_000_000)
        record(
            "polite E2E: stale timeout drops closure without firing",
            !stalePoliteFired && !stillPendingAfterStale,
            "closureFired=\(stalePoliteFired ? "Y (BUG)" : "N") stillPending=\(stillPendingAfterStale ? "Y (BUG)" : "N")"
        )

        // 31. SemanticMemory store + retrieve round-trip. The memory subsystem
        // is the backbone of the persistent-memory upgrade; we store a known
        // phrase, retrieve with a semantically related query, and assert the
        // stored text comes back in the top-K.
        _ = SemanticMemory.shared.isReady // trigger lazy init if needed
        let memReady = SemanticMemory.shared.isReady
        let marker = "SMOKE_MARKER_\(UUID().uuidString.prefix(8))"
        let memText = "You just shipped the \(marker) release to production."
        SemanticMemory.shared.store(kind: .fact, text: memText, metadata: ["smoke": "1"])
        // Retrieve using a semantically-adjacent query - not substring match.
        let hits = SemanticMemory.shared.retrieve(
            query: "deployed the release",
            topK: 10,
            kinds: [.fact]
        )
        let roundTripped = hits.contains(where: { $0.text.contains(marker) })
        record(
            "SemanticMemory store→retrieve round-trip (semantic search)",
            memReady && roundTripped,
            "ready=\(memReady) hits=\(hits.count) found=\(roundTripped ? "Y" : "N")"
        )

        // 32. SemanticMemory retrieval is deterministic + returns top-K in
        // descending similarity order. Insert three distinct facts, query
        // with a phrase closer to fact #2, expect fact #2 first.
        let m = "SM2_\(UUID().uuidString.prefix(6))"
        SemanticMemory.shared.store(kind: .fact, text: "\(m) - baseball scores are boring today.")
        SemanticMemory.shared.store(kind: .fact, text: "\(m) - the espresso machine at the shop broke this morning.")
        SemanticMemory.shared.store(kind: .fact, text: "\(m) - Python's asyncio got a new TaskGroup API in 3.11.")
        let ranked = SemanticMemory.shared.retrieve(
            query: "coffee brewing equipment repair",
            topK: 5,
            kinds: [.fact]
        )
        let firstIsCoffee = ranked.first?.text.contains("espresso") ?? false
        record(
            "SemanticMemory top-K cosine ranking surfaces closest match first",
            firstIsCoffee,
            "top=\(ranked.first?.text.prefix(60) ?? "nil")"
        )

        // 33. Brave API key is present in Keychain (required for web research).
        // We verify length + non-empty only, never log the key itself.
        let braveKey = KeychainStore.get(.braveApiKey)
        record(
            "Brave Search API key present in Keychain",
            !braveKey.isEmpty && braveKey.count >= 20,
            "key_len=\(braveKey.count) prefix=\(braveKey.prefix(4))…"
        )

        // 34. GruxTier cadence math: all 10 tiers expose a positive cadence,
        // a valid cloud model, a non-zero max calls/day, and monotone cadence
        // within each family (faster tier ⇒ ≤ cadence).
        let tiers = GruxTier.allCases
        let allHaveCadence = tiers.allSatisfy { $0.cadenceSeconds > 0 }
        let allHaveModel = tiers.allSatisfy { !$0.cloudModel.isEmpty }
        let allHaveCeiling = tiers.allSatisfy { $0.maxCloudCallsPerDay > 0 }
        let hybrid4Cadence = GruxTier.tier4_hybrid_8s.cadenceSeconds == 8
        let cloudSonnetModel = GruxTier.tier10_cloud_sonnet_5s.cloudModel.contains("sonnet")
        let prescreenFlagOK = GruxTier.tier4_hybrid_8s.useLocalPrescreen && !GruxTier.tier7_cloud_8s.useLocalPrescreen
        let cadenceMonotone = GruxTier.tier1_cloud_30s.cadenceSeconds > GruxTier.tier4_hybrid_8s.cadenceSeconds
            && GruxTier.tier4_hybrid_8s.cadenceSeconds > GruxTier.tier6_hybrid_2s.cadenceSeconds
        record(
            "GruxTier: 10 tiers, valid cadence/model/ceiling, monotone",
            allHaveCadence && allHaveModel && allHaveCeiling && hybrid4Cadence
                && cloudSonnetModel && prescreenFlagOK && cadenceMonotone,
            "count=\(tiers.count) t4cad=\(GruxTier.tier4_hybrid_8s.cadenceSeconds) t10model=\(GruxTier.tier10_cloud_sonnet_5s.cloudModel)"
        )

        // 35. GruxConfig tier round-trips through Codable encode/decode. This
        // is how the user's tier selection survives an app restart.
        let originalTier = AppState.shared.config.tier
        let originalMem = AppState.shared.config.memoryEnabled
        let originalWeb = AppState.shared.config.webResearchEnabled
        var mutated = AppState.shared.config
        mutated.tier = .tier5_hybrid_5s
        mutated.memoryEnabled = false
        mutated.webResearchEnabled = false
        mutated.premiumNoiseCancellation = false
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var roundTripOK = false
        var roundTripDetail = "encode failed"
        if let encoded = try? enc.encode(mutated) {
            if let decoded = try? JSONDecoder().decode(GruxConfig.self, from: encoded) {
                roundTripOK = decoded.tier == .tier5_hybrid_5s
                    && decoded.memoryEnabled == false
                    && decoded.webResearchEnabled == false
                    && decoded.premiumNoiseCancellation == false
                roundTripDetail = "tier=\(decoded.tier.rawValue) mem=\(decoded.memoryEnabled) web=\(decoded.webResearchEnabled) aec=\(decoded.premiumNoiseCancellation)"
            } else {
                roundTripDetail = "decode failed"
            }
        }
        // Restore original so smoke-test doesn't clobber the user's actual config.
        AppState.shared.config.tier = originalTier
        AppState.shared.config.memoryEnabled = originalMem
        AppState.shared.config.webResearchEnabled = originalWeb
        record(
            "GruxConfig Codable round-trip preserves tier + upgrade flags",
            roundTripOK,
            roundTripDetail
        )

        // 36. research_web tool is properly gated by webResearchEnabled.
        // With flag=false, the tool must return an "error:" starting with the
        // disabled-feature message. We don't hit the network here - just gate.
        let webWas = AppState.shared.config.webResearchEnabled
        AppState.shared.config.webResearchEnabled = false
        let gatedResp = await ChatService.dispatchTool(
            name: "research_web",
            input: ["query": "what is the weather today", "depth": "fast"]
        )
        AppState.shared.config.webResearchEnabled = webWas
        let gateWorks = gatedResp.hasPrefix("error:") && gatedResp.lowercased().contains("disabled")
        record(
            "research_web tool gated by config.webResearchEnabled",
            gateWorks,
            "resp=\(gatedResp.prefix(80))"
        )

        // 37. ScreenPrescreen thresholds + state machine. Create a 64×64 solid
        // image, evaluate twice against the same (bundleId, title) - first call
        // has no baseline so should escalate; second should NOT (no diff).
        func makeTestImage(color: (UInt8, UInt8, UInt8)) -> CGImage? {
            let width = 64, height = 64
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.setFillColor(red: CGFloat(color.0)/255, green: CGFloat(color.1)/255, blue: CGFloat(color.2)/255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }
        ScreenPrescreen.shared.reset()
        let testBundle = "com.smoketest.fake"
        var preScreenOK = false
        var preScreenDetail = "image creation failed"
        if let img1 = makeTestImage(color: (128, 128, 128)) {
            let r1 = await ScreenPrescreen.shared.evaluate(
                image: img1, bundleId: testBundle, windowTitle: "Test",
                secondsSinceLastCloud: 0, maxSilenceSeconds: 60
            )
            // First call: no baseline ⇒ imageChange is 1.0 and windowChanged=true
            // (lastBundleId was empty). Expect escalate.
            let firstEscalates = r1.shouldEscalate
            // Second call with same image + same bundle/title:
            // imageChange should drop to ~0 and windowChanged=false. No forced
            // escalation (secondsSinceLastCloud=0).
            let r2 = await ScreenPrescreen.shared.evaluate(
                image: img1, bundleId: testBundle, windowTitle: "Test",
                secondsSinceLastCloud: 0, maxSilenceSeconds: 60
            )
            // The Apple feature-print on an identical CGImage: distance ~0.
            let secondStable = !r2.windowChanged && r2.imageChange < 0.05
            preScreenOK = firstEscalates && secondStable
            preScreenDetail = String(format: "first=%@ (reason=%@) second imageChange=%.3f windowChanged=%@",
                                     firstEscalates ? "Y" : "N", r1.reason,
                                     r2.imageChange, r2.windowChanged ? "Y" : "N")
            ScreenPrescreen.shared.reset()
        }
        record(
            "ScreenPrescreen: fresh frame escalates, identical follow-up stable",
            preScreenOK,
            preScreenDetail
        )

        // 38. FocusWatcher.restartForTierChange is idempotent + non-crashing.
        // We don't start it here (would tie up the mic/capture loop mid-test),
        // just prove the hook is wired and can be called repeatedly.
        FocusWatcher.shared.restartForTierChange()
        FocusWatcher.shared.restartForTierChange()
        record(
            "FocusWatcher.restartForTierChange callable + idempotent",
            true,
            "two back-to-back calls completed without crash"
        )

        // 39. Apple voice processing primitive is available on this macOS
        // build + input node. Verifies the API surface compiles & returns a
        // non-throwing success on a disposable engine. Doesn't actually start
        // capture - the VoiceInput path will handle that at mic-time.
        //
        // CRITICAL: skip this probe unless mic auth is already live. Touching
        // the inputNode from an unsigned `swift run` smoke-test binary can
        // cause coreaudiod to bind a fresh TCC grant to that binary's cdhash,
        // which then invalidates the grant for the signed /Applications copy.
        // See audit 2026-04-24.
        var vpSupported = false
        var vpDetail = ""
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let probeEngine = AVAudioEngine()
            do {
                try probeEngine.inputNode.setVoiceProcessingEnabled(true)
                vpSupported = probeEngine.inputNode.isVoiceProcessingEnabled
                vpDetail = "enabled=\(vpSupported) agc=\(probeEngine.inputNode.isVoiceProcessingAGCEnabled)"
                // Leave it off again so we don't leave the HAL in voice-chat mode.
                try probeEngine.inputNode.setVoiceProcessingEnabled(false)
            } catch {
                vpDetail = "threw: \(error.localizedDescription)"
            }
        } else {
            vpDetail = "skipped - mic not authorized in this process (would poison TCC csreq)"
        }
        record(
            "Apple voice processing (hw AEC+NS+AGC) supported on this mic",
            vpSupported,
            vpDetail
        )

        // 40. WebResearch guardrail - missing Brave key returns a clean error,
        // never crashes, never leaks anthropic. Simulated by temporarily
        // DELETING the keychain slot (set("") may not clear, depending on
        // the macOS SecItemUpdate behaviour with empty data). We restore the
        // saved key right after so the run leaves the user's state untouched.
        let savedBrave = KeychainStore.get(.braveApiKey)
        _ = KeychainStore.delete(.braveApiKey)
        let webWas2 = AppState.shared.config.webResearchEnabled
        AppState.shared.config.webResearchEnabled = true
        let noKeyResp = await WebResearch.research(query: "ping", depth: "fast")
        // Restore before asserting so a test failure doesn't strand the key blank.
        if !savedBrave.isEmpty {
            _ = KeychainStore.set(.braveApiKey, savedBrave)
        }
        AppState.shared.config.webResearchEnabled = webWas2
        let noKeyOK = noKeyResp.hasPrefix("error:") && noKeyResp.lowercased().contains("brave")
        record(
            "WebResearch: missing Brave key ⇒ clean error (no crash, no leak)",
            noKeyOK,
            "resp=\(noKeyResp.prefix(100))"
        )

        // 41. AmbientListener.voicedSeconds REJECTS a short-burst signal
        // (keyboard-click simulation: a 50ms loud burst followed by silence).
        // Real speech has ~150-250ms syllables, so any chunk with <0.35s of
        // above-floor RMS is almost certainly transient noise - voicedSeconds
        // returns the measured voiced duration; the transcribe() gate rejects
        // anything < 0.35s. This test exercises the raw helper.
        let sampleRate41 = 16000
        let totalLen41 = sampleRate41 * 2 // 2 seconds
        var clickSignal = [Float](repeating: 0, count: totalLen41)
        // 50ms (800 samples) of 0.3-RMS noise at the start; rest is silence.
        var rngClick = SplitMix64(seed: 0xABCD_1234_5678)
        for k in 0..<800 {
            clickSignal[k] = (rngClick.nextFloat() * 2 - 1) * 0.3
        }
        let clickVoiced = AmbientListener.voicedSeconds(clickSignal)
        record(
            "AmbientListener.voicedSeconds rejects <0.35s transient (keyboard click)",
            clickVoiced < 0.35,
            String(format: "50ms click ⇒ voiced=%.3fs (want < 0.35s)", Double(clickVoiced))
        )

        // 42. AmbientListener.voicedSeconds ACCEPTS a continuous speech-level
        // signal. Simulated by 1.2s of 0.05-RMS noise (voice energy territory),
        // which should measure ≥ 1.0s voiced and clear the 0.35s gate.
        var speechSim = [Float](repeating: 0, count: totalLen41)
        var rngSpeech = SplitMix64(seed: 0xDEAD_BEEF_CAFE)
        let speechSamples = Int(Double(sampleRate41) * 1.2) // 1.2s
        for k in 0..<speechSamples {
            speechSim[k] = (rngSpeech.nextFloat() * 2 - 1) * 0.05
        }
        let speechVoiced = AmbientListener.voicedSeconds(speechSim)
        record(
            "AmbientListener.voicedSeconds accepts 1.2s continuous speech-level signal",
            speechVoiced >= 0.35,
            String(format: "1.2s speech ⇒ voiced=%.3fs (want ≥ 0.35s)", Double(speechVoiced))
        )

        // 43. AmbientListener.passesConfidenceGate: tighter thresholds for
        // short segments (<1.0s) reject the keyboard-click regime where
        // Whisper emits noSpeechProb≈0.4 + avgLogprob≈-0.8, while keeping the
        // same scores valid on a >1.0s segment (where Whisper has real
        // acoustic context). We check four quadrants:
        //   - short + weak scores → REJECTED (the bug-fix case)
        //   - long + weak scores  → ACCEPTED (stays permissive on real speech)
        //   - short + strong scores → ACCEPTED (don't over-reject confident clips)
        //   - short + very-weak scores → REJECTED on old gate too (sanity)
        let shortWeak   = AmbientListener.passesConfidenceGate(noSpeechProb: 0.40, avgLogprob: -0.80, segmentDuration: 0.50)
        let longWeak    = AmbientListener.passesConfidenceGate(noSpeechProb: 0.40, avgLogprob: -0.80, segmentDuration: 2.00)
        let shortStrong = AmbientListener.passesConfidenceGate(noSpeechProb: 0.10, avgLogprob: -0.30, segmentDuration: 0.50)
        let longBad     = AmbientListener.passesConfidenceGate(noSpeechProb: 0.80, avgLogprob: -1.50, segmentDuration: 2.00)
        let gateOK = !shortWeak && longWeak && shortStrong && !longBad
        record(
            "AmbientListener.passesConfidenceGate: short-segment rejection",
            gateOK,
            "shortWeak=\(shortWeak ? "ACCEPT (BUG)" : "reject") longWeak=\(longWeak ? "accept" : "REJECT (regression)") shortStrong=\(shortStrong ? "accept" : "REJECT (regression)") longBad=\(longBad ? "ACCEPT (BUG)" : "reject")"
        )

        // 44 removed: SystemAudioTap was deleted along with the rest of the
        // custom AEC stack - VP-IO replaces it.

        // 45. WakeWord stale-resume regression guard. We can't easily simulate
        // the observer timing deterministically, but we CAN assert that
        // WakeWordListener.shared is a live singleton that accepts start()/stop()
        // idempotently - which is the surface the observer touches. If the
        // singleton ever becomes non-recoverable, this test catches it.
        // The actual stale-flag behaviour change is a 2-line observer fix
        // that's verified by code review; this test just guards the surface.
        let wwBefore = WakeWordListener.shared.isListening
        WakeWordListener.shared.stop()
        let wwAfterStop = WakeWordListener.shared.isListening
        // Don't auto-restart - the user may not have wake-word enabled, and we
        // don't want smoke-test to steal mic from an ambient session. Just
        // assert stop() left the state consistent.
        record(
            "WakeWordListener.shared.stop() leaves isListening=false cleanly",
            !wwAfterStop,
            "before=\(wwBefore) afterStop=\(wwAfterStop)"
        )

        // ---- Meeting capture subsystem ----
        // Tool registration surface
        let meetingToolNames = Set(MeetingTool.claudeTools().map { $0.name })
        let expectedMeetingTools: Set<String> = [
            "start_meeting_capture", "stop_meeting_capture", "list_meetings",
            "get_meeting_transcript", "summarize_meeting", "search_meetings"
        ]
        record(
            "MeetingTool registers all 6 LLM tools",
            expectedMeetingTools.isSubset(of: meetingToolNames),
            "registered: \(meetingToolNames.sorted().joined(separator: ", "))"
        )

        // MeetingAudioMixer: pure-logic sum-and-clip correctness
        let mixA: [Float] = [0.2, -0.2, 0.8,  1.5, -1.5]
        let mixB: [Float] = [0.3,  0.4, 0.3, -0.1,  0.7]
        let mixed = MeetingAudioMixer.sumAndClip(mixA, mixB)
        let mixerOk = abs(mixed[0] - 0.5) < 1e-4
            && abs(mixed[1] - 0.2) < 1e-4
            && abs(mixed[2] - 1.0) < 1e-4   // 1.1 clipped to 1.0
            && abs(mixed[3] - 1.0) < 1e-4   // 1.4 clipped to 1.0
            && abs(mixed[4] - (-0.8)) < 1e-4
        record(
            "MeetingAudioMixer.sumAndClip sums and hard-clips to [-1,1]",
            mixerOk,
            "out[0..4]=\(mixed.prefix(5).map { String(format: "%.3f", $0) }.joined(separator: ", "))"
        )

        // Persistence: meetings dir is created
        let meetingsDir = Persistence.meetingsDir
        let meetingsDirExists = FileManager.default.fileExists(atPath: meetingsDir.path)
        record(
            "Persistence.meetingsDir exists after access",
            meetingsDirExists,
            "dir=\(meetingsDir.path)"
        )

        // ---- Slack integration ----
        let slackToolNames = Set(SlackTool.claudeTools().map { $0.name })
        let expectedSlackTools: Set<String> = [
            "slack_send", "slack_list_channels", "slack_send_workday_log"
        ]
        record(
            "SlackTool registers all 3 LLM tools",
            expectedSlackTools.isSubset(of: slackToolNames),
            "registered: \(slackToolNames.sorted().joined(separator: ", "))"
        )
        // Names-set matches constant
        record(
            "SlackTool.toolNames matches claudeTools() names",
            SlackTool.toolNames == slackToolNames,
            "toolNames=\(SlackTool.toolNames.sorted()) claudeTools=\(slackToolNames.sorted())"
        )
        // Not-connected error path should surface a safe missing-token message
        let slackHadToken = !KeychainStore.get(.slackUserToken).isEmpty
        let savedSlackTok = KeychainStore.get(.slackUserToken)
        _ = KeychainStore.delete(.slackUserToken)
        let slackMissing = await SlackTool.dispatch(name: "slack_list_channels", input: [:])
        record(
            "SlackTool returns friendly error when no token set",
            slackMissing.hasPrefix("error:") && slackMissing.contains("token"),
            "response: \(slackMissing)"
        )
        if slackHadToken { _ = KeychainStore.set(.slackUserToken, savedSlackTok) }
        // Tool names are actually wired into ChatService
        let allTools = Set(ChatService.allTools().map { $0.name })
        record(
            "ChatService.allTools() includes slack tools",
            expectedSlackTools.isSubset(of: allTools),
            "missing: \(expectedSlackTools.subtracting(allTools).sorted())"
        )

        // ---- Notion integration ----
        let notionToolNames = Set(NotionTool.claudeTools().map { $0.name })
        let expectedNotionTools: Set<String> = [
            "notion_push_memory", "notion_push_workday_log",
            "notion_sync_all_logs", "notion_list_databases"
        ]
        record(
            "NotionTool registers all 4 LLM tools",
            expectedNotionTools.isSubset(of: notionToolNames),
            "registered: \(notionToolNames.sorted().joined(separator: ", "))"
        )
        record(
            "NotionTool.toolNames matches claudeTools() names",
            NotionTool.toolNames == notionToolNames,
            "toolNames=\(NotionTool.toolNames.sorted()) claudeTools=\(notionToolNames.sorted())"
        )
        let notionHadToken = !KeychainStore.get(.notionToken).isEmpty
        let savedNotionTok = KeychainStore.get(.notionToken)
        _ = KeychainStore.delete(.notionToken)
        let notionMissing = await NotionTool.dispatch(name: "notion_list_databases", input: [:])
        record(
            "NotionTool returns friendly error when no token set",
            notionMissing.hasPrefix("error:") && notionMissing.contains("token"),
            "response: \(notionMissing)"
        )
        if notionHadToken { _ = KeychainStore.set(.notionToken, savedNotionTok) }
        record(
            "ChatService.allTools() includes notion tools",
            expectedNotionTools.isSubset(of: allTools),
            "missing: \(expectedNotionTools.subtracting(allTools).sorted())"
        )

        // NotionSyncLedger: in-memory set add / check
        let ledger = NotionSyncLedger.shared
        let fakeDay = "2099-12-31"
        let preSynced = ledger.isSynced(dayKey: fakeDay)
        ledger.markSynced(dayKey: fakeDay, pageID: "test-page-xyz")
        let postSynced = ledger.isSynced(dayKey: fakeDay)
        record(
            "NotionSyncLedger.markSynced persists across isSynced calls",
            !preSynced && postSynced,
            "pre=\(preSynced) post=\(postSynced)"
        )

        // Keychain round-trip for new integration keys
        let testSlack = "xoxp-TEST-SMOKE-\(UUID().uuidString.prefix(8))"
        let priorSlack = KeychainStore.get(.slackUserToken)
        _ = KeychainStore.set(.slackUserToken, testSlack)
        let readBack = KeychainStore.get(.slackUserToken)
        _ = KeychainStore.delete(.slackUserToken)
        if !priorSlack.isEmpty { _ = KeychainStore.set(.slackUserToken, priorSlack) }
        record(
            "KeychainStore round-trip for slackUserToken",
            readBack == testSlack,
            "wrote=\(testSlack.prefix(16))… read=\(readBack.prefix(16))…"
        )

        // SlackTool.renderWorkdayLogForSlack smoke: given a minimal log,
        // ensure the rendered text is non-empty, contains the dayKey, and
        // stays under Slack's 40k limit.
        let sampleLog = WorkdayLog(
            id: WorkdayLog.deterministicID(forDayKey: "2099-01-01"),
            dayKey: "2099-01-01",
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 86_400),
            generatedAt: Date(),
            schemaVersion: WorkdayLog.currentSchemaVersion,
            completedTasks: [],
            codeShipped: [],
            conversations: [],
            commitments: CommitmentsBreakdown(made: [], kept: [], stillOpen: []),
            focusStats: FocusStats(
                onTaskMinutes: 0, driftingMinutes: 0, offTaskMinutes: 0,
                perAppMinutes: [:], perProjectMinutes: [:]
            ),
            insights: ["test insight"],
            narrative: "Smoke narrative body.",
            tags: ["test"],
            totalProductiveMinutes: 0
        )
        let rendered = SlackTool.renderWorkdayLogForSlack(sampleLog)
        record(
            "SlackTool.renderWorkdayLogForSlack produces valid output",
            rendered.contains("2099-01-01") && rendered.contains("Smoke narrative") && rendered.count < 40_000,
            "length=\(rendered.count)"
        )

        // Full end-to-end: start capture, pump synthetic speech into the mixer,
        // then stop and check the record has at least one utterance.
        //
        // We don't rely on SCStream/mic being audible in smoke-mode - we
        // push samples directly into MeetingCaptureService's mixer the way
        // SystemAudioCapture would in production. That exercises the
        // chunker, transcriber, MeetingStore write path, and summarizer
        // no-op branch.
        let svcBefore = MeetingCaptureService.shared.isCapturing
        record(
            "MeetingCaptureService starts idle (isCapturing=false)",
            !svcBefore,
            "isCapturing=\(svcBefore)"
        )

        MeetingAppDetector.shared.start()
        lines.append("[INFO] Meeting capture smoke - NOT starting real SCStream; exercising persistence + mixer + store only.")

        // Create a meeting record directly via the store - confirms the
        // Codable round-trip and the index-rebuild path.
        let directRec = MeetingStore.shared.create(
            title: "Smoke Test Meeting",
            sourceApp: "com.gruxai.grux.smoke",
            sourceAppName: "Smoke"
        )
        var populated = directRec
        populated.utterances = [
            MeetingUtterance(t: 0.0, speaker: .mixed, text: "This is a smoke test utterance.", confidence: 0.9),
            MeetingUtterance(t: 3.5, speaker: .mixed, text: "Second synthetic line.", confidence: 0.85)
        ]
        populated.summary = "Smoke test summary placeholder."
        populated.actionItems = ["Verify meeting store roundtrip"]
        populated.endedAt = Date()
        MeetingStore.shared.finalize(populated)

        // Reload + assert
        let reloaded = MeetingStore.shared.loadRecord(id: directRec.id)
        record(
            "MeetingStore create → finalize → loadRecord round-trip",
            reloaded?.utterances.count == 2
                && reloaded?.summary == "Smoke test summary placeholder."
                && reloaded?.actionItems == ["Verify meeting store roundtrip"],
            "loaded=\(reloaded.map { "utt=\($0.utterances.count) summary=\($0.summary ?? "nil")" } ?? "nil")"
        )

        // Index surfaces the new record
        let idx = MeetingStore.shared.list(limit: 50)
        record(
            "MeetingStore.list includes the new record",
            idx.contains { $0.id == directRec.id },
            "index has \(idx.count) rows"
        )

        // Search finds it by title
        let searchHits = MeetingStore.shared.search(query: "smoke", limit: 20)
        record(
            "MeetingStore.search finds 'smoke' by title",
            searchHits.contains { $0.id == directRec.id },
            "search returned \(searchHits.count) rows"
        )

        // MeetingAppDetector display-name lookups cover the whitelist bundles
        let faceTimeName = MeetingAppDetector.displayName(for: "com.apple.FaceTime")
        let zoomName = MeetingAppDetector.displayName(for: "us.zoom.xos")
        let teamsName = MeetingAppDetector.displayName(for: "com.microsoft.teams2")
        record(
            "MeetingAppDetector display-name lookup",
            faceTimeName == "FaceTime" && zoomName == "Zoom" && teamsName == "Microsoft Teams",
            "faceTime=\(faceTimeName ?? "nil") zoom=\(zoomName ?? "nil") teams=\(teamsName ?? "nil")"
        )

        // System-audio support gate reports accurately
        let supported = MeetingCaptureService.shared.isSystemAudioSupported
        record(
            "MeetingCaptureService.isSystemAudioSupported reports accurate",
            supported == true,
            "supported=\(supported)"
        )

        // Tool dispatch: list_meetings returns non-empty now
        let listReply = await MeetingTool.dispatch(name: "list_meetings", input: ["limit": 5])
        record(
            "MeetingTool.dispatch list_meetings includes the new record",
            listReply.contains(directRec.id.uuidString),
            "dispatch reply preview: \(listReply.prefix(140))"
        )

        // Tool dispatch: get_meeting_transcript returns the utterances
        let getReply = await MeetingTool.dispatch(
            name: "get_meeting_transcript",
            input: ["meeting_id": directRec.id.uuidString]
        )
        record(
            "MeetingTool.dispatch get_meeting_transcript returns utterances",
            getReply.contains("Second synthetic line"),
            "dispatch reply preview: \(getReply.prefix(140))"
        )

        // ---- Sub-tasks primitive + Meeting → task import ----
        // Sub-task creation, retrieval, and parent/child filtering.
        let appState = AppState.shared
        let preTopLevel = appState.topLevelActiveTasks.count
        guard let parentTask = appState.addTask(
            "SmokeParent - action items",
            project: "smoke-test",
            priority: .next
        ) else {
            record("addTask returns a FocusTask (sub-task smoke)", false, "addTask returned nil")
            lines.append(String(repeating: "=", count: 60))
            lines.append("RESULT: \(pass) passed, \(fail) failed")
            lines.append("")
            let out = lines.joined(separator: "\n")
            let resultPath = NSHomeDirectory() + "/.grux/smoke-test-results.txt"
            let resultDir = (resultPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: resultDir, withIntermediateDirectories: true)
            try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
            WakeLog.shared.log("smoke test complete - \(pass) pass / \(fail) fail - results at \(resultPath)")
            return
        }
        let sub1 = appState.addSubtask(parentId: parentTask.id, title: "SmokeChild A")
        let sub2 = appState.addSubtask(parentId: parentTask.id, title: "SmokeChild B")
        record(
            "AppState.addSubtask creates two sub-tasks tied to parent",
            sub1?.parentId == parentTask.id && sub2?.parentId == parentTask.id,
            "sub1.parent=\(sub1?.parentId?.uuidString.prefix(8) ?? "nil") sub2.parent=\(sub2?.parentId?.uuidString.prefix(8) ?? "nil")"
        )

        let childrenBefore = appState.subtasks(of: parentTask.id)
        record(
            "subtasks(of:) returns only the two children",
            childrenBefore.count == 2 && childrenBefore.allSatisfy { $0.parentId == parentTask.id },
            "count=\(childrenBefore.count)"
        )

        let topLevelAfter = appState.topLevelActiveTasks.count
        record(
            "topLevelActiveTasks excludes sub-tasks",
            topLevelAfter == preTopLevel + 1,    // parent only, not children
            "before=\(preTopLevel) after=\(topLevelAfter) (+\(topLevelAfter - preTopLevel) expected 1)"
        )

        // Codable round-trip: persist + reload tasks.json, verify parentId survives
        let snapshot = appState.tasks
        let taskEnc = JSONEncoder(); taskEnc.dateEncodingStrategy = .iso8601
        let taskDec = JSONDecoder(); taskDec.dateDecodingStrategy = .iso8601
        let encoded = (try? taskEnc.encode(snapshot)) ?? Data()
        let decoded = (try? taskDec.decode([FocusTask].self, from: encoded)) ?? []
        let roundTrippedSub = decoded.first { $0.id == sub1?.id }
        record(
            "FocusTask parentId survives Codable round-trip",
            roundTrippedSub?.parentId == parentTask.id,
            "original.parent=\(sub1?.parentId?.uuidString.prefix(8) ?? "nil") roundtripped.parent=\(roundTrippedSub?.parentId?.uuidString.prefix(8) ?? "nil")"
        )

        // Legacy JSON (no parentId key) must still decode as top-level.
        let legacyJSON = """
        [{
          "id": "E3E3E3E3-1111-2222-3333-444444444444",
          "title": "Legacy task - no parentId key",
          "project": "legacy",
          "priority": "next",
          "createdAt": "2025-01-01T00:00:00Z",
          "notes": "",
          "completed": false
        }]
        """
        let legacyDecoded = (try? taskDec.decode([FocusTask].self, from: Data(legacyJSON.utf8))) ?? []
        record(
            "Legacy tasks.json (no parentId field) still decodes as top-level",
            legacyDecoded.count == 1 && legacyDecoded[0].parentId == nil && legacyDecoded[0].title == "Legacy task - no parentId key",
            "decoded=\(legacyDecoded.count) parent=\(legacyDecoded.first?.parentId?.uuidString ?? "nil")"
        )

        // Promote: sub-task → top-level
        if let subId = sub1?.id {
            appState.promoteSubtask(subId)
            let promoted = appState.tasks.first { $0.id == subId }
            record(
                "promoteSubtask clears parentId so the row lifts to top-level",
                promoted?.parentId == nil,
                "promoted.parent=\(promoted?.parentId?.uuidString ?? "nil")"
            )
        }

        // Cascade delete: deleting the parent removes remaining children.
        let sub2Id = sub2?.id
        appState.deleteTask(parentTask.id)
        let parentGone = !appState.tasks.contains { $0.id == parentTask.id }
        let childGone = sub2Id.map { id in !appState.tasks.contains { $0.id == id } } ?? false
        record(
            "deleteTask cascades to sub-tasks (parent + remaining child both removed)",
            parentGone && childGone,
            "parentGone=\(parentGone) childGone=\(childGone)"
        )

        // Clean up the promoted stray so we don't litter the user's task list.
        if let subId = sub1?.id {
            appState.deleteTask(subId)
        }

        // Meeting → "import all as main task" end-to-end.
        //
        // Build a fresh record, then simulate the MeetingsView.importAllAsParent
        // flow directly: create a parent + N sub-tasks from its action items.
        var importRec = MeetingStore.shared.create(
            title: "Smoke Import Meeting",
            sourceApp: "com.gruxai.grux.smoke",
            sourceAppName: "Smoke"
        )
        importRec.actionItems = [
            "Send follow-up email to alpha group",
            "Book room for the Tuesday sync",
            "Ping Sarah about the pricing deck"
        ]
        importRec.endedAt = Date()
        MeetingStore.shared.finalize(importRec)

        let preImportCount = appState.tasks.count
        guard let importParent = appState.addTask(
            "Action items from \(importRec.displayTitle)",
            project: importRec.displayTitle,
            priority: .next
        ) else {
            record("Meeting → import-all-as-parent flow", false, "parent addTask failed")
            return
        }
        var importedCount = 0
        for item in importRec.actionItems {
            if appState.addSubtask(parentId: importParent.id, title: item) != nil {
                importedCount += 1
            }
        }
        record(
            "Meeting importAllAsParent produces 1 parent + N sub-tasks",
            importedCount == importRec.actionItems.count
                && appState.subtasks(of: importParent.id).count == importRec.actionItems.count
                && appState.tasks.count == preImportCount + 1 + importRec.actionItems.count,
            "imported=\(importedCount) subsVisible=\(appState.subtasks(of: importParent.id).count) tasksDelta=\(appState.tasks.count - preImportCount)"
        )

        // Cleanup
        appState.deleteTask(importParent.id)

        // ---- Commands V2 engine ----
        // 100. Engine loads, builtins registered, persistence dir exists.
        CommandV2Engine.shared.load()
        let v2Defs = CommandV2Engine.shared.definitions
        let hasSmoke = v2Defs.contains(where: { $0.id == "smoke-hello-world" })
        let hasShip = v2Defs.contains(where: { $0.id == "ship-ios-app" })
        let hasStatus = v2Defs.contains(where: { $0.id == "check-asc-status" })
        record(
            "CommandV2Engine.load() registers all 3 builtin definitions",
            hasSmoke && hasShip && hasStatus,
            "defs=\(v2Defs.map(\.id).sorted())"
        )

        // 101. Trigger matching: "ship the aurora" resolves to ship-ios-app
        // with project=aurora.
        let triggerHit = CommandV2Engine.shared.matchTrigger("ship the aurora")
        let triggerDefMatches = triggerHit?.0.id == "ship-ios-app"
        let triggerProjectMatches = triggerHit?.1["project"]?.stringValue == "aurora"
        record(
            "CommandV2Engine.matchTrigger resolves 'ship the aurora' to ship-ios-app",
            triggerDefMatches && triggerProjectMatches,
            "def=\(triggerHit?.0.id ?? "nil") project=\(triggerHit?.1["project"]?.stringValue ?? "nil")"
        )

        // 102. End-to-end: smoke-hello-world runs to completion, mutates state,
        // takes the true branch, and lands the success log. We watch the engine's
        // active runs list - when our run drops out, it's done. Persistent JSON
        // for the run is then read off disk to assert the final state.
        let v2RunsDir = Persistence.supportDir.appendingPathComponent("v2-runs")
        try? FileManager.default.createDirectory(at: v2RunsDir, withIntermediateDirectories: true)
        // Snapshot existing run files so we can identify the one we're starting.
        let preFiles: Set<String> = (try? FileManager.default.contentsOfDirectory(atPath: v2RunsDir.path).filter { $0.hasSuffix(".json") }).map { Set($0) } ?? Set()
        let startResult = await CommandV2Engine.shared.start(definitionId: "smoke-hello-world")
        var startedId: UUID? = nil
        if case .success(let id) = startResult { startedId = id }
        // Wait up to 25 seconds for the run to leave the active list (it speaks,
        // so timing depends on TTS latency - generous timeout).
        var waitedMs = 0
        let pollMs = 200
        let timeoutMs = 25_000
        while waitedMs < timeoutMs {
            let stillActive = startedId.map { id in CommandV2Engine.shared.activeRuns.contains(where: { $0.id == id }) } ?? true
            if !stillActive { break }
            try? await Task.sleep(nanoseconds: UInt64(pollMs * 1_000_000))
            waitedMs += pollMs
        }
        let stillActiveAtEnd = startedId.map { id in CommandV2Engine.shared.activeRuns.contains(where: { $0.id == id }) } ?? true
        // Reload the run from disk and assert outcome.
        var diskRun: CommandV2Run? = nil
        if let id = startedId {
            let url = v2RunsDir.appendingPathComponent("\(id.uuidString).json")
            if let data = try? Data(contentsOf: url) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                diskRun = try? dec.decode(CommandV2Run.self, from: data)
            }
        }
        let didComplete = diskRun?.status == .completed
        let tealStashed = diskRun?.state["color"]?.stringValue == "teal"
        let echoMatched = diskRun?.state["last_echo"]?.stringValue == "smoke world says hi"
        let tookTrueBranch = diskRun?.phaseHistory.contains(where: { $0.phaseId == "celebrate" }) ?? false
        let didNotTakeFalseBranch = !(diskRun?.phaseHistory.contains(where: { $0.phaseId == "sad" }) ?? false)
        record(
            "CommandV2 E2E: smoke-hello-world runs, mutates state, branches true",
            !stillActiveAtEnd && didComplete && tealStashed && echoMatched && tookTrueBranch && didNotTakeFalseBranch,
            "completed=\(didComplete) teal=\(tealStashed) echo=\(echoMatched) celebrated=\(tookTrueBranch) didntSad=\(didNotTakeFalseBranch) waited=\(waitedMs)ms"
        )

        // 103. Approval gate: a run with userApprovalRequired pauses; engine.resume() advances it.
        // Build a one-shot definition with an approval gate in phase 1 then a setState in phase 2.
        let gateDef = CommandV2Definition(
            id: "smoke-approval-gate",
            displayName: "smoke: approval gate",
            voiceTriggers: [],
            description: "Pauses for approval, then writes state to prove resume worked.",
            category: .system,
            parameters: [],
            phases: [
                .init(
                    id: "ask",
                    displayName: "Ask",
                    action: .userApprovalGate(prompt: "Approve to continue.", expectedReplies: ["go"])
                ),
                .init(
                    id: "stash",
                    displayName: "Stash",
                    action: .setState(key: "approved_marker", valueExpr: .literal(.string("yes")))
                )
            ]
        )
        CommandV2Engine.shared.register(gateDef)
        let gateStart = await CommandV2Engine.shared.start(definitionId: "smoke-approval-gate")
        var gateRunId: UUID? = nil
        if case .success(let id) = gateStart { gateRunId = id }
        // Wait for the run to enter waitingForApproval (TTS fires before the pause).
        var waited2 = 0
        var pausedRun: CommandV2Run? = nil
        while waited2 < 8000 {
            if let id = gateRunId, let r = CommandV2Engine.shared.run(id: id), r.status == .waitingForApproval {
                pausedRun = r; break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited2 += 200
        }
        let didPause = pausedRun != nil
        // Resume.
        if let id = gateRunId { await CommandV2Engine.shared.resume(id, userReply: "go (smoke)") }
        // Wait for completion.
        var waited3 = 0
        while waited3 < 5000 {
            if let id = gateRunId, !CommandV2Engine.shared.activeRuns.contains(where: { $0.id == id }) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited3 += 200
        }
        var finalGateRun: CommandV2Run? = nil
        if let id = gateRunId {
            let url = v2RunsDir.appendingPathComponent("\(id.uuidString).json")
            if let data = try? Data(contentsOf: url) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                finalGateRun = try? dec.decode(CommandV2Run.self, from: data)
            }
        }
        let resumed = finalGateRun?.status == .completed
        let stateWritten = finalGateRun?.state["approved_marker"]?.stringValue == "yes"
        record(
            "CommandV2 approval gate pauses, then resume() advances",
            didPause && resumed && stateWritten,
            "paused=\(didPause) resumed=\(resumed) state=\(stateWritten) waitedToPause=\(waited2)ms waitedToFinish=\(waited3)ms"
        )

        // 104. Persistence: the on-disk JSON for our completed smoke run is decodable
        // into the same shape (Codable round-trip survives the engine's actual writes).
        var roundTripOK104 = false
        if let original = diskRun {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
            if let bytes = try? enc.encode(original),
               let decoded = try? { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }().decode(CommandV2Run.self, from: bytes) {
                roundTripOK104 = decoded.id == original.id
                    && decoded.state["color"]?.stringValue == "teal"
                    && decoded.phaseHistory.count == original.phaseHistory.count
            }
        }
        record(
            "CommandV2Run Codable round-trip preserves id, state, and phase history",
            roundTripOK104,
            "ok=\(roundTripOK104)"
        )

        // 105. Cleanup: delete v2-run files that didn't exist before we started so
        // smoke runs don't leak into the live UI on the next launch.
        if let postFiles = try? FileManager.default.contentsOfDirectory(atPath: v2RunsDir.path) {
            for f in postFiles where f.hasSuffix(".json") && !preFiles.contains(f) {
                try? FileManager.default.removeItem(at: v2RunsDir.appendingPathComponent(f))
            }
        }

        lines.append(String(repeating: "=", count: 60))
        lines.append("RESULT: \(pass) passed, \(fail) failed")
        lines.append("")

        let out = lines.joined(separator: "\n")
        let resultPath = NSHomeDirectory() + "/.grux/smoke-test-results.txt"
        // Ensure the directory exists. `~/.grux` is created by the app at
        // runtime normally; for CLI --smoke-test we can't assume it.
        let resultDir = (resultPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: resultDir, withIntermediateDirectories: true)
        try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
        WakeLog.shared.log("smoke test complete - \(pass) pass / \(fail) fail - results at \(resultPath)")
    }
}
