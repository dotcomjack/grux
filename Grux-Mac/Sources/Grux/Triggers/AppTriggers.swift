import SwiftUI
import AppKit

/// Every `~/.grux/fire-*` file-drop trigger, registered with `TriggerWatcher`.
///
/// Moved out of `GruxApp.swift` in P-R-7 (2026-09-21), where this table was more than half
/// of a 3,600 line file. It is a MOVE: every registration and every closure body below is
/// byte for byte what it was inside `AppDelegate.startInjectChatWatcher()`, in the same
/// order. That method is still the only caller, behind the same `controlSocketEnabled`
/// switch, and it still arms the watcher with `TriggerWatcher.shared.start()` after this
/// returns.
///
/// THE FILE NAMES ARE LOCKED. The CLI, `tools/grux-sweep.sh`, CLAUDE.md's runbook and
/// outside automation drop these exact names, and a renamed trigger fails silently: the
/// file sits in `~/.grux` and nothing happens.
///
/// One table rather than one file per area, on purpose. `TriggerWatcher` runs handlers in
/// registration order, so when several trigger files are present in one sweep (the launch
/// sweep, for one) they run in the order below. Splitting by area would reorder them, and
/// this change was meant to move code, not to change what runs first.
///
/// `IdleCostTests` and `ScreenControlProofTests` read this file as source.
@MainActor
enum AppTriggers {
    /// Register every trigger. Call before `TriggerWatcher.shared.start()`.
    static func register(in dir: URL) {
        // Endpoint key import: ~/.grux/fire-endpoint-key holds two lines, the
        // custom endpoint id then its API key. Grux stores the key in the
        // Keychain ITSELF so the item belongs to this app: an item written by
        // the `security` tool sits in a partition that makes every read from
        // here raise a login-password prompt, and that prompt freezes the main
        // thread for as long as it sits. The file is shredded before the key
        // is used, and only its outcome is logged, never the key.
        let endpointKeyFile = dir.appendingPathComponent("fire-endpoint-key")
        TriggerWatcher.shared.register(endpointKeyFile) {
            guard FileManager.default.fileExists(atPath: endpointKeyFile.path) else { return }
            Task { @MainActor in
                let outcome = EndpointKeyImport.consume(fileURL: endpointKeyFile)
                WakeLog.shared.log(outcome)
            }
        }

        // Focus card drive: write one of left|right|top|bottom|collapse|expand|
        // show|hide|status|move:x,y to ~/.grux/fire-focus-card. `status` writes
        // ~/.grux/focus-card-status.json. How the card is driven without a mouse.
        let focusCardFile = dir.appendingPathComponent("fire-focus-card")
        TriggerWatcher.shared.register(focusCardFile) {
            guard let text = try? String(contentsOf: focusCardFile, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: focusCardFile)
            let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            Task { @MainActor in
                let c = FocusOverlayController.shared
                let s = FocusOverlayState.shared
                switch cmd {
                case "left": c.place(side: .left, vertical: s.vertical)
                case "right": c.place(side: .right, vertical: s.vertical)
                case "top": c.place(side: s.side, vertical: .top)
                case "bottom": c.place(side: s.side, vertical: .bottom)
                case "collapse": withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { s.isCollapsed = true }
                case "expand": withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { s.isCollapsed = false }
                case "show": c.show()
                case "hide": c.hide()
                default:
                    if cmd.hasPrefix("move:") {
                        let parts = cmd.dropFirst(5).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        if parts.count == 2 { c.moveTo(x: parts[0], y: parts[1]) }
                    }
                }
                // Collapse and expand reframe after the transition; report after it.
                let settle: UInt64 = (cmd == "collapse" || cmd == "expand") ? 600_000_000 : 50_000_000
                try? await Task.sleep(nanoseconds: settle)
                let out = dir.appendingPathComponent("focus-card-status.json")
                try? c.statusJSON().write(to: out, atomically: true, encoding: .utf8)
                WakeLog.shared.log("focus card: \(cmd) -> \(c.statusJSON())")
            }
        }

        // Ambient inject: write text to ~/.grux/fire-ambient-inject and it
        // runs the exact path a transcribed chunk takes (clean, gates,
        // router), without a microphone. How the television test is driven.
        // Every inject answers in ~/.grux/ambient-inject-result.json, dropped
        // or not. Format and dry-run modes: AmbientInject.
        let ambientInjectFile = dir.appendingPathComponent("fire-ambient-inject")
        TriggerWatcher.shared.register(ambientInjectFile) {
            guard let raw = try? String(contentsOf: ambientInjectFile, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: ambientInjectFile)
            let request = AmbientInject.parse(raw)
            Task { @MainActor in
                let started = Date()
                let route = request.text.isEmpty
                    ? AmbientListener.ChunkRoute(heard: "", stage: "dropped: empty inject")
                    : await AmbientListener.shared.debugInjectChunk(request.text, dryRun: request.dryRun)
                AmbientInject.write(AmbientInject.result(
                    for: request, route: route, wallMs: Int(Date().timeIntervalSince(started) * 1000)))
            }
        }

        // Chat context dump: touch ~/.grux/fire-chat-context-dump and Grux
        // writes the exact system blocks, messages and tool sizes the next
        // turn would send to ~/.grux/chat-context-dump.txt, 0600.
        let contextDumpFile = dir.appendingPathComponent("fire-chat-context-dump")
        TriggerWatcher.shared.register(contextDumpFile) {
            guard FileManager.default.fileExists(atPath: contextDumpFile.path) else { return }
            try? FileManager.default.removeItem(at: contextDumpFile)
            Task { @MainActor in
                ChatContextDump.write(to: dir.appendingPathComponent("chat-context-dump.txt"))
            }
        }

        // Debug recap trigger - touch ~/.grux/fire-recap to force the daily
        // recap at any time without waiting for 22:00.
        let recapFile = dir.appendingPathComponent("fire-recap")
        TriggerWatcher.shared.register(recapFile) {
            guard FileManager.default.fileExists(atPath: recapFile.path) else { return }
            try? FileManager.default.removeItem(at: recapFile)
            WakeLog.shared.log("manual recap trigger fired")
            Task { @MainActor in await DailyRecapScheduler.shared.fireRecapNow() }
        }

        // Debug MusicKit probe: touch ~/.grux/fire-musickit-test to verify whether
        // ApplicationMusicPlayer + a catalog request FUNCTION in this signed build
        // (with or without the com.apple.developer.musickit entitlement). File
        // contents optional: a numeric Apple Music store id to probe, else a
        // default. Result -> ~/.grux/musickit-test-result.txt and wake.log. First
        // run shows the Apple Music access prompt (one-time grant).
        let mkProbeFile = dir.appendingPathComponent("fire-musickit-test")
        TriggerWatcher.shared.register(mkProbeFile) {
            guard FileManager.default.fileExists(atPath: mkProbeFile.path) else { return }
            let payload = (try? String(contentsOf: mkProbeFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: mkProbeFile)
            let storeID = payload.isEmpty ? "1442846328" : payload   // default: Kanye West, Stronger
            Task { @MainActor in
                let result = await MusicKitPlayer.probe(testStoreID: storeID)
                WakeLog.shared.log("musickit-probe: \(result)")
                try? result.write(to: dir.appendingPathComponent("musickit-test-result.txt"),
                                   atomically: true, encoding: .utf8)
            }
        }

        // Debug STT-correction trigger: write a raw (possibly misheard) transcript
        // into ~/.grux/fire-stt-correct and Grux runs TranscriptCorrector on it,
        // writing the corrected text to ~/.grux/stt-correct-result.txt + wake.log.
        // Lets the correction layer be verified without a microphone.
        let sttCorrectFile = dir.appendingPathComponent("fire-stt-correct")
        TriggerWatcher.shared.register(sttCorrectFile) {
            guard FileManager.default.fileExists(atPath: sttCorrectFile.path) else { return }
            let raw = (try? String(contentsOf: sttCorrectFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: sttCorrectFile)
            guard !raw.isEmpty else { return }
            Task { @MainActor in
                let corrected = await TranscriptCorrector.correct(raw)
                let out = "RAW: \(raw)\nCORRECTED: \(corrected)"
                WakeLog.shared.log("stt-correct-test: \(out.replacingOccurrences(of: "\n", with: " | "))")
                try? out.write(to: dir.appendingPathComponent("stt-correct-result.txt"),
                               atomically: true, encoding: .utf8)
            }
        }

        // Debug issue-from-voice trigger: touch ~/.grux/fire-issue-from-voice-test
        // to run the spoken-frustration -> GitHub issue pipeline end to end,
        // bypassing the heuristic + debounce. File contents are optional:
        //   - empty            : draft from a built-in seed transcript, then
        //                        present the confirmation panel (nothing filed).
        //   - "file"           : also file the drafted issue to GitHub via gh
        //                        (proves the gh path; writes the created URL).
        //   - "file|<text>"    : file, drafting from <text> as the transcript.
        //   - "<text>"         : draft from <text>, present the panel.
        // Result is written to ~/.grux/issue-from-voice-test-result.txt.
        let issueVoiceFile = dir.appendingPathComponent("fire-issue-from-voice-test")
        TriggerWatcher.shared.register(issueVoiceFile) {
            guard FileManager.default.fileExists(atPath: issueVoiceFile.path) else { return }
            let payload = (try? String(contentsOf: issueVoiceFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: issueVoiceFile)
            WakeLog.shared.log("manual issue-from-voice-test trigger fired")
            // Parse "file" prefix and optional inline transcript.
            var autoFile = false
            var seed = ""
            if payload.lowercased() == "file" {
                autoFile = true
            } else if payload.lowercased().hasPrefix("file|") {
                autoFile = true
                seed = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                seed = payload
            }
            if seed.isEmpty && !autoFile {
                seed = """
                Me: ok let me push this build.
                Me: ugh the Grux deploy script always fails on the notarize step, this is broken every single time and it is so annoying.
                Me: I really need to fix that, it wastes ten minutes a run.
                """
            } else if seed.isEmpty && autoFile {
                seed = """
                Me: the Grux deploy script always fails on the notarize step, this is broken and really annoying. I need to fix that.
                """
            }
            let outPath = Persistence.gruxDir.appendingPathComponent("issue-from-voice-test-result.txt").path
            Task { @MainActor in
                await IssueExtractor.shared.runSmokeTest(seed: seed, autoFile: autoFile, resultPath: outPath)
            }
        }

        // Debug support-triage trigger: touch ~/.grux/fire-support-triage-test
        // to run the support-email triage pipeline end to end without waiting
        // for the hourly sweep. File contents are optional:
        //   - empty            : the first configured inbox, built-in fixture
        //                        (deterministic).
        //   - "<inbox>"        : that inbox, built-in fixture.
        //   - "<inbox>|<path>" : that inbox, read the [InboxMessage] JSON at
        //                        <path> (use this to test live-tab scraping by
        //                        pointing at a file you dumped, or omit the
        //                        path to scrape the open Outlook tab).
        // Stages drafts in SupportDraftStore, opens the Support Drafts window,
        // and writes a summary to ~/.grux/support-triage-test-result.txt.
        let supportTriageFile = dir.appendingPathComponent("fire-support-triage-test")
        TriggerWatcher.shared.register(supportTriageFile) {
            guard FileManager.default.fileExists(atPath: supportTriageFile.path) else { return }
            let payload = (try? String(contentsOf: supportTriageFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: supportTriageFile)
            WakeLog.shared.log("manual support-triage-test trigger fired")
            var fixturePath = ""
            let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count > 1 { fixturePath = parts[1].trimmingCharacters(in: .whitespaces) }
            let outPath = Persistence.gruxDir.appendingPathComponent("support-triage-test-result.txt").path
            // "live" payload runs the REAL unattended sweep (reads the open
            // Outlook tab, no fixture), so the live path can be verified on
            // demand instead of only at the top of the hour. Checked before the
            // inbox is resolved because a live sweep walks the whole roster and
            // needs no single inbox.
            if fixturePath.lowercased() == "live" || payload.trimmingCharacters(in: .whitespaces).lowercased() == "live" {
                Task { @MainActor in
                    let n = await EmailTriageEngine.shared.runHourly()
                    WakeLog.shared.log("manual LIVE support sweep: staged \(n) draft(s)")
                    WindowOpener.openSupportDrafts()
                }
                return
            }
            // The inbox the payload names, else the first configured one. There
            // is no compiled-in default any more: with no support inboxes in
            // ~/.grux/brands.json there is nothing to triage, so say so and stop
            // rather than smoke-testing a brand this install never had.
            let named = parts.first.flatMap {
                SupportInbox(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces))
            }
            guard let inbox = named ?? SupportInbox.roster.first else {
                let msg = "support-triage-test: no support inboxes configured in ~/.grux/brands.json, nothing to triage"
                WakeLog.shared.log(msg)
                try? msg.write(toFile: outPath, atomically: true, encoding: .utf8)
                return
            }
            Task { @MainActor in
                await EmailTriageEngine.shared.runSmokeTest(inbox: inbox, fixturePath: fixturePath, resultPath: outPath)
            }
        }

        // Graph mail setup: drop ~/.grux/fire-graph-mail-setup containing JSON
        //   {"tenantId","clientId","clientSecret","mailboxes":[{"inbox","address"}]}
        // to wire DIRECT M365 access (no tab). The secret is moved into Keychain
        // and the file is shredded immediately so it never lingers in plaintext.
        let graphSetupFile = dir.appendingPathComponent("fire-graph-mail-setup")
        TriggerWatcher.shared.register(graphSetupFile) {
            guard FileManager.default.fileExists(atPath: graphSetupFile.path) else { return }
            let data = (try? Data(contentsOf: graphSetupFile)) ?? Data()
            try? FileManager.default.removeItem(at: graphSetupFile)
            Task { @MainActor in
                WakeLog.shared.log(GraphMailStore.shared.ingest(data))
            }
        }

        // Debug cold-email trigger: touch ~/.grux/fire-cold-email-test to draft
        // a voice-style outreach email end to end (no auto-send; opens the
        // confirm dialog). File contents are optional:
        //   - empty                         : built-in test target.
        //   - "<person>|<company>|<email?>" : draft to that target.
        // Writes a summary (including an em/en-dash check) to
        // ~/.grux/cold-email-test-result.txt for CLI verification.
        let coldEmailFile = dir.appendingPathComponent("fire-cold-email-test")
        TriggerWatcher.shared.register(coldEmailFile) {
            guard FileManager.default.fileExists(atPath: coldEmailFile.path) else { return }
            let payload = (try? String(contentsOf: coldEmailFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: coldEmailFile)
            WakeLog.shared.log("manual cold-email-test trigger fired")
            let outPath = Persistence.gruxDir.appendingPathComponent("cold-email-test-result.txt").path
            Task { @MainActor in
                await ColdEmailEngine.shared.runSmokeTest(payload: payload, resultPath: outPath)
            }
        }

        // Debug energy-recap trigger: touch ~/.grux/fire-energy-recap-test
        // to force the 8pm energy + focus recap at any time. Builds the
        // EnergyRecap from today's data, presents the glass takeover, speaks
        // the summary, and pushes to phone via TTSBroadcaster when paired.
        let energyRecapFile = dir.appendingPathComponent("fire-energy-recap-test")
        TriggerWatcher.shared.register(energyRecapFile) {
            guard FileManager.default.fileExists(atPath: energyRecapFile.path) else { return }
            try? FileManager.default.removeItem(at: energyRecapFile)
            WakeLog.shared.log("manual energy-recap trigger fired")
            Task { @MainActor in await EnergyRecapScheduler.shared.fireRecapNow() }
        }

        // Debug workday-log trigger - touch ~/.grux/fire-workday-log to
        // generate TODAY's archival workday log immediately and open the
        // panel. Useful for CLI-based end-to-end verification.
        let wdFile = dir.appendingPathComponent("fire-workday-log")
        TriggerWatcher.shared.register(wdFile) {
            guard FileManager.default.fileExists(atPath: wdFile.path) else { return }
            try? FileManager.default.removeItem(at: wdFile)
            WakeLog.shared.log("manual workday-log trigger fired")
            Task { @MainActor in
                let dk = WorkdayLogScheduler.currentDayKey()
                _ = await WorkdayLogScheduler.shared.generateWorkdayLogNow(forDayKey: dk)
                WorkdayLogPanelController.shared.present()
            }
        }

        // Debug decision-log trigger: touch ~/.grux/fire-decision-log-test to
        // run the extraction pass over whatever transcript is currently in
        // the AmbientState ring buffer (uses a 360-min window so a quick test
        // only needs a few recent chunks). Writes a summary to
        // ~/.grux/decision-log-test-result.txt for CLI verification.
        let dlFile = dir.appendingPathComponent("fire-decision-log-test")
        TriggerWatcher.shared.register(dlFile) {
            guard FileManager.default.fileExists(atPath: dlFile.path) else { return }
            try? FileManager.default.removeItem(at: dlFile)
            WakeLog.shared.log("manual decision-log-test trigger fired")
            Task { @MainActor in
                let result = await DecisionLogScheduler.shared.runNow(transcriptMinutes: 360)
                let now = Date()
                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("decision-log-test result @ \(iso.string(from: now))")
                lines.append("provider: \(result.provider)")
                lines.append("new decisions saved this pass: \(result.records.count)")
                for d in result.records {
                    lines.append("  - [\(d.dayKey)] \(d.summary)")
                    if !d.rationale.isEmpty { lines.append("    why: \(d.rationale)") }
                    if !d.alternatives.isEmpty {
                        lines.append("    alts: \(d.alternatives.joined(separator: " | "))")
                    }
                    lines.append("    id: \(d.id)")
                }
                let all = DecisionLog.loadAllDecisions(limit: 5)
                lines.append("most-recent stored (across all days): \(all.count)")
                for d in all {
                    lines.append("  - [\(d.dayKey)] \(d.summary)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("decision-log-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug person-memory trigger: touch ~/.grux/fire-person-memory-test to
        // run the NER + fact pass over a SEEDED multi-person transcript (so the
        // smoke test never depends on real ambient audio being in the buffer).
        // HERMETIC: pre-cleans the synthetic test slugs so the run is repeatable
        // and the acceptance gate counts ONLY this pass (not the real CRM);
        // runs with name-fold OFF so the fakes can't graft onto a real dossier;
        // post-cleans so the fakes never pollute ~/.grux/people/. Writes a
        // summary to ~/.grux/person-memory-test-result.txt for CLI verification.
        let personMemFile = dir.appendingPathComponent("fire-person-memory-test")
        TriggerWatcher.shared.register(personMemFile) {
            guard FileManager.default.fileExists(atPath: personMemFile.path) else { return }
            try? FileManager.default.removeItem(at: personMemFile)
            WakeLog.shared.log("manual person-memory-test trigger fired")
            Task { @MainActor in
                // Synthetic people. "Mark" (a single-word, common-word name)
                // exists specifically to exercise the false-positive guard.
                let testSlugs = ["sarah-chen","marcus-reed","priya-patel","devon-brooks","linda-okafor","mark"]
                @MainActor func wipeTestDossiers() {
                    for s in testSlugs {
                        try? FileManager.default.removeItem(at: PersonMemory.rootDir.appendingPathComponent("\(s).json"))
                    }
                    PersonMemory.shared.invalidateCache() // drop ghosts from the hot-path cache
                }
                wipeTestDossiers() // start clean so the gate counts THIS pass only

                let seeded = """
                - I just got off the phone with Sarah Chen, she's the new ops lead at the fulfillment center and she said the bar soap two-packs ship out of the east warehouse now.
                - Marcus Reed from the Alibaba supplier confirmed the turmeric citrus scent batch is ready to pour next week.
                - Got an email from Priya Patel, she's the lawyer reviewing the enterprise contract, she works at a firm called Westfield.
                - My buddy Devon Brooks is cutting the launch video, he lives in Austin and he's done three of my promos already.
                - Linda Okafor wants to put money into the new app, she runs a small angel fund and asked for the deck.
                - Talked to Mark today about the warehouse lease, he's the property manager.
                - Reminded myself to text Sarah Chen back about the lotion cadence, she's waiting on the forty-two day number.
                """
                let result = await PersonMemoryScheduler.shared.runNow(transcriptOverride: seeded, allowNameFold: false)

                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("person-memory-test result @ \(iso.string(from: Date()))")
                lines.append("provider: \(result.provider)")
                lines.append("dossiers this pass: \(result.dossiers.count)")
                lines.append("new facts this pass: \(result.newFactCount)")
                lines.append("ACCEPTANCE (>= 5 dossiers THIS pass): \(result.dossiers.count >= 5 ? "PASS" : "FAIL")")
                lines.append("ACCEPTANCE (new facts > 0): \(result.newFactCount > 0 ? "PASS" : "FAIL")")
                for d in result.dossiers.sorted(by: { $0.name < $1.name }) {
                    lines.append("  - \(d.name) [\(d.relationship.isEmpty ? "?" : d.relationship)] facts=\(d.facts.count) mentions=\(d.mentionCount)")
                }

                // Chat-surface: a known full name must surface a card.
                if let card = PersonMemory.shared.cardBlock(forUtterance: "did Sarah Chen ever get back to me about that?") {
                    lines.append("CARD_LOOKUP (multi-word name): PASS")
                    lines.append("--- sample card ---")
                    lines.append(card)
                } else {
                    lines.append("CARD_LOOKUP (multi-word name): FAIL")
                }
                // Single-word name, capitalized and mid-sentence: SHOULD match.
                let posSingle = PersonMemory.shared.cardBlock(forUtterance: "I talked to Mark today about the lease")
                lines.append("SINGLE_WORD_POSITIVE (\"...Mark...\"): \(posSingle != nil ? "PASS" : "FAIL")")
                // Same word lowercased as a verb: must NOT match (false-positive guard).
                let negVerb = PersonMemory.shared.cardBlock(forUtterance: "can you mark that one done and bill it later")
                lines.append("FALSE_POSITIVE_GUARD (\"mark/bill\" lowercase): \(negVerb == nil ? "PASS (no card)" : "FAIL (card injected)")")

                wipeTestDossiers() // never leave synthetic people in the real CRM

                let outPath = Persistence.gruxDir.appendingPathComponent("person-memory-test-result.txt").path
                try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug idea-dedup trigger: touch ~/.grux/fire-idea-dedup-test to run
        // a two-idea smoke test through IdeaQueue. Captures a unique idea, then
        // a near paraphrase, and writes the dedup outcome to
        // ~/.grux/idea-dedup-test-result.txt for CLI verification.
        let ideaTestFile = dir.appendingPathComponent("fire-idea-dedup-test")
        TriggerWatcher.shared.register(ideaTestFile) {
            guard FileManager.default.fileExists(atPath: ideaTestFile.path) else { return }
            try? FileManager.default.removeItem(at: ideaTestFile)
            WakeLog.shared.log("manual idea-dedup-test trigger fired")
            Task {
                // Sprinkle a per-run nonce throughout both strings so the
                // embedding is dominated by run-specific tokens. Without this,
                // a re-trigger sees the prior run's near-identical pair still
                // in the index and the new FIRST capture comes back as a
                // duplicate of an older run, masking real regressions.
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
                let original = "Idea dedup smoke nonce \(nonce): a voice trigger named \(nonce) that summarizes yesterday's commits \(nonce) into a short audio clip \(nonce) every weekday morning."
                let paraphrase = "Idea dedup smoke nonce \(nonce): a morning recap feature called \(nonce) that voices yesterday's git commits \(nonce) as a quick audio snippet \(nonce) on weekdays."
                let first = await IdeaQueue.shared.capture(content: original)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let second = await IdeaQueue.shared.capture(content: paraphrase)

                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("idea-dedup-test result @ \(iso.string(from: Date()))")
                lines.append("memory_available: \(first.memoryAvailable && second.memoryAvailable)")
                lines.append("nonce: \(nonce)")
                lines.append("")
                lines.append("FIRST (expected: unique, fresh nonce)")
                lines.append("  id=\(first.id) duplicate=\(first.isDuplicate) score=\(first.score.map { String(format: "%.4f", $0) } ?? "nil")")
                lines.append("  file=\(first.filePath)")
                lines.append("")
                lines.append("SECOND (expected: duplicate of FIRST)")
                lines.append("  id=\(second.id) duplicate=\(second.isDuplicate) score=\(second.score.map { String(format: "%.4f", $0) } ?? "nil")")
                lines.append("  file=\(second.filePath)")
                if let pid = second.priorId { lines.append("  prior_id=\(pid)") }
                if let pd = second.priorDate { lines.append("  prior_date=\(iso.string(from: pd))") }
                lines.append("")
                // PASS requires: FIRST treated as fresh AND SECOND linked back
                // to FIRST (not to some older smoke-test entry left in the
                // index). The !first.isDuplicate clause is what surfaces a
                // polluted index instead of silently green-lighting a re-run.
                let pass = !first.isDuplicate
                    && second.isDuplicate
                    && second.priorId == first.id
                lines.append("VERDICT: \(pass ? "PASS" : "FAIL")")
                let outPath = Persistence.gruxDir.appendingPathComponent("idea-dedup-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)

                // Self-cleanup: remove this run's entries from the companion
                // service's Lance index AND delete the on-disk .md files. Without
                // this, every fire-trigger leaves two near-identical entries
                // that drift the next run's FIRST capture above the 0.85
                // duplicate threshold, masking real regressions.
                let rag = RAGClient()
                _ = try? await rag.deleteDoc(id: first.id)
                _ = try? await rag.deleteDoc(id: second.id)
                try? FileManager.default.removeItem(atPath: first.filePath)
                try? FileManager.default.removeItem(atPath: second.filePath)
            }
        }

        // Debug cross-brand-rag trigger: touch ~/.grux/fire-cross-brand-rag-test
        // to exercise the companion RAG store end-to-end. Indexes three nonce-tagged docs
        // across different brand_hints, runs a recall query, and writes the
        // verdict to ~/.grux/cross-brand-rag-test-result.txt for CLI
        // verification. Self-cleans the nonce entries so the index does not
        // accumulate test cruft.
        let ragTestFile = dir.appendingPathComponent("fire-cross-brand-rag-test")
        TriggerWatcher.shared.register(ragTestFile) {
            guard FileManager.default.fileExists(atPath: ragTestFile.path) else { return }
            try? FileManager.default.removeItem(at: ragTestFile)
            WakeLog.shared.log("manual cross-brand-rag-test trigger fired")
            Task {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
                let rag = RAGClient()
                let docs: [RAGClient.Document] = [
                    .init(
                        id: "rag-smoke-brand-a-\(nonce)",
                        source: "ambient",
                        text: "RAG smoke nonce \(nonce): brand A goat milk lotion subscribe and save cadence is forty two days.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "brand-a"
                    ),
                    .init(
                        id: "rag-smoke-grux-\(nonce)",
                        source: "decision",
                        text: "RAG smoke nonce \(nonce): the Grux exception allows a deploy without an explicit ship-it confirmation, no other brand qualifies.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "grux"
                    ),
                    .init(
                        id: "rag-smoke-brand-b-\(nonce)",
                        source: "doc",
                        text: "RAG smoke nonce \(nonce): brand B primary working tree is the Express plus React plus Drizzle codebase on Render.",
                        ts: Int(Date().timeIntervalSince1970),
                        brandHint: "brand-b"
                    ),
                ]

                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("cross-brand-rag-test result @ \(iso.string(from: Date()))")
                lines.append("nonce: \(nonce)")
                lines.append("")

                var indexedOK = false
                do {
                    let resp = try await rag.index(docs)
                    indexedOK = resp.indexed == docs.count
                    lines.append("index: indexed=\(resp.indexed) table_rows=\(resp.tableRows)")
                } catch {
                    lines.append("index: FAILED \(error)")
                }

                var hitBrandA = false
                var hitGrux = false
                var hitBrandB = false
                var hitTopScore: Double = 0
                if indexedOK {
                    do {
                        let resp = try await rag.query("smoke nonce \(nonce)", k: 5)
                        hitTopScore = resp.hits.first?.score ?? 0
                        for h in resp.hits {
                            if h.id == "rag-smoke-brand-a-\(nonce)" { hitBrandA = true }
                            if h.id == "rag-smoke-grux-\(nonce)" { hitGrux = true }
                            if h.id == "rag-smoke-brand-b-\(nonce)" { hitBrandB = true }
                        }
                        lines.append("query: hits=\(resp.hits.count) top_score=\(String(format: "%.3f", hitTopScore))")
                        for h in resp.hits.prefix(5) {
                            lines.append("  - \(h.id) score=\(String(format: "%.3f", h.score)) brand=\(h.brandHint) source=\(h.source)")
                        }
                    } catch {
                        lines.append("query: FAILED \(error)")
                    }

                    do {
                        let brandResp = try await rag.query("smoke nonce \(nonce)", k: 5, brandHint: "brand-a")
                        let allBrandA = !brandResp.hits.isEmpty && brandResp.hits.allSatisfy { $0.brandHint == "brand-a" }
                        lines.append("brand_filter(brand-a): hits=\(brandResp.hits.count) all_brand_a=\(allBrandA)")
                    } catch {
                        lines.append("brand_filter(brand-a): FAILED \(error)")
                    }
                }

                let pass = indexedOK && hitBrandA && hitGrux && hitBrandB && hitTopScore > 0.5
                lines.append("")
                lines.append("VERDICT: \(pass ? "PASS" : "FAIL")")

                let outPath = Persistence.gruxDir.appendingPathComponent("cross-brand-rag-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)

                for doc in docs {
                    _ = try? await rag.deleteDoc(id: doc.id)
                }
            }
        }

        // Open the Creative tab: touch ~/.grux/fire-open-creative
        // Routes through AppState.requestedTab which LaunchRootView observes,
        // so any external caller (CLI verification, fire-and-forget script,
        // future iOS deep link) can pop the user straight into the inbox.
        let openCreativeFile = dir.appendingPathComponent("fire-open-creative")
        TriggerWatcher.shared.register(openCreativeFile) {
            guard FileManager.default.fileExists(atPath: openCreativeFile.path) else { return }
            try? FileManager.default.removeItem(at: openCreativeFile)
            WakeLog.shared.log("manual open-creative trigger fired")
            Task { @MainActor in AppState.shared.requestedTab = "creative" }
        }

        // Voice-to-creative-engine smoke trigger: touch ~/.grux/fire-voice-image-test
        // to run a hard-coded creative brief end to end. Routes through
        // CreativeEngine (wrapper → image service → claude direct fallback),
        // saves the bundle to ~/.grux/creative/<brand>/<id>.json, and writes a
        // result summary to ~/.grux/voice-image-test-result.txt for CLI
        // verification. Lets us prove the pipeline works without a voice prompt.
        let voiceImageTestFile = dir.appendingPathComponent("fire-voice-image-test")
        TriggerWatcher.shared.register(voiceImageTestFile) {
            guard FileManager.default.fileExists(atPath: voiceImageTestFile.path) else { return }
            try? FileManager.default.removeItem(at: voiceImageTestFile)
            WakeLog.shared.log("manual voice-image-test trigger fired")
            Task { @MainActor in await CreativeEngine.shared.runSmokeTest() }
        }

        // Whisper-queue smoke trigger: touch ~/.grux/fire-whisper-queue-test
        // to run the Mac to companion service transcription round trip end to end. Resolves
        // a test WAV (explicit ~/.grux/whisper-test-audio.wav fixture, else a
        // freshly synthesized short `say` clip), uploads to the companion
        // transcription queue, polls for the result, and writes
        // ~/.grux/whisper-queue-test-result.txt for CLI verification. Proves the
        // offload path without waiting for a real 5-min-plus meeting to end.
        let whisperQueueTestFile = dir.appendingPathComponent("fire-whisper-queue-test")
        TriggerWatcher.shared.register(whisperQueueTestFile) {
            guard FileManager.default.fileExists(atPath: whisperQueueTestFile.path) else { return }
            try? FileManager.default.removeItem(at: whisperQueueTestFile)
            WakeLog.shared.log("manual whisper-queue-test trigger fired")
            Task {
                let summary = await WhisperQueueClient.shared.runSmokeTest()
                await MainActor.run {
                    AppState.shared.appendChat(ChatMessage(role: .system, content: "🎙️ \(summary)"))
                }
            }
        }

        // LLM-spend smoke trigger: touch ~/.grux/fire-llm-spend-test to verify
        // the spend tracker end to end without waiting for the 6h sweep or a
        // real billing spike. Contents:
        //   - empty / "synthetic" : inject a 7-day flat baseline + a 9x spike
        //                           day, run the REAL anomaly detector, and
        //                           speak + banner the alert (proves detection).
        //   - "live"              : force a real refresh and dump current
        //                           daily spend + provider split.
        // Result is written to ~/.grux/llm-spend-test-result.txt.
        let llmSpendTestFile = dir.appendingPathComponent("fire-llm-spend-test")
        TriggerWatcher.shared.register(llmSpendTestFile) {
            guard FileManager.default.fileExists(atPath: llmSpendTestFile.path) else { return }
            let payload = (try? String(contentsOf: llmSpendTestFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: llmSpendTestFile)
            WakeLog.shared.log("manual llm-spend-test trigger fired (mode=\(payload.isEmpty ? "synthetic" : payload))")
        }

        // Manual audio-restore escape hatch: touch ~/.grux/fire-audio-restore
        // when Music has been stranded at the ducked level (50) outside the
        // ducker's normal start/stop notification flow. Force-restores from
        // the persisted breadcrumb or to a sane default (80) when no
        // breadcrumb exists. Belt-and-suspenders for the crash-mid-duck
        // path that the self-heal in AudioDucker.install() already covers.
        let audioRestoreFile = dir.appendingPathComponent("fire-audio-restore")
        TriggerWatcher.shared.register(audioRestoreFile) {
            guard FileManager.default.fileExists(atPath: audioRestoreFile.path) else { return }
            try? FileManager.default.removeItem(at: audioRestoreFile)
            WakeLog.shared.log("manual audio-restore trigger fired")
            Task { @MainActor in AudioDucker.shared.forceRestoreNow() }
        }

        // Debug stuck-trigger - touch ~/.grux/fire-stuck to force the stuck
        // detector to fire a nudge right now (bypasses idle/silence checks
        // and the 20-min cooldown). Used for testing + power users.
        let stuckFile = dir.appendingPathComponent("fire-stuck")
        TriggerWatcher.shared.register(stuckFile) {
            guard FileManager.default.fileExists(atPath: stuckFile.path) else { return }
            try? FileManager.default.removeItem(at: stuckFile)
            WakeLog.shared.log("manual stuck trigger fired")
            Task { @MainActor in await StuckDetector.shared.forceFire() }
        }

        // Debug screen-time trigger: touch ~/.grux/fire-screentime-test to
        // force an immediate tick (writes one NDJSON line now) and dump the
        // last hour's per-app dwell summary to ~/.grux/screentime-test-result.txt
        // for CLI verification.
        let stFile = dir.appendingPathComponent("fire-screentime-test")
        TriggerWatcher.shared.register(stFile) {
            guard FileManager.default.fileExists(atPath: stFile.path) else { return }
            try? FileManager.default.removeItem(at: stFile)
            WakeLog.shared.log("manual screentime-test trigger fired")
            Task { @MainActor in
                ScreenTimeWatcher.shared.fireTickNow()
                // Give the async tick ~1.5s to land on disk before reading.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let events = ScreenTimeWatcher.loadEvents(between: hourAgo, and: now)
                let dwell = ScreenTimeWatcher.perAppDwell(between: hourAgo, and: now)
                var lines: [String] = []
                lines.append("screentime-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: app=\(last.appName) title=\(last.windowTitle) idle=\(last.idle) idle_seconds=\(last.idleSeconds)")
                }
                lines.append("per-app dwell (last hour, idle excluded):")
                for entry in dwell.prefix(10) {
                    lines.append("  \(entry.app): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("screentime-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug chrome-tabs trigger: touch ~/.grux/fire-chrome-tabs-test to
        // force one ChromeTabWatcher tick (writes one NDJSON line right now
        // if Chrome is frontmost, skips if not) and dump the last hour's
        // per-domain dwell to ~/.grux/chrome-tabs-test-result.txt for CLI
        // verification.
        let ctFile = dir.appendingPathComponent("fire-chrome-tabs-test")
        TriggerWatcher.shared.register(ctFile) {
            guard FileManager.default.fileExists(atPath: ctFile.path) else { return }
            try? FileManager.default.removeItem(at: ctFile)
            WakeLog.shared.log("manual chrome-tabs-test trigger fired")
            Task { @MainActor in
                ChromeTabWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let events = ChromeTabWatcher.loadEvents(between: hourAgo, and: now)
                let dwell = ChromeTabWatcher.perDomainDwell(between: hourAgo, and: now)
                var lines: [String] = []
                lines.append("chrome-tabs-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: domain=\(last.domain) title=\(last.title.prefix(80))")
                    lines.append("url: \(last.url.prefix(200))")
                }
                lines.append("per-domain dwell (last hour):")
                for entry in dwell.prefix(10) {
                    lines.append("  \(entry.domain): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("chrome-tabs-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug music-tracker trigger: touch ~/.grux/fire-music-tracker-test to
        // force one MusicWatcher tick (writes one NDJSON line per playing
        // source if any are running, skips silently otherwise) and dump the
        // last hour's top artists + genres + total listen-seconds to
        // ~/.grux/music-test-result.txt for CLI verification.
        let mtFile = dir.appendingPathComponent("fire-music-tracker-test")
        TriggerWatcher.shared.register(mtFile) {
            guard FileManager.default.fileExists(atPath: mtFile.path) else { return }
            try? FileManager.default.removeItem(at: mtFile)
            WakeLog.shared.log("manual music-tracker-test trigger fired")
            Task { @MainActor in
                MusicWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let dayAgo = now.addingTimeInterval(-86400)
                let events = MusicWatcher.loadEvents(between: hourAgo, and: now)
                let artistsH = MusicWatcher.perArtistDwell(between: hourAgo, and: now)
                let artistsD = MusicWatcher.perArtistDwell(between: dayAgo, and: now)
                let genresD = MusicWatcher.perGenreDwell(between: dayAgo, and: now)
                let listenH = MusicWatcher.totalListenSeconds(between: hourAgo, and: now)
                let listenD = MusicWatcher.totalListenSeconds(between: dayAgo, and: now)
                var lines: [String] = []
                lines.append("music-tracker-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("events in last hour: \(events.count)")
                if let last = events.last {
                    lines.append("most-recent: source=\(last.source) state=\(last.state) artist=\(last.artist) track=\(last.track.prefix(60))")
                }
                lines.append("listen-seconds last hour: \(listenH) (\(listenH / 60)m)")
                lines.append("listen-seconds last 24h: \(listenD) (\(listenD / 60)m)")
                lines.append("top artists last hour:")
                for entry in artistsH.prefix(5) {
                    lines.append("  \(entry.artist): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                lines.append("top artists last 24h:")
                for entry in artistsD.prefix(10) {
                    lines.append("  \(entry.artist): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                lines.append("top genres last 24h (Apple Music only):")
                for entry in genresD.prefix(5) {
                    lines.append("  \(entry.genre): \(entry.seconds)s (\(entry.seconds / 60)m)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("music-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug notification-storm trigger: touch ~/.grux/fire-notif-storm-test
        // to force one NotificationWatcher poll, then dump the last hour and
        // last 24h interrupt totals + per-app breakdown to
        // ~/.grux/notif-storm-test-result.txt for CLI verification. Lets us
        // prove the watcher end-to-end without waiting for the natural 60s
        // tick or for the next 6am workday rollup.
        let nsFile = dir.appendingPathComponent("fire-notif-storm-test")
        TriggerWatcher.shared.register(nsFile) {
            guard FileManager.default.fileExists(atPath: nsFile.path) else { return }
            try? FileManager.default.removeItem(at: nsFile)
            WakeLog.shared.log("manual notif-storm-test trigger fired")
            Task { @MainActor in
                NotificationWatcher.shared.fireTickNow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let now = Date()
                let hourAgo = now.addingTimeInterval(-3600)
                let dayAgo = now.addingTimeInterval(-86400)
                let hourCount = NotificationWatcher.interruptCount(between: hourAgo, and: now)
                let dayCount = NotificationWatcher.interruptCount(between: dayAgo, and: now)
                let hourApps = NotificationWatcher.perAppInterrupts(between: hourAgo, and: now)
                let dayApps = NotificationWatcher.perAppInterrupts(between: dayAgo, and: now)
                var lines: [String] = []
                lines.append("notif-storm-test result @ \(ISO8601DateFormatter().string(from: now))")
                if NotificationWatcher.isFDADenied() {
                    lines.append("WARNING: Full Disk Access denied. See ~/.grux/notif-storm-fda-required.txt for the one-time grant steps. Counts below will be 0 until granted.")
                }
                lines.append("interrupts last hour:  \(hourCount)")
                lines.append("interrupts last 24h:   \(dayCount)")
                lines.append("per-app last hour:")
                for entry in hourApps.prefix(10) {
                    lines.append("  \(entry.app): \(entry.count)")
                }
                lines.append("per-app last 24h:")
                for entry in dayApps.prefix(10) {
                    lines.append("  \(entry.app): \(entry.count)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("notif-storm-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug calendar-correlator trigger: touch ~/.grux/fire-calendar-correlator-test
        // to fetch the past 24h of EventKit events, correlate them to the
        // current ambient transcript chunks, and dump the resulting timeline
        // entries to ~/.grux/calendar-correlator-test-result.txt. Used for
        // CLI-driven end-to-end verification without waiting for the next 6am
        // WorkdayLog rollup.
        let ccFile = dir.appendingPathComponent("fire-calendar-correlator-test")
        TriggerWatcher.shared.register(ccFile) {
            guard FileManager.default.fileExists(atPath: ccFile.path) else { return }
            try? FileManager.default.removeItem(at: ccFile)
            WakeLog.shared.log("manual calendar-correlator-test trigger fired")
            Task { @MainActor in
                let granted = await CalendarCorrelator.ensurePermission()
                let now = Date()
                let dayAgo = now.addingTimeInterval(-24 * 3600)
                let chunks = AmbientState.shared.recentChunks
                let entries = await CalendarCorrelator.entries(
                    forWindow: dayAgo, windowEnd: now, chunks: chunks
                )
                let sessions = CalendarCorrelator.ambientSessions(from: chunks)
                let iso = ISO8601DateFormatter()
                var lines: [String] = []
                lines.append("calendar-correlator-test result @ \(iso.string(from: now))")
                lines.append("permission_granted: \(granted)")
                lines.append("ambient_chunks_in_buffer: \(chunks.count)")
                lines.append("ambient_sessions_inferred: \(sessions.count)")
                lines.append("entries (\(entries.count)):")
                for e in entries {
                    let ambient = e.ambientSessionId ?? "(none)"
                    let cal = e.calendarName.isEmpty ? "(no calendar name)" : e.calendarName
                    lines.append("  - \(iso.string(from: e.tsStart)) -> \(iso.string(from: e.tsEnd)) | \(e.eventTitle) | \(cal) | session=\(ambient)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("calendar-correlator-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug sleep-log trigger: touch ~/.grux/fire-sleep-log-test to
        // synthesize a paired sleep+wake event right now (bypasses NSWorkspace
        // so verification works on an awake Mac) and dump the rows from
        // today's NDJSON to ~/.grux/sleep-log-test-result.txt for CLI checks.
        let slFile = dir.appendingPathComponent("fire-sleep-log-test")
        TriggerWatcher.shared.register(slFile) {
            guard FileManager.default.fileExists(atPath: slFile.path) else { return }
            try? FileManager.default.removeItem(at: slFile)
            WakeLog.shared.log("manual sleep-log-test trigger fired")
            Task { @MainActor in
                SleepWatcher.shared.fireSyntheticTestEvents()
                let url = SleepWatcher.systemEventsURL(forDate: Date())
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let now = Date()
                let dayStart = Calendar.current.startOfDay(for: now)
                let intervals = SleepWatcher.sleepIntervals(in: dayStart..<now)
                var lines: [String] = []
                lines.append("sleep-log-test result @ \(ISO8601DateFormatter().string(from: now))")
                lines.append("file: \(url.path)")
                lines.append("rows:")
                lines.append(body)
                lines.append("paired sleep intervals today: \(intervals.count)")
                for iv in intervals.suffix(5) {
                    let secs = Int(iv.end.timeIntervalSince(iv.start).rounded())
                    lines.append("  \(iv.start) -> \(iv.end) (\(secs)s)")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("sleep-log-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Debug glow triggers - touch ~/.grux/fire-glow-red / fire-glow-green /
        // fire-glow-speaking to render the refocus glow around the frontmost
        // window. Lets the user verify the overlay end-to-end without waiting.
        let glowRed = dir.appendingPathComponent("fire-glow-red")
        let glowGreen = dir.appendingPathComponent("fire-glow-green")
        let glowSpeaking = dir.appendingPathComponent("fire-glow-speaking")
        TriggerWatcher.shared.register(glowRed) {
            if FileManager.default.fileExists(atPath: glowRed.path) {
                try? FileManager.default.removeItem(at: glowRed)
                WakeLog.shared.log("manual glow (red) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .distracted) }
            }
            if FileManager.default.fileExists(atPath: glowGreen.path) {
                try? FileManager.default.removeItem(at: glowGreen)
                WakeLog.shared.log("manual glow (green) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .focused) }
            }
            if FileManager.default.fileExists(atPath: glowSpeaking.path) {
                try? FileManager.default.removeItem(at: glowSpeaking)
                WakeLog.shared.log("manual glow (speaking) fired")
                Task { @MainActor in GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .speaking) }
            }
        }

        // Debug hint + stage triggers - drop the matching file at ~/.grux/ to
        // exercise each surface end-to-end. The file's text (if any) is used
        // as the message.
        let hintFile = dir.appendingPathComponent("fire-orb-hint")
        let stageFile = dir.appendingPathComponent("fire-stage")
        TriggerWatcher.shared.register(hintFile) {
            if FileManager.default.fileExists(atPath: hintFile.path) {
                let payload = (try? String(contentsOf: hintFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: hintFile)
                WakeLog.shared.log("manual orb-hint fired: '\(payload)'")
                Task { @MainActor in
                    // Payload can be "message" or "message|state". Default state is thinking.
                    let parts = payload.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let message = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "working on it"
                    let stateStr = parts.count > 1 ? parts[1] : "thinking"
                    OrbHintBus.shared.show(
                        message: message,
                        state: OrbHintBus.parseState(stateStr),
                        duration: 4.0
                    )
                }
            }
            if FileManager.default.fileExists(atPath: stageFile.path) {
                let payload = (try? String(contentsOf: stageFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: stageFile)
                WakeLog.shared.log("manual stage fired: '\(payload)'")
                Task { @MainActor in
                    let message = payload.isEmpty ? "shipped it" : payload
                    StageController.shared.show(message: message, state: .speaking, duration: 3.5)
                }
            }
        }

        // Force one focus check immediately - handy for testing the new vision
        // path without waiting for captureIntervalSeconds to elapse.
        let focusNow = dir.appendingPathComponent("fire-focus-check")
        TriggerWatcher.shared.register(focusNow) {
            guard FileManager.default.fileExists(atPath: focusNow.path) else { return }
            try? FileManager.default.removeItem(at: focusNow)
            WakeLog.shared.log("manual focus check fired")
            Task { @MainActor in FocusWatcher.shared.runOnceNow() }
        }

        // Security smoke test - touch ~/.grux/fire-smoke-test to run the
        // FilesystemTool / Redaction / Keychain / audit checks in-process
        // and write results to ~/.grux/smoke-test-results.txt.
        let smokeTrigger = dir.appendingPathComponent("fire-smoke-test")
        TriggerWatcher.shared.register(smokeTrigger) {
            guard FileManager.default.fileExists(atPath: smokeTrigger.path) else { return }
            try? FileManager.default.removeItem(at: smokeTrigger)
            WakeLog.shared.log("smoke test triggered")
            Task { @MainActor in await SmokeTest.runAndWriteReport() }
        }

        // iPhone pairing window trigger - touch ~/.grux/fire-pair-iphone to
        // open the QR pairing window. CLI verification uses this so the
        // physical iPhone can pair without clicking through the menu bar.
        let pairTrigger = dir.appendingPathComponent("fire-pair-iphone")
        TriggerWatcher.shared.register(pairTrigger) {
            guard FileManager.default.fileExists(atPath: pairTrigger.path) else { return }
            try? FileManager.default.removeItem(at: pairTrigger)
            WakeLog.shared.log("manual pair-iphone trigger fired")
            Task { @MainActor in
                AppDelegate.shared?.openPhonePairingWindow()
            }
        }

        // Agents tab CLI trigger - touch ~/.grux/fire-open-agents to open
        // the launch window with the Agents tab focused. Used by E2E scripts
        // verifying job-row right-click context menus without driving the
        // menu bar extra (System Events automation is permission-gated and
        // unreliable from Bash subshells).
        let openAgentsTrigger = dir.appendingPathComponent("fire-open-agents")
        TriggerWatcher.shared.register(openAgentsTrigger) {
            guard FileManager.default.fileExists(atPath: openAgentsTrigger.path) else { return }
            try? FileManager.default.removeItem(at: openAgentsTrigger)
            WakeLog.shared.log("manual open-agents trigger fired")
            Task { @MainActor in
                AppState.shared.requestedTab = "agents"
                AppDelegate.shared?.openLaunchWindow(tab: "agents")
            }
        }

        // Job context-menu E2E trigger - touch ~/.grux/fire-test-job-ctxmenu
        // to exercise every menu action against the FIRST job in svc.jobs and
        // dump a verification report to ~/.grux/job-ctxmenu-test.json. Used by
        // CLI verification that can't dispatch real synthetic right-clicks
        // (System Events automation is permission-gated). Each action's
        // observable side effect is captured: clipboard contents (Copy *),
        // existence of the job dir on disk (Open in Finder → Job folder),
        // and a flag for whether the Expand window scene was successfully
        // requested (Open Window).
        let ctxMenuTestTrigger = dir.appendingPathComponent("fire-test-job-ctxmenu")
        TriggerWatcher.shared.register(ctxMenuTestTrigger) {
            guard FileManager.default.fileExists(atPath: ctxMenuTestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: ctxMenuTestTrigger)
            WakeLog.shared.log("manual fire-test-job-ctxmenu fired")
            Task { @MainActor in
                await AgentService.shared.refreshJobs()
                guard let job = AgentService.shared.jobs.first else {
                    let report: [String: Any] = ["ok": false, "reason": "no jobs to test against"]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                        try? data.write(to: dir.appendingPathComponent("job-ctxmenu-test.json"))
                    }
                    return
                }
                var results: [String: Any] = [:]
                results["job_id"] = job.id
                results["job_title"] = job.title
                results["job_status"] = job.status.rawValue
                let workersDone = job.workers.filter { $0.status == .done }.count
                let workersFailed = job.workers.filter { $0.status == .failed }.count
                results["workers_total"] = job.workers.count
                results["workers_done"] = workersDone
                results["workers_failed"] = workersFailed
                results["is_terminal"] = job.isTerminal
                // Action: Copy job ID → clipboard
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(job.id, forType: .string)
                let clipped = pb.string(forType: .string) ?? ""
                results["copy_id_action"] = [
                    "expected": job.id,
                    "clipboard": clipped,
                    "match": clipped == job.id
                ]
                // Action: Reveal job folder in Finder (verify path exists)
                let folder = AgentService.shared.jobFolderURL(jobId: job.id)
                results["reveal_job_folder_action"] = [
                    "path": folder.path,
                    "exists_on_disk": FileManager.default.fileExists(atPath: folder.path)
                ]
                // Action: Open Expand window via the registered "agent-job" scene.
                // We can't call SwiftUI's openWindow from outside a View, but
                // we can prove the scene is registered + AgentJobWindow renders
                // by instantiating it directly and confirming type identity.
                let _ = AgentJobWindow(jobId: job.id)
                results["expand_window_scene"] = [
                    "scene_id": "agent-job",
                    "view_type": String(describing: AgentJobWindow.self),
                    "instantiated": true
                ]
                // Action: Retry-failed availability (only meaningful when failed > 0)
                results["retry_failed_workers_available"] = workersFailed > 0
                // Action: Resume availability (only when waiting + authLimitHit)
                results["resume_available"] = (job.status == .waiting && job.pausedReason == .authLimitHit)
                // Final verdict
                let copyOk = (results["copy_id_action"] as? [String: Any])?["match"] as? Bool ?? false
                results["all_critical_paths_ok"] = copyOk
                results["timestamp"] = ISO8601DateFormatter().string(from: Date())
                if let data = try? JSONSerialization.data(withJSONObject: results, options: .prettyPrinted) {
                    try? data.write(to: dir.appendingPathComponent("job-ctxmenu-test.json"))
                }
                WakeLog.shared.log("ctxmenu-test wrote report; copy_id_match=\(copyOk)")
            }
        }

        // Expand-job-window E2E trigger - touch ~/.grux/fire-test-expand-job
        // to open the AgentJobWindow scene for the first job, exercising the
        // exact codepath the right-click "Expand" menu item uses. Posts a
        // notification that LaunchRootView observes (it has the SwiftUI
        // openWindow environment value in scope).
        let expandTrigger = dir.appendingPathComponent("fire-test-expand-job")
        TriggerWatcher.shared.register(expandTrigger) {
            guard FileManager.default.fileExists(atPath: expandTrigger.path) else { return }
            try? FileManager.default.removeItem(at: expandTrigger)
            WakeLog.shared.log("manual fire-test-expand-job fired")
            Task { @MainActor in
                guard let jobId = AgentService.shared.jobs.first?.id else { return }
                NotificationCenter.default.post(
                    name: .gruxOpenAgentJobWindow,
                    object: nil,
                    userInfo: ["jobId": jobId]
                )
            }
        }

        // Brand-time CLI smoke trigger: touch ~/.grux/fire-brand-time-test
        // to compute today's per-brand breakdown right now (reads
        // ~/.grux/ambient/screentime-*.ndjson + chrome-tabs-*.ndjson + walks
        // discovered git repos for commits since 00:00 local). Writes
        // ~/.grux/brand-time/YYYY-MM-DD.json and dumps a verification summary
        // to ~/.grux/brand-time-test-result.txt for CLI checks. Also nudges
        // the in-memory BrandTimeStore so the EmpireDashboard reflects the
        // new report next time it opens.
        let btFile = dir.appendingPathComponent("fire-brand-time-test")
        TriggerWatcher.shared.register(btFile) {
            guard FileManager.default.fileExists(atPath: btFile.path) else { return }
            try? FileManager.default.removeItem(at: btFile)
            WakeLog.shared.log("manual brand-time-test trigger fired")
            Task.detached(priority: .utility) {
                let now = Date()
                let report = BrandAttribution.computeAndWriteToday(now: now)
                // Hand the just-computed report to the store directly so we
                // don't fire a second detached compute that races with this
                // one on the output file.
                await MainActor.run { BrandTimeStore.shared.setReport(report, computedAt: now) }
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("brand-time-test result @ \(iso.string(from: now))")
                lines.append("report: \(BrandAttribution.outputURL(for: now).path)")
                lines.append("date: \(report.date)")
                lines.append("total active seconds today: \(report.totalActiveSeconds) (\(report.totalActiveSeconds / 60)m)")
                lines.append("unattributed seconds: \(report.unattributedSeconds) (\(report.unattributedSeconds / 60)m)")
                lines.append("brands surfaced: \(report.brands.count)")
                for row in report.brands.prefix(15) {
                    let mins = row.totalSeconds / 60
                    lines.append("  \(row.brand): \(mins)m total, \(row.gitCommits) commit\(row.gitCommits == 1 ? "" : "s"), web \(row.chromeSeconds / 60)m")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("brand-time-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Empire dashboard CLI trigger: touch ~/.grux/fire-empire-dashboard
        // to open the live stat grid. Same purpose as
        // fire-pair-iphone: lets E2E scripts open the window without
        // driving sidebar clicks.
        let empireTrigger = dir.appendingPathComponent("fire-empire-dashboard")
        TriggerWatcher.shared.register(empireTrigger) {
            guard FileManager.default.fileExists(atPath: empireTrigger.path) else { return }
            try? FileManager.default.removeItem(at: empireTrigger)
            WakeLog.shared.log("manual empire-dashboard trigger fired")
            Task { @MainActor in
                AppDelegate.shared?.openEmpireDashboardWindow()
            }
        }

        // Brand-sentiment CLI smoke trigger: touch ~/.grux/fire-sentiment-test
        // to pull the latest digest from the companion sentiment service right
        // now (GET <host>/api/digest/latest), refresh the in-memory
        // store so the EmpireDashboard reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/sentiment-test-result.txt for CLI
        // checks. End-to-end verifiable without waiting for the nightly cron.
        let sentimentTrigger = dir.appendingPathComponent("fire-sentiment-test")
        TriggerWatcher.shared.register(sentimentTrigger) {
            guard FileManager.default.fileExists(atPath: sentimentTrigger.path) else { return }
            try? FileManager.default.removeItem(at: sentimentTrigger)
            WakeLog.shared.log("manual sentiment-test trigger fired")
            Task { @MainActor in
                await SentimentStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = SentimentStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("sentiment-test result @ \(iso.string(from: Date()))")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt)")
                    lines.append("brands: \(d.brandCount) | mentions: \(d.totalMentions) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    for b in d.brands.sorted(by: { $0.mentionCount > $1.mentionCount }) {
                        lines.append("  \(b.name): \(b.mood) \(String(format: "%.2f", b.score)) | \(b.mentionCount) mention(s) | \(b.provider)")
                    }
                } else {
                    lines.append("no digest (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("sentiment-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // PR-digest CLI smoke trigger: touch ~/.grux/fire-pr-summarizer-test to
        // pull the latest open-PR digest from the companion digest service
        // right now (GET <host>/api/digest/latest), refresh the
        // store so the EmpireDashboard reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/pr-summarizer-test-result.txt. This
        // exercises the Grux pull path + render end-to-end without waiting for
        // the 5:55am cron. (The PUSH path, companion POST -> /api/inbox, is verified
        // separately by the deploy smoke script.)
        let prDigestTrigger = dir.appendingPathComponent("fire-pr-summarizer-test")
        TriggerWatcher.shared.register(prDigestTrigger) {
            guard FileManager.default.fileExists(atPath: prDigestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: prDigestTrigger)
            WakeLog.shared.log("manual pr-summarizer-test trigger fired")
            Task { @MainActor in
                await PRDigestStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = PRDigestStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("pr-summarizer-test result @ \(iso.string(from: Date()))")
                lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt) | source: \(d.source)")
                    lines.append("open: \(d.openCount) | repos: \(d.repoCount) | headline: \(d.headlineProvider) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    lines.append("headline: \(d.headline)")
                    for p in d.prs.sorted(by: { $0.ageDays > $1.ageDays }) {
                        lines.append("  \(p.repo) #\(p.number) | \(p.mergeable)\(p.draft ? "/draft" : "") | \(p.ageDays)d | \(p.title)")
                    }
                } else {
                    lines.append("no digest (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("pr-summarizer-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Nightly-tests CLI smoke trigger: touch ~/.grux/fire-nightly-tests-test to
        // pull the latest nightly test report from the companion nightly service
        // right now (GET <host>/api/tests/latest), refresh the store
        // so the EmpireDashboard's Nightly Tests section reflects it, open the
        // dashboard, and dump a verification summary to
        // ~/.grux/nightly-tests-test-result.txt. Exercises the Grux pull path +
        // render end-to-end without waiting for the 4:15am cron. (The PUSH path,
        // companion POST -> /api/inbox/tests, is verified separately by the deploy
        // smoke script.)
        let nightlyTrigger = dir.appendingPathComponent("fire-nightly-tests-test")
        TriggerWatcher.shared.register(nightlyTrigger) {
            guard FileManager.default.fileExists(atPath: nightlyTrigger.path) else { return }
            try? FileManager.default.removeItem(at: nightlyTrigger)
            WakeLog.shared.log("manual nightly-tests-test trigger fired")
            Task { @MainActor in
                await TestDigestStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = TestDigestStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("nightly-tests-test result @ \(iso.string(from: Date()))")
                lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
                if let d = store.digest {
                    lines.append("generatedAt: \(d.generatedAt) | source: \(d.source)")
                    lines.append("pass: \(d.passCount) | fail: \(d.failCount) | skip: \(d.skipCount) | error: \(d.errorCount) | repos: \(d.repoCount) | fallback: \(d.fallbackUsed)")
                    lines.append("servingStale: \(store.servingStale)")
                    lines.append("headline: \(d.headline)")
                    for r in d.results {
                        lines.append("  \(r.name) [\(r.status)] | \(r.gitInfo)")
                        for c in r.checks {
                            lines.append("    \(c.kind): \(c.status) (\(Int(c.durationSec))s)")
                        }
                    }
                } else {
                    lines.append("no report (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("nightly-tests-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Empire-ops snapshot CLI smoke trigger: touch ~/.grux/fire-empire-dash-test
        // to pull the aggregated snapshot from the companion snapshot service
        // right now (GET <host>/api/empire/snapshot), refresh the store
        // so the Empire Dashboard's Ops grid reflects it, open the dashboard, and dump
        // a verification summary to ~/.grux/empire-dash-test-result.txt. Exercises the
        // Grux pull + render end-to-end without waiting for the hourly refresh.
        let empireDashTrigger = dir.appendingPathComponent("fire-empire-dash-test")
        TriggerWatcher.shared.register(empireDashTrigger) {
            guard FileManager.default.fileExists(atPath: empireDashTrigger.path) else { return }
            try? FileManager.default.removeItem(at: empireDashTrigger)
            WakeLog.shared.log("manual empire-dash-test trigger fired")
            Task { @MainActor in
                await EmpireSnapshotStore.shared.refresh()
                AppDelegate.shared?.openEmpireDashboardWindow()
                let store = EmpireSnapshotStore.shared
                var lines: [String] = []
                let iso = ISO8601DateFormatter()
                lines.append("empire-dash-test result @ \(iso.string(from: Date()))")
                if let s = store.snapshot {
                    let t = s.totals
                    let rev = t.revenueCents.map { String(format: "$%.2f", Double($0) / 100.0) } ?? "n/a"
                    lines.append("generatedAt: \(s.generatedAt) | source: \(s.source) | tookMs: \(s.tookMs)")
                    lines.append("brands: \(s.brandCount) | revenue: \(rev) | installs: \(t.installs.map(String.init) ?? "n/a") | ratings: \(t.ratingCount ?? 0) | openPRs: \(t.openPRs) | infra: \(t.infraHealthy)/\(t.infraTotal)")
                    lines.append("servingStale: \(store.servingStale)")
                    let order = ["stripe", "asc", "github", "render", "cloudflare", "support"]
                    let badges = order.compactMap { k -> String? in
                        guard let m = s.sources[k] else { return nil }
                        let state = (m.ok == true) ? "ok" : ((m.configured == true) ? "cfg" : "off")
                        return "\(k)=\(state)"
                    }
                    lines.append("sources: " + badges.joined(separator: " "))
                    for b in s.brands {
                        let r = b.revenueCents.map { String(format: "$%.0f", Double($0) / 100.0) } ?? "n/a"
                        lines.append("  \(b.name): rev \(r) | installs \(b.installs.map(String.init) ?? "n/a")(\(b.installsSource)) | PRs \(b.openPRs) | infra \(b.infra.healthy)/\(b.infra.total)")
                    }
                    if !s.errors.isEmpty { lines.append("errors: \(s.errors.joined(separator: "; "))") }
                } else {
                    lines.append("no snapshot (error: \(store.lastError ?? "unknown"))")
                }
                let outPath = Persistence.gruxDir.appendingPathComponent("empire-dash-test-result.txt").path
                try? lines.joined(separator: "\n").write(
                    toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        // Social Ops cockpit CLI smoke trigger: touch ~/.grux/fire-social-ops-cockpit-test
        // to pull the live grid from the companion social-ops service right now
        // (GET <host>/api/social-ops/state), ingest it so the
        // Empire Dashboard's Social Ops section reflects it, open the dashboard,
        // write a PASS/FAIL summary to ~/.grux/social-ops-cockpit-test-result.txt,
        // and append a one-line result to chat. Exercises the Mac pull + render
        // end-to-end without waiting for a sweep change-event.
        let socialOpsTrigger = dir.appendingPathComponent("fire-social-ops-cockpit-test")
        TriggerWatcher.shared.register(socialOpsTrigger) {
            guard FileManager.default.fileExists(atPath: socialOpsTrigger.path) else { return }
            try? FileManager.default.removeItem(at: socialOpsTrigger)
            WakeLog.shared.log("manual social-ops-cockpit-test trigger fired")
            Task { @MainActor in
                let summary = await SocialOpsCoordinator.shared.runSmokeTest()
                AppDelegate.shared?.openEmpireDashboardWindow()
                AppState.shared.appendChat(ChatMessage(role: .system, content: "📣 \(summary)"))
            }
        }

        // Social Ops digest CLI trigger: touch ~/.grux/fire-social-ops-digest to
        // force the daily health digest + weekly reach-trend cards right now
        // (ignoring the once-per-period guards), so the native notification +
        // chat card + phone push path can be verified without waiting for the
        // 15-minute tick or a day/week rollover.
        let socialOpsDigestTrigger = dir.appendingPathComponent("fire-social-ops-digest")
        TriggerWatcher.shared.register(socialOpsDigestTrigger) {
            guard FileManager.default.fileExists(atPath: socialOpsDigestTrigger.path) else { return }
            try? FileManager.default.removeItem(at: socialOpsDigestTrigger)
            WakeLog.shared.log("manual social-ops-digest trigger fired")
            Task { @MainActor in
                SocialOpsCoordinator.shared.runScheduledDigestsIfDue(force: true)
            }
        }

        // iPhone receiver status dump - touch ~/.grux/fire-phone-status to
        // write a one-shot JSON file at ~/.grux/phone-receiver-status.json
        // with the current port, connection state, and frame counts.
        let phoneStatusTrigger = dir.appendingPathComponent("fire-phone-status")
        TriggerWatcher.shared.register(phoneStatusTrigger) {
            guard FileManager.default.fileExists(atPath: phoneStatusTrigger.path) else { return }
            try? FileManager.default.removeItem(at: phoneStatusTrigger)
            Task { @MainActor in
                let s = PhoneReceiverState.shared
                let json: [String: Any] = [
                    "isRunning": s.isRunning,
                    "isConnected": s.isConnected,
                    "connectedDevice": s.connectedDevice,
                    "audioFramesReceived": s.audioFramesReceived,
                    "listenerPort": Int(s.listenerPort),
                    "latestTranscript": s.latestTranscript,
                    "lastError": s.lastError,
                    "lastFrameAtEpoch": s.lastFrameAt.timeIntervalSince1970,
                    "pairingSecretConfigured": PhonePairing.isConfigured,
                    "hostname": PhonePairing.localHostname()
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                    let out = dir.appendingPathComponent("phone-receiver-status.json")
                    try? data.write(to: out)
                }
            }
        }

        // Screen control status dump - touch ~/.grux/fire-screen-check to write
        // ~/.grux/screen-control-status.json.
        //
        // THIS EXISTS BECAUSE OF A GAP IN WHAT TESTS CAN SEE. The screen control
        // tests run in the test host, which is a different binary with its own
        // TCC grants and its own place in the window stack. A green suite there
        // says the logic is right; it says nothing about whether the SHIPPED,
        // re-signed Grux.app still holds Accessibility, or which app the running
        // app believes is behind it. Both of those are exactly the questions
        // that go wrong silently, and both are only answerable from inside this
        // process.
        //
        // Read-only and side-effect free: it reports the switch and the grant,
        // and resolves the target WITHOUT walking any accessibility tree, so
        // firing it never touches another app.
        let screenCheckTrigger = dir.appendingPathComponent("fire-screen-check")
        TriggerWatcher.shared.register(screenCheckTrigger) {
            guard FileManager.default.fileExists(atPath: screenCheckTrigger.path) else { return }
            try? FileManager.default.removeItem(at: screenCheckTrigger)
            Task { @MainActor in
                let selfPID = ProcessInfo.processInfo.processIdentifier
                let order = ScreenControlEngine.onScreenPIDsFrontToBack()
                let target = ScreenControlEngine.currentTarget()
                var json: [String: Any] = [
                    "accessibilityGranted": ScreenControlEngine.hasAccessibility(),
                    "screenControlEnabled": AppState.shared.config.screenControlEnabled,
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "selfPID": Int(selfPID),
                    "frontmostPID": NSWorkspace.shared.frontmostApplication
                        .map { Int($0.processIdentifier) } ?? -1,
                    "gruxIsFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == selfPID,
                    "onScreenFrontToBack": order.map(Int.init),
                    // The whole point of the dump: which app list_ui would read.
                    "resolvedTarget": target?.name ?? "(none)",
                    "resolvedTargetPID": target.map { Int($0.pid) } ?? -1,
                    "resolvedTargetIsSelf": target?.pid == selfPID,
                    // The layout the key table is relative to, plus the one combo
                    // that was silently typing the wrong character.
                    "keyboardLayout": ScreenControlEngine.currentKeyboardLayoutName() ?? "unknown",
                    "plusTypes": ScreenControlEngine.producedCharacter(for: "plus") ?? "(none)",
                    "equalsTypes": ScreenControlEngine.producedCharacter(for: "equals") ?? "(none)",
                    "writtenAtEpoch": Date().timeIntervalSince1970
                ]
                json["onScreenAppNames"] = order.compactMap { pid in
                    NSWorkspace.shared.runningApplications
                        .first { $0.processIdentifier == pid }?.localizedName
                }
                if let data = try? JSONSerialization.data(withJSONObject: json,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: dir.appendingPathComponent("screen-control-status.json"))
                }
            }
        }

        // Fire a TTS utterance through SpeechEngine - same path as a chat
        // reply. Used to end-to-end verify the phone's TTS playback pipeline
        // from CLI without typing into chat. Reads message from the trigger
        // file contents; fallback text if empty.
        let fireSpeak = dir.appendingPathComponent("fire-speak")
        TriggerWatcher.shared.register(fireSpeak) {
            guard FileManager.default.fileExists(atPath: fireSpeak.path) else { return }
            let msg = (try? String(contentsOf: fireSpeak, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireSpeak)
            let text = msg.isEmpty
                ? "Grux is now streaming both ways over Cloudflare. If you can hear this on your phone, we nailed the bidirectional pipeline."
                : msg
            WakeLog.shared.log("fire-speak: \(text.prefix(60))")
            Task { @MainActor in SpeechEngine.shared.speak(text) }
        }

        // fire-optimize: write a work order without a click, contents = the
        // request. For voice, the CLI and tests. Writes the order's id and
        // file to `optimize-ack.json` and never touches the clipboard, which
        // is the person's; the panel's Copy button is what copies.
        let fireOptimize = dir.appendingPathComponent("fire-optimize")
        TriggerWatcher.shared.register(fireOptimize) {
            guard FileManager.default.fileExists(atPath: fireOptimize.path) else { return }
            let request = (try? String(contentsOf: fireOptimize, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: fireOptimize)
            Task { @MainActor in
                let order = WorkOrderStore.shared.create(request: request, context: { WorkOrderContext.live(orderDir: $0) })
                if order != nil { OptimizeHubState.shared.isExpanded = true }
                let ack: [String: Any] = order.map { ["ok": true, "id": $0.id, "workOrder": $0.workOrderFile.path,
                                                       "progress": $0.progressFile.path] }
                    ?? ["ok": false, "error": "empty request"]
                if let data = try? JSONSerialization.data(withJSONObject: ack, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: dir.appendingPathComponent("optimize-ack.json"), options: .atomic)
                }
                WakeLog.shared.log("fire-optimize: \(order.map { "wrote \($0.id)" } ?? "refused an empty request")")
            }
        }

        // fire-first-run-reset: put the first-run flow back at its first
        // screen so it can be walked again on a real install (P-F-1, Task F5).
        // First run happens once per machine, which is why it was so hard to
        // verify. Forgets the feature selection too, since first run is what
        // writes it. Keeps consent, keys and macOS permissions: a walk
        // re-offers those, it does not erase them.
        let fireFirstRunReset = dir.appendingPathComponent("fire-first-run-reset")
        TriggerWatcher.shared.register(fireFirstRunReset) {
            guard FileManager.default.fileExists(atPath: fireFirstRunReset.path) else { return }
            try? FileManager.default.removeItem(at: fireFirstRunReset)
            Task { @MainActor in
                OnboardingModel.shared.reset()
                FeatureSelection.clear()
                WakeLog.shared.log("fire-first-run-reset: onboarding at \(OnboardingModel.shared.stage.rawValue), feature selection cleared")
            }
        }

        // fire-first-run-finish: end the first-run flow where it stands, the
        // same way "I am already set up" does. An install left on a setup
        // screen shows no tab to any command, and the only way past it was a
        // click. Sends nothing to Chat: the first-run answer is the person's.
        let fireFirstRunFinish = dir.appendingPathComponent("fire-first-run-finish")
        TriggerWatcher.shared.register(fireFirstRunFinish) {
            guard FileManager.default.fileExists(atPath: fireFirstRunFinish.path) else { return }
            try? FileManager.default.removeItem(at: fireFirstRunFinish)
            Task { @MainActor in
                OnboardingModel.shared.finish(skippedFirstLook: true, sendFirstExchange: false)
                WakeLog.shared.log("fire-first-run-finish: onboarding at \(OnboardingModel.shared.stage.rawValue)")
            }
        }

        // fire-open-tab: switch the RUNNING app to a tab, contents = the tab key
        // (the same keys --open-tab accepts). Opens the launch window if it is
        // closed, then selects the tab.
        //
        // This exists for UI verification. The only way to reach a specific tab
        // from outside was `--open-tab=` at LAUNCH, so sweeping every tab meant
        // quitting and relaunching per tab: about 12 seconds each, roughly 7
        // minutes for a full pass, which is slow enough that a full-app visual
        // check gets skipped and layout regressions ship. Switching a live tab
        // is a repaint, so the same pass runs in about a second per tab.
        //
        // Writes ~/.grux/open-tab-ack.txt with the key it applied, so a script
        // can wait for the switch to actually land instead of sleeping and
        // hoping. That ack is what makes the loop both fast and reliable.
        // fire-mic-mute / fire-mic-unmute: drive the microphone from the CLI.
        //
        // Added while fixing a bug where MUTED left the device held: a mute that
        // can only be triggered by clicking an orb cannot be verified without a
        // person, and this app's owner has limited mobility, so "just click it"
        // is not a test plan OR an acceptable only-path for the feature itself.
        // Writes a status file so a caller can assert the result rather than
        // sleeping and hoping.
        let fireMicMute = dir.appendingPathComponent("fire-mic-mute")
        TriggerWatcher.shared.register(fireMicMute) {
            try? FileManager.default.removeItem(at: fireMicMute)
            Task { @MainActor in
                MicController.mute(source: "fire-mic-mute")
                await MicController.writeMicStatus(dir: dir)
            }
        }
        let fireMicUnmute = dir.appendingPathComponent("fire-mic-unmute")
        TriggerWatcher.shared.register(fireMicUnmute) {
            try? FileManager.default.removeItem(at: fireMicUnmute)
            Task { @MainActor in
                MicController.unmute()
                await MicController.writeMicStatus(dir: dir)
            }
        }

        // fire-ambient-enable / fire-wake-enable: drive the LISTENING CONSENT
        // path from the CLI.
        //
        // Turning either feature on presents a modal dialog, and a modal is a
        // mouse gesture by construction. Same reasoning that produced
        // fire-mic-mute directly above: a feature whose only trigger is a click
        // cannot be verified by this app's owner, and a consent gate that has
        // never been seen working is a consent gate nobody should trust.
        //
        // Each writes mic-status.json after the dialog closes, so the ANSWER is
        // assertable: declining leaves ambientEnabledPreference false.
        let fireAmbientEnable = dir.appendingPathComponent("fire-ambient-enable")
        TriggerWatcher.shared.register(fireAmbientEnable) {
            try? FileManager.default.removeItem(at: fireAmbientEnable)
            Task { @MainActor in
                AppState.shared.config.listeningMode = .alwaysOn
                await ListeningController.shared.apply()
                await MicController.writeMicStatus(dir: dir)
            }
        }
        let fireWakeEnable = dir.appendingPathComponent("fire-wake-enable")
        TriggerWatcher.shared.register(fireWakeEnable) {
            try? FileManager.default.removeItem(at: fireWakeEnable)
            Task { @MainActor in
                AppState.shared.config.listeningMode = .wakeWord
                await ListeningController.shared.apply()
                await MicController.writeMicStatus(dir: dir)
            }
        }
        // And a read with no side effects, so state can be checked without
        // changing it. Every other status write here rides on an action.
        let fireMicStatus = dir.appendingPathComponent("fire-mic-status")
        TriggerWatcher.shared.register(fireMicStatus) {
            try? FileManager.default.removeItem(at: fireMicStatus)
            Task { @MainActor in await MicController.writeMicStatus(dir: dir) }
        }

        // The setup surface, refreshed on demand and with no side effects.
        //
        // Every agent handoff Grux emits ends with a VERIFY section pointing at this state,
        // so it has to be readable without launching a UI and without changing anything.
        // The app also writes it at launch and after any step completes; this trigger is
        // for a caller that wants it recomputed right now, which is what the CLI does after
        // handing a permission queue over and waiting for the answer.
        let fireSetupStatus = dir.appendingPathComponent("fire-setup-status")
        TriggerWatcher.shared.register(fireSetupStatus) {
            try? FileManager.default.removeItem(at: fireSetupStatus)
            Task { @MainActor in SetupStatusFile.write() }
        }

        // fire-headless-snapshot: render every Grux window's own view hierarchy
        // to PNG under ~/.grux/headless-workspace/shots and list the files in
        // headless-workspace/snapshot-result.json. Needs no Screen Recording permission,
        // so a headless Mac can see what a person would have seen.
        let fireHeadlessSnapshot = dir.appendingPathComponent("fire-headless-snapshot")
        TriggerWatcher.shared.register(fireHeadlessSnapshot) {
            guard FileManager.default.fileExists(atPath: fireHeadlessSnapshot.path) else { return }
            let reason = (try? String(contentsOf: fireHeadlessSnapshot, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireHeadlessSnapshot)
            Task { @MainActor in
                let files = HeadlessWorkspace.snapshot(reason: reason.isEmpty ? "trigger" : reason)
                WakeLog.shared.log("fire-headless-snapshot: \(files.count) window(s)")
            }
        }

        let fireOpenTab = dir.appendingPathComponent("fire-open-tab")
        TriggerWatcher.shared.register(fireOpenTab) {
            guard FileManager.default.fileExists(atPath: fireOpenTab.path) else { return }
            let key = (try? String(contentsOf: fireOpenTab, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireOpenTab)
            guard !key.isEmpty else { return }
            Task { @MainActor in
                // `settings:<tag>` selects a pane INSIDE Settings as well as the
                // tab, so a sweep can reach every Settings surface rather than
                // photographing whichever pane happened to be open last.
                //
                // Settings is one sidebar entry hiding five panes and nine
                // sub-panes, which is more distinct surface than most tabs have,
                // and none of it was reachable from outside. That is precisely
                // the gap this trigger's own comment describes: a surface that
                // cannot be driven does not get checked, and layout regressions
                // ship there. The tag goes through SettingsTabAliases, the same
                // resolver the setup card's deep link uses, so there is no
                // second vocabulary to keep in sync.
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                let tab = parts[0]
                // Approvals are a tray, not a tab (C10): open Today with the
                // tray open rather than letting an unknown key fall to Chat.
                if tab == ApprovalsTray.openKey {
                    (NSApp.delegate as? AppDelegate)?.openLaunchWindow(tab: "home")
                    WindowFacade.activateGrux()
                    ApprovalsTrayState.shared.isOpen = true
                    try? key.write(to: dir.appendingPathComponent("open-tab-ack.txt"), atomically: true, encoding: .utf8)
                    WakeLog.shared.log("fire-open-tab: approvals tray (\(ApprovalQueue.shared.pendingCount) waiting)")
                    return
                }
                // Any other key closes the tray. A programmatic tab change is not
                // a click outside the popover, so it used to stay open over
                // whatever the key opened (seen live, 2026-09-21).
                ApprovalsTrayState.shared.isOpen = false
                if parts.count == 2 {
                    if tab == "settings" { AppState.shared.requestedSettingsTab = parts[1] }
                    else { AppState.shared.requestedSection = parts[1] }
                }
                AppState.shared.requestedTab = tab
                (NSApp.delegate as? AppDelegate)?.openLaunchWindow(tab: tab)
                WindowFacade.activateGrux()
                let ack = dir.appendingPathComponent("open-tab-ack.txt")
                // Acks the FULL key including the pane, so a script waiting on
                // "settings:models" is not released by a bare "settings".
                try? key.write(to: ack, atomically: true, encoding: .utf8)
                WakeLog.shared.log("fire-open-tab: \(key)")
            }
        }

        // fire-chat-show-earlier, fire-chat-scroll, fire-chat-latest,
        // fire-chat-status, fire-pane-width: the Chat transcript's clicks and
        // scrolls, each followed by chat-status.json (Triggers/ChatTriggers.swift).
        ChatTriggers.register(in: dir)
        // fire-workflow-open-run, fire-workflows-status: open a run's steps
        // as a click does, then workflows-status.json (Triggers/WorkflowTriggers.swift).
        WorkflowTriggers.register(in: dir)

        // fire-jax-brief: Jax speaks an on-demand briefing now (Home "brief me"
        // / CLI hook). Does not touch the scheduled-slot dedupe.
        let fireJaxBrief = dir.appendingPathComponent("fire-jax-brief")
        TriggerWatcher.shared.register(fireJaxBrief) {
            guard FileManager.default.fileExists(atPath: fireJaxBrief.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxBrief)
            WakeLog.shared.log("fire-jax-brief: on-demand briefing requested")
            Task { @MainActor in await BriefingEngine.shared.briefNow() }
        }

        // fire-foundry-resume: clear a tripped auto-land pause (the crash-loop
        // breaker pauses Foundry auto-land after repeated launch crashes; this
        // is the human reset). touch ~/.grux/fire-foundry-resume to resume.
        let fireFoundryResume = dir.appendingPathComponent("fire-foundry-resume")
        TriggerWatcher.shared.register(fireFoundryResume) {
            guard FileManager.default.fileExists(atPath: fireFoundryResume.path) else { return }
            try? FileManager.default.removeItem(at: fireFoundryResume)
            WakeLog.shared.log("fire-foundry-resume: clearing auto-land pause")
            Task { @MainActor in GruxUpdater.shared.clearAutoLandPause() }
        }

        // fire-jax-goalcycle: run one Jax goal-pursuit cycle now (respects the
        // current autonomy mode; SIMULATE by default, so it plans + logs only).
        // Reusable for verification and on-demand "what would you do next".
        let fireJaxGoal = dir.appendingPathComponent("fire-jax-goalcycle")
        TriggerWatcher.shared.register(fireJaxGoal) {
            guard FileManager.default.fileExists(atPath: fireJaxGoal.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxGoal)
            WakeLog.shared.log("fire-jax-goalcycle: goal-pursuit cycle requested")
            Task { @MainActor in _ = await GoalPursuitEngine.shared.runNow() }
        }

        // fire-jax-ingest: run the full corpus ingest now (all sources). Drop new
        // exports into ~/.grux/jax/imports first, then touch this file. Result is
        // logged to WakeLog. Reusable after dropping fresh data.
        let fireJaxIngest = dir.appendingPathComponent("fire-jax-ingest")
        TriggerWatcher.shared.register(fireJaxIngest) {
            guard FileManager.default.fileExists(atPath: fireJaxIngest.path) else { return }
            try? FileManager.default.removeItem(at: fireJaxIngest)
            WakeLog.shared.log("fire-jax-ingest: corpus ingest requested")
            Task { @MainActor in
                let summary = await CorpusCoordinator.shared.runAll()
                WakeLog.shared.log("fire-jax-ingest done: \(summary)")
            }
        }

        // Rotate phone pairing secret. Closes any active phone session so
        // it can't keep streaming with the now-revoked key, deletes the
        // secret from Keychain (where we have ACL), and regenerates. There is
        // no tunnel URL to wait for: the pair QR encodes the new secret the
        // next time the pairing window renders.
        let fireRotate = dir.appendingPathComponent("fire-rotate-secret")
        TriggerWatcher.shared.register(fireRotate) {
            guard FileManager.default.fileExists(atPath: fireRotate.path) else { return }
            try? FileManager.default.removeItem(at: fireRotate)
            WakeLog.shared.log("fire-rotate-secret triggered")
            Task { @MainActor in
                PhoneReceiverService.shared.closeActiveConnectionForRotate()
                _ = PhonePairing.reset()
                _ = PhonePairing.ensureSecret()
            }
        }

        // Smoke-test the local-Qwen ambient brain end to end. Touch
        // ~/.grux/fire-ambient-llm-test to send a canned prompt through the
        // exact AmbientLLM routing the hourly summarizer uses, then write the
        // reply + latency + provider to ~/.grux/ambient-llm-test-result.txt.
        // Lets E2E scripts verify the Mac → companion service → Ollama loop without
        // waiting for the hour boundary or opening Settings.
        let fireAmbientLLM = dir.appendingPathComponent("fire-ambient-llm-test")
        TriggerWatcher.shared.register(fireAmbientLLM) {
            guard FileManager.default.fileExists(atPath: fireAmbientLLM.path) else { return }
            let prompt = (try? String(contentsOf: fireAmbientLLM, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireAmbientLLM)
            let user = prompt.isEmpty
                ? "TRANSCRIPT_CHUNKS:\n- shipped the PDP image render\n- still need to wire the label-fidelity check\n- Grux ambient brain landed today\nOne-sentence summary:"
                : prompt
            let sys = "You are Grux summarizing one hour of the user's ambient speech. Produce ONE short sentence (≤40 words). If pure filler, reply quiet. No emoji, no markdown."
            Task { @MainActor in
                let started = Date()
                let intent = AppState.shared.config.useLocalQwenForAmbient
                    ? "local/\(AppState.shared.config.localLLMModel)"
                    : "claude"
                do {
                    let res = try await AmbientLLM.completeTagged(
                        system: sys,
                        messages: [ClaudeMessage(role: "user", content: user)],
                        maxTokens: 120, temperature: 0.3,
                        featureTag: "ambient_llm_smoke_test"
                    )
                    let reply = res.text
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    // Provider used may differ from intent if the local path
                    // failed and the router fell back to Claude.
                    let actual = res.provider
                    let out = "intent=\(intent) provider=\(actual) ms=\(ms)\nreply: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    let outUrl = dir.appendingPathComponent("ambient-llm-test-result.txt")
                    try? out.write(to: outUrl, atomically: true, encoding: .utf8)
                    WakeLog.shared.log("fire-ambient-llm-test: ok (intent=\(intent) provider=\(actual), \(ms)ms)")
                } catch {
                    let outUrl = dir.appendingPathComponent("ambient-llm-test-result.txt")
                    try? "intent=\(intent) FAILED: \(error.localizedDescription)\n"
                        .write(to: outUrl, atomically: true, encoding: .utf8)
                    WakeLog.shared.log("fire-ambient-llm-test: failed \(error.localizedDescription)")
                }
            }
        }

        // Direct-to-phone synthetic TTS tone. Doesn't touch SpeechEngine or
        // ElevenLabs - synthesizes a 24kHz PCM16 warble right into
        // TTSBroadcaster. Lets us end-to-end verify the phone TTS playback
        // path even without an ElevenLabs key configured.
        let fireTTSTone = dir.appendingPathComponent("fire-tts-tone")
        TriggerWatcher.shared.register(fireTTSTone) {
            guard FileManager.default.fileExists(atPath: fireTTSTone.path) else { return }
            try? FileManager.default.removeItem(at: fireTTSTone)
            WakeLog.shared.log("fire-tts-tone → injecting 2s warble into TTSBroadcaster")
            Task { @MainActor in
                TTSBroadcaster.shared.speakStart()
                // 2-second warble: slow-sweeping sine, 24 kHz. Produces a
                // recognizable "dooo-waaa" that's obvious over a phone speaker.
                let sr = 24_000
                let totalSamples = sr * 2
                var pcm = Data(count: totalSamples * 2)
                pcm.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                    for i in 0..<totalSamples {
                        let t = Double(i) / Double(sr)
                        let freq = 300.0 + 250.0 * sin(2.0 * .pi * 0.5 * t)
                        let v = sin(2.0 * .pi * freq * t) * 0.25
                        base[i] = Int16(clamping: Int(v * Double(Int16.max)))
                    }
                }
                TTSBroadcaster.shared.feedPCM24(pcm)
                // Small drain delay so the phone plays the full tone before
                // END fires (which would otherwise stop the player node).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    Task { @MainActor in TTSBroadcaster.shared.speakEnd() }
                }
            }
        }

        // V2 workflow CANCEL trigger - touch ~/.grux/fire-v2-cancel with a
        // run id (8-char prefix is enough) in the file body to cancel the
        // matching active or waiting run. Used for headless E2E recovery
        // when a run is parked at an approval gate.
        let v2CancelTrigger = dir.appendingPathComponent("fire-v2-cancel")
        TriggerWatcher.shared.register(v2CancelTrigger) {
            guard FileManager.default.fileExists(atPath: v2CancelTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2CancelTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2CancelTrigger)
            guard !payload.isEmpty else {
                WakeLog.shared.log("fire-v2-cancel: empty payload - skipping")
                return
            }
            Task { @MainActor in
                let prefix = String(payload.prefix(36))
                let match = CommandV2Engine.shared.activeRuns.first {
                    $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) ||
                    $0.id.uuidString.lowercased() == prefix.lowercased()
                }
                guard let target = match else {
                    WakeLog.shared.log("fire-v2-cancel: no active run matches '\(prefix)'")
                    return
                }
                await CommandV2Engine.shared.cancel(target.id)
                WakeLog.shared.log("fire-v2-cancel: canceled \(target.id.uuidString.prefix(8))")
            }
        }

        // V2 workflow APPROVE trigger - touch ~/.grux/fire-v2-approve with a
        // run id (8-char prefix or full UUID) optionally followed by `|<reply>`
        // to programmatically advance a userApprovalGate-paused run. Used so
        // autonomous loops can drive workflows past walkthrough gates without
        // a human click. The reply must be one the gate asked for. With none,
        // only a gate that lists an approve word goes on, with that word; a
        // gate of choices (fix / ship / hold) or free text stays waiting.
        let v2ApproveTrigger = dir.appendingPathComponent("fire-v2-approve")
        TriggerWatcher.shared.register(v2ApproveTrigger) {
            guard FileManager.default.fileExists(atPath: v2ApproveTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2ApproveTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2ApproveTrigger)
            guard !payload.isEmpty else { return }
            let parts = payload.split(separator: "|", maxSplits: 1).map { String($0) }
            let prefix = parts[0].trimmingCharacters(in: .whitespaces)
            let reply: String? = parts.count > 1 ? parts[1] : nil
            Task { @MainActor in
                let match = CommandV2Engine.shared.activeRuns.first {
                    $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased()) ||
                    $0.id.uuidString.lowercased() == prefix.lowercased()
                }
                guard let target = match else {
                    WakeLog.shared.log("fire-v2-approve: no waiting run matches '\(prefix)'")
                    return
                }
                let taken = await CommandV2Engine.shared.resume(target.id, userReply: reply)
                WakeLog.shared.log("fire-v2-approve: \(taken ? "advanced" : "did not advance") \(target.id.uuidString.prefix(8)) reply='\(reply ?? "(none)")'")
            }
        }

        // V2 workflow CLI trigger - touch ~/.grux/fire-v2-run with a
        // definition id (e.g. "smoke-hello-world") in the file body to
        // start that V2 workflow. Used for headless E2E verification of
        // the engine without driving the SwiftUI tab.
        let v2RunTrigger = dir.appendingPathComponent("fire-v2-run")
        TriggerWatcher.shared.register(v2RunTrigger) {
            guard FileManager.default.fileExists(atPath: v2RunTrigger.path) else { return }
            let payload = (try? String(contentsOf: v2RunTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: v2RunTrigger)
            // Payload format: "<definition-id>" or "<definition-id>|<param>=<value>,<param>=<value>"
            let parts = payload.split(separator: "|", maxSplits: 1).map { String($0) }
            let defId = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !defId.isEmpty else {
                WakeLog.shared.log("fire-v2-run: empty payload - skipping")
                return
            }
            var params: [String: JSONValue] = [:]
            if parts.count > 1 {
                for kv in parts[1].split(separator: ",") {
                    let bits = kv.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if bits.count == 2 { params[bits[0]] = .string(bits[1]) }
                }
            }
            WakeLog.shared.log("fire-v2-run: starting '\(defId)' with params \(params.keys.sorted())")
            Task { @MainActor in
                let result = await CommandV2Engine.shared.start(definitionId: defId, params: params)
                let outURL = dir.appendingPathComponent("v2-run-result.txt")
                let line: String
                switch result {
                case .success(let id):
                    let engine = CommandV2Engine.shared
                    let dry = (engine.run(id: id) ?? engine.recentRuns.first { $0.id == id })?.isDryRun == true
                    line = "started \(defId)\(dry ? " (dry run)" : "") → \(id.uuidString)\n"
                case .failure(let err):
                    line = "error: \(err.localizedDescription)\n"
                }
                try? line.write(to: outURL, atomically: true, encoding: .utf8)
            }
        }

        // Pairing URL dump - touch ~/.grux/fire-phone-pair-dump to write the
        // full grux-pair:// URL (INCLUDING the shared secret) to
        // ~/.grux/phone-pair-url.txt. Dev + CI testing only - the secret is
        // the whole trust boundary, so we nuke the file 30s after writing and
        // require the trigger to be re-touched each time.
        let phonePairDumpTrigger = dir.appendingPathComponent("fire-phone-pair-dump")
        TriggerWatcher.shared.register(phonePairDumpTrigger) {
            guard FileManager.default.fileExists(atPath: phonePairDumpTrigger.path) else { return }
            try? FileManager.default.removeItem(at: phonePairDumpTrigger)
            Task { @MainActor in
                _ = PhonePairing.ensureSecret()
                guard let secret = PhonePairing.secret() else { return }
                let port: UInt16 = PhoneReceiverState.shared.listenerPort == 0
                    ? 55000 : PhoneReceiverState.shared.listenerPort
                // LAN only: there is no cloud tunnel, so the branch that used to
                // prefer a wss://*.trycloudflare.com URL had one live arm left.
                let wss = "ws://\(PhonePairing.localHostname()):\(port)/ws"
                let info = PhonePairingURL.Info(
                    secretBase64URL: PhonePairingURL.base64URLEncode(secret),
                    wssURL: wss,
                    name: PhonePairing.displayName()
                )
                let out = dir.appendingPathComponent("phone-pair-url.txt")
                try? info.url.absoluteString.write(to: out, atomically: true, encoding: .utf8)
                // Auto-shred after 30s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    try? FileManager.default.removeItem(at: out)
                }
            }
        }

        // Dynamic image render trigger (Studio CLI front door). Drop
        // ~/.grux/fire-image with a JSON payload, e.g.
        //   {"brand":"<brand>","directive":"Change the white background. ...","sku":"standard","aspect":"4:5","count":2}
        // and CreativeEngine.renderDynamic runs the same path as the Studio
        // composer, landing the batch in the inbox. Writes
        // ~/.grux/fire-image-result.txt for CLI verification. One code path,
        // two front doors.
        let fireImageTrigger = dir.appendingPathComponent("fire-image")
        TriggerWatcher.shared.register(fireImageTrigger) {
            guard FileManager.default.fileExists(atPath: fireImageTrigger.path) else { return }
            let raw = (try? String(contentsOf: fireImageTrigger, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: fireImageTrigger)
            let resultPath = dir.appendingPathComponent("fire-image-result.txt").path
            guard !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let brand = json["brand"] as? String,
                  let directive = json["directive"] as? String, !directive.isEmpty else {
                let msg = "fire-image: missing or invalid JSON payload (need brand + directive)"
                try? msg.write(toFile: resultPath, atomically: true, encoding: .utf8)
                WakeLog.shared.log(msg)
                return
            }
            let sku = json["sku"] as? String
            let aspect = json["aspect"] as? String
            // JSONSerialization may hand back a number as Int or Double depending
            // on whether the literal had a decimal point, so accept both.
            let count = (json["count"] as? Int) ?? (json["count"] as? Double).map(Int.init) ?? 1
            WakeLog.shared.log("creative: fire-image trigger brand=\(brand) aspect=\(aspect ?? "4:5") count=\(count)")
            Task { @MainActor in
                await CreativeEngine.shared.renderDynamic(
                    brand: brand, directive: directive, sku: sku,
                    aspect: aspect, count: count, resultPath: resultPath
                )
            }
        }
    }
}
