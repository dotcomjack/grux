import Foundation
import CryptoKit

// Drives the support-email triage flow:
//   read open Outlook tab (or fixture) -> classify each unread message
//   (refund / shipping / product / other) -> draft a brand-voice reply ->
//   stage it in SupportDraftStore for one-tap send.
//
// Nothing sends automatically. Sending is a separate explicit tap in
// SupportDraftsView, which calls sendDraft().
//
// LLM policy (global rule 5): try-local-fall-back-to-Claude. We route through
// AmbientLLM.completeTagged, which prefers the local qwen3:8b proxy on the
// companion service (:3849) and falls back to Claude on any error. qwen3 can leak <think>
// blocks, so we strip them before the JSON brace-scan.
@MainActor
final class EmailTriageEngine {
    static let shared = EmailTriageEngine()
    private init() {}

    private var inFlight = false
    private let graph = MailGraphClient()

    // The inboxes a scheduled run sweeps, from the user's own roster rather
    // than a compiled-in pair. Empty until they configure one, so an
    // unconfigured install sweeps nothing and runHourly returns 0 instead of
    // reading a mailbox that is not theirs.
    static var scheduledInboxes: [SupportInbox] { SupportInbox.roster }

    // MARK: - Public entry points

    // Hourly sweep across the configured inboxes. Skips silently if a sweep is
    // already running.
    @discardableResult
    func runHourly() async -> Int {
        guard !inFlight else { return 0 }
        inFlight = true
        defer { inFlight = false }
        var staged = 0
        // Net "newly waiting" is the staged-count delta across the sweep, so a draft
        // that was staged then immediately auto-sent (LIVE) does not inflate the
        // notification. (stagedCount counts only status == .staged.)
        let beforeWaiting = SupportDraftStore.shared.stagedCount
        for inbox in Self.scheduledInboxes {
            staged += await triage(inbox: inbox, fixturePath: nil)
        }
        let newlyWaiting = max(0, SupportDraftStore.shared.stagedCount - beforeWaiting)
        WakeLog.shared.log("emailTriage: hourly sweep staged \(staged) draft(s), \(newlyWaiting) newly waiting")
        if newlyWaiting > 0 {
            // Surface it so the queue is not silent. Tapping the banner opens
            // the Support Drafts window (handled in AppDelegate.handleAction
            // via kind == "supportDrafts").
            let total = SupportDraftStore.shared.stagedCount
            NotificationManager.shared.sendSupportDraftsReady(newCount: newlyWaiting, totalWaiting: total)
        }
        return staged
    }

    // On-demand smoke test (fire-support-triage-test). When `fixturePath` is
    // empty we fall back to a built-in fixture written to disk so the test is
    // fully deterministic and never needs a live Outlook tab. Writes a summary
    // to `resultPath` for CLI verification and opens the drafts window.
    func runSmokeTest(inbox: SupportInbox, fixturePath: String, resultPath: String) async {
        // Sentinel that exercises the full SEND lifecycle headlessly (card
        // leaves the queue + sent-log written + real Resend delivery). Uses a
        // fixture addressed to this inbox's OWN configured mailbox so the send
        // is deliverable, and can only ever land back with the user.
        if fixturePath == "sendtest" {
            await runSendSmoke(inbox: inbox, resultPath: resultPath)
            return
        }
        // Sentinel: prove the LLM fabrication auditor discriminates, feeding it a
        // paraphrased fabrication (no banned token) and a clean deferral.
        if fixturePath == "audittest" {
            let voice = Self.brandVoice(inbox: inbox)
            let fabricating = "Hi, of course. Since you want to try before committing, I can send you a couple of our scents to try at no charge. I will also knock 20 percent off your first order."
            let clean = "Hi, we do not offer samples. The only saving is 15 percent through Subscribe and Save on a recurring order. Let me know if you would like help setting that up."
            let (f1, r1) = await auditFabrication(reply: fabricating, voice: voice)
            let (f2, r2) = await auditFabrication(reply: clean, voice: voice)
            let banned1 = Self.bannedTokensFound(in: fabricating, voice: voice)
            let out = """
            support-audit-test @ \(ISO8601DateFormatter().string(from: Date()))
            fabricating reply -> auditor flagged: \(f1) reason: \(r1 ?? "none") | token-scan: \(banned1.isEmpty ? "missed (none)" : banned1.joined(separator: ","))
            clean reply        -> auditor flagged: \(f2) reason: \(r2 ?? "none")
            EXPECT: fabricating flagged true (token-scan likely missed the paraphrase), clean flagged false.
            """
            try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
            WakeLog.shared.log("emailTriage: audit test -> \(resultPath)")
            return
        }
        // Sentinel: prove the corrections -> learning loop (Phase 2) end to end.
        // Feeds an AI draft + a user-edited version (a real, non-cosmetic wording
        // change: long and over-apologetic -> short and direct), runs the learner,
        // and reports whether a durable lesson was captured, added as a heuristic,
        // and would be injected into the next draft via the prompt block.
        if fixturePath == "learntest" {
            let voice = Self.brandVoice(inbox: inbox)
            let before = "Hi, thank you so much for reaching out to us. We are so sorry for any inconvenience this may have caused and we truly appreciate your patience. We will look into this right away and get back to you as soon as we possibly can."
            let after = "Hi, looking into your order now and will follow up shortly."
            let draft = SupportDraft(
                id: "learntest-\(Int(Date().timeIntervalSince1970))",
                createdAt: Date(), inbox: inbox, brandVoice: voice, category: .shipping,
                fromName: "Test Customer", fromEmail: "learn-test@example.com",
                subject: "Where is my order", incomingPreview: "where is my order",
                draftReply: after, originalReply: before, urgency: .normal,
                needsReview: false, reviewReason: nil, sourceMessageId: "", status: .sent)
            let beforeCount = CorrectionLessonStore.shared.lessons(forBrand: voice).count
            await CorrectionLearner.learn(from: draft)
            let lessons = CorrectionLessonStore.shared.lessons(forBrand: voice)
            let newest = lessons.first
            let heuristicHit = JaxProfile.shared.heuristics.contains {
                $0.domain == CorrectionLearner.learnDomain(voice) && $0.rule == (newest?.lesson ?? "\u{1}")
            }
            let block = CorrectionLessonStore.shared.promptBlock(forBrand: voice, limit: 6)
            let out = """
            support-learn-test @ \(ISO8601DateFormatter().string(from: Date()))
            voice: \(voice)
            lessons for brand: \(beforeCount) -> \(lessons.count)
            lesson captured: \(newest?.lesson ?? "(none)")
            added as heuristic: \(heuristicHit)
            drafter prompt block present: \(block != nil)
            ---- prompt block ----
            \(block ?? "(nil)")
            EXPECT: a concise lesson captured (brevity / less apology), heuristic added true, block present true.
            """
            try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
            WakeLog.shared.log("emailTriage: learn test -> \(resultPath)")
            return
        }
        // Sentinel: prove the Phase 3 OUTPUT GATE blocks bad outbound copy and
        // allows clean copy. Deterministic, no send.
        if fixturePath == "outputgatetest" {
            let voice = Self.brandVoice(inbox: inbox)
            let clean = "Hi, looking into your order now and will follow up shortly."
            let banned = "Hi, I can send you a free sample and a coupon to try."
            let emdash = "Hi, your order is on its way \u{2014} thanks for your patience."
            func describe(_ d: OutputDecision) -> String { if case .block(let r) = d { return "BLOCK: \(r)" } else { return "ALLOW" } }
            let out = """
            support-output-gate-test @ \(ISO8601DateFormatter().string(from: Date()))
            voice: \(voice)
            clean reply        -> \(describe(OutputGate.vet(replyText: clean, voice: voice, enforceGrounding: true)))
            banned offer reply -> \(describe(OutputGate.vet(replyText: banned, voice: voice, enforceGrounding: false)))
            em dash reply      -> \(describe(OutputGate.vet(replyText: emdash, voice: voice, enforceGrounding: false)))
            empty reply        -> \(describe(OutputGate.vet(replyText: "   ", voice: voice, enforceGrounding: false)))
            EXPECT: clean ALLOW, banned BLOCK, em dash BLOCK, empty BLOCK.
            """
            try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
            WakeLog.shared.log("emailTriage: output-gate test -> \(resultPath)")
            return
        }
        // Sentinel: prove Phase 4 graduation + LIVE auto-send end to end. Seeds a
        // throwaway brand to readiness (logic check), then on a real brand: flips
        // to LIVE, refuses a banned-offer auto-send (output gate), and delivers a
        // clean auto-send to the inbox's own configured mailbox (safe
        // self-delivery). Resets the ledger afterward so the real autonomy record
        // is untouched.
        if fixturePath == "gradtest" {
            let probe = "gradtest-probe"
            AutonomyLedger.shared.reset(brand: probe)
            for _ in 0..<AutonomyLedger.minCleanSends { AutonomyLedger.shared.recordSent(brand: probe, edited: false) }
            let readyClean = AutonomyLedger.shared.graduationReady(forBrand: probe)
            for _ in 0..<6 { AutonomyLedger.shared.recordSent(brand: probe, edited: true) }
            let readyAfterEdits = AutonomyLedger.shared.graduationReady(forBrand: probe)
            // LIVE-mode gating on the THROWAWAY brand only: graduating flips the
            // mode, after which the brand is no longer "ready". We never set a real
            // brand to LIVE in a test, so a concurrent hourly sweep can never enter
            // an auto-send window opened here.
            AutonomyLedger.shared.reset(brand: probe)
            for _ in 0..<AutonomyLedger.minCleanSends { AutonomyLedger.shared.recordSent(brand: probe, edited: false) }
            AutonomyLedger.shared.setMode(.live, forBrand: probe)
            let liveMode = AutonomyLedger.shared.mode(forBrand: probe)
            let readyAfterLive = AutonomyLedger.shared.graduationReady(forBrand: probe)
            AutonomyLedger.shared.reset(brand: probe)

            // Send-path checks go through sendDraft(auto: true) DIRECTLY, which
            // runs the same output gate + ledger recording as the live sweep,
            // without ever flipping a real brand to LIVE. Delivery goes to this
            // inbox's own configured mailbox, so the test can only ever mail the
            // user. With no mailbox configured there is no safe destination, so
            // the send half reports SKIPPED rather than mailing anyone.
            let voice = Self.brandVoice(inbox: inbox)
            let selfAddress = Self.replyToAddress(inbox: inbox)
            var sendLines: [String]
            if selfAddress.isEmpty {
                sendLines = [
                    "BLOCK path (banned offer): SKIPPED, no mailbox configured for the \(inbox.rawValue) inbox",
                    "ALLOW path (clean): SKIPPED, no mailbox configured for the \(inbox.rawValue) inbox"
                ]
            } else {
                AutonomyLedger.shared.reset(brand: voice)

                let bannedId = "gradtest-banned-\(Int(Date().timeIntervalSince1970))"
                SupportDraftStore.shared.upsert(SupportDraft(
                    id: bannedId, createdAt: Date(), inbox: inbox, brandVoice: voice, category: .product,
                    fromName: "Test", fromEmail: selfAddress, subject: "gradtest banned offer",
                    incomingPreview: "", draftReply: "Hi, I can send you a free sample and a coupon to try.",
                    originalReply: "x", urgency: .normal, needsReview: false, reviewReason: nil,
                    sourceMessageId: "", status: .staged, confidence: 0.95))
                let blocksBefore = AutonomyLedger.shared.record(forBrand: voice).gateBlocks
                let blockRes = await sendDraft(bannedId, auto: true)
                let blocksAfter = AutonomyLedger.shared.record(forBrand: voice).gateBlocks
                let blockedOK: Bool = { if case .failure = blockRes { return true } else { return false } }()

                let cleanText = "Hi, looking into your order now and will follow up shortly."
                let cleanId = "gradtest-clean-\(Int(Date().timeIntervalSince1970))"
                SupportDraftStore.shared.upsert(SupportDraft(
                    id: cleanId, createdAt: Date(), inbox: inbox, brandVoice: voice, category: .shipping,
                    fromName: "Test", fromEmail: selfAddress, subject: "gradtest auto-send",
                    incomingPreview: "", draftReply: cleanText, originalReply: cleanText, urgency: .normal,
                    needsReview: false, reviewReason: nil, sourceMessageId: "", status: .staged, confidence: 0.95))
                let cleanBefore = AutonomyLedger.shared.record(forBrand: voice).sentClean
                let sendRes = await sendDraft(cleanId, auto: true)
                let cleanAfter = AutonomyLedger.shared.record(forBrand: voice).sentClean
                let sentOK: Bool = { if case .success = sendRes { return true } else { return false } }()
                let finalStatus = SupportDraftStore.shared.drafts.first(where: { $0.id == cleanId })?.status
                // Leave the real records clean: drop the ledger entry and both test
                // drafts so nothing test-shaped lingers in the queue.
                AutonomyLedger.shared.reset(brand: voice)
                SupportDraftStore.shared.remove(bannedId)
                SupportDraftStore.shared.remove(cleanId)

                sendLines = [
                    "BLOCK path (banned offer): auto-send refused = \(blockedOK), gateBlocks \(blocksBefore) -> \(blocksAfter)",
                    "ALLOW path (clean): auto-send delivered = \(sentOK), draft status = \(finalStatus.map { String(describing: $0) } ?? "?"), sentClean \(cleanBefore) -> \(cleanAfter)"
                ]
            }

            let out = """
            support-grad-test @ \(ISO8601DateFormatter().string(from: Date()))
            graduation ready after \(AutonomyLedger.minCleanSends) clean sends: \(readyClean)
            graduation ready after edits push edit-rate up: \(readyAfterEdits)
            probe mode after setMode(.live): \(liveMode.rawValue); ready while live: \(readyAfterLive)
            \(sendLines.joined(separator: "\n"))
            (\(voice) ledger + test drafts removed after test; \(voice) never set LIVE)
            EXPECT: ready true, ready-after-edits false, probe mode live + ready-while-live false, banned refused + gateBlocks +1, clean delivered + status sent + sentClean +1.
            """
            try? out.write(toFile: resultPath, atomically: true, encoding: .utf8)
            WakeLog.shared.log("emailTriage: grad test -> \(resultPath)")
            return
        }
        let path: String
        if fixturePath.isEmpty {
            path = Self.writeBuiltinFixture(for: inbox)
        } else {
            path = fixturePath
        }
        let before = SupportDraftStore.shared.drafts.count
        let staged = await triage(inbox: inbox, fixturePath: path)
        let after = SupportDraftStore.shared.drafts

        var lines: [String] = []
        lines.append("support-triage-test @ \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("inbox: \(inbox.displayName)")
        lines.append("fixture: \(path)")
        lines.append("messages staged this run: \(staged) (store \(before) -> \(after.count))")
        for d in after.prefix(staged) {
            lines.append("---")
            lines.append("from: \(d.fromName) <\(d.fromEmail)>")
            lines.append("category: \(d.category.label) | urgency: \(d.urgency.label) | review: \(d.needsReview) | voice: \(d.brandVoice)")
            lines.append("subject: Re: \(d.subject)")
            let banned = Self.bannedTokensFound(in: d.draftReply, voice: d.brandVoice)
            lines.append("banned_offers_found: \(banned.isEmpty ? "none" : banned.joined(separator: ", "))")
            lines.append("review_reason: \(d.reviewReason ?? "none")")
            lines.append("reply:")
            lines.append(d.draftReply)
        }
        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
        WakeLog.shared.log("emailTriage: smoke test staged \(staged) draft(s) -> \(resultPath)")
        WindowOpener.openSupportDrafts()
    }

    // Exercises the send lifecycle end to end: stage one draft addressed to this
    // inbox's own configured mailbox, send it, and report that it left the active
    // queue, landed in Done, wrote the sent-log, and got a real Resend id.
    private func runSendSmoke(inbox: SupportInbox, resultPath: String) async {
        // Self-delivery only. With no mailbox configured for this inbox there is
        // no address the test may safely mail, so it reports that and stops.
        let selfAddress = Self.replyToAddress(inbox: inbox)
        guard !selfAddress.isEmpty else {
            let msg = """
            support-send-smoke @ \(ISO8601DateFormatter().string(from: Date()))
            SKIPPED: no mailbox is configured for the \(inbox.rawValue) inbox, so there is no
            self-delivery address to send to. Add the account (or its Graph mailbox) and re-run.
            """
            try? msg.write(toFile: resultPath, atomically: true, encoding: .utf8)
            return
        }
        let dir = SupportDraftStore.rootDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixtureURL = dir.appendingPathComponent("send-smoke-fixture.json")
        let sample = [InboxMessage(
            fromName: "Grux Send Smoke",
            fromEmail: selfAddress,
            subject: "Send lifecycle smoke test",
            preview: "This is a deliverable smoke test for the support send path. A short friendly acknowledgement is fine.",
            messageId: ""
        )]
        if let data = try? JSONEncoder().encode(sample) { try? data.write(to: fixtureURL, options: .atomic) }

        let staged = await triage(inbox: inbox, fixturePath: fixtureURL.path)
        var lines: [String] = ["support-send-smoke @ \(ISO8601DateFormatter().string(from: Date()))",
                               "staged this run: \(staged)"]
        guard let target = SupportDraftStore.shared.activeDrafts.first(where: { $0.fromEmail == selfAddress }) else {
            lines.append("FAIL: no staged draft to send")
            try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
            return
        }
        let activeBefore = SupportDraftStore.shared.activeDrafts.count
        let result = await sendDraft(target.id)
        let activeAfter = SupportDraftStore.shared.activeDrafts.count
        let nowSent = SupportDraftStore.shared.drafts.first(where: { $0.id == target.id })?.status == .sent
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let sentLog = dir.appendingPathComponent("sent-\(f.string(from: Date())).jsonl")
        let logExists = FileManager.default.fileExists(atPath: sentLog.path)
        switch result {
        case .success(let id): lines.append("send: SUCCESS resend_id=\(id)")
        case .failure(let e): lines.append("send: FAIL \(e.localizedDescription)")
        }
        lines.append("active queue: \(activeBefore) -> \(activeAfter) (card left queue: \(activeAfter < activeBefore))")
        lines.append("status==sent: \(nowSent)")
        lines.append("sent-log written: \(logExists) (\(sentLog.lastPathComponent))")
        lines.append("in Done section: \(SupportDraftStore.shared.doneDrafts.contains(where: { $0.id == target.id }))")
        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
        WindowOpener.openSupportDrafts()
    }

    // MARK: - Core

    // Triage a batch of IMAP-fetched messages through the same classify/draft/
    // audit/stage path the webmail scraper uses. Returns drafts staged.
    @discardableResult
    func triageFetched(inbox: SupportInbox, messages: [InboxMessage]) async -> Int {
        guard !messages.isEmpty else { return 0 }
        let dir = SupportDraftStore.rootDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("imap-fetch-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? JSONEncoder().encode(messages) else { return 0 }
        try? data.write(to: url, options: .atomic)
        return await triage(inbox: inbox, fixturePath: url.path)
    }

    // Read unread for an inbox. A fixture path forces the deterministic fixture.
    // Otherwise prefer Microsoft Graph (direct, headless M365 API) when this
    // inbox is configured, and fall back to scraping the open Outlook tab if
    // Graph is not set up or errors. This is what lets the sweep run with no tab.
    private func readUnread(inbox: SupportInbox, fixturePath: String?) async -> [InboxMessage] {
        if let fixturePath, !fixturePath.isEmpty {
            return OutlookReader.readUnread(inbox: inbox, fixturePath: fixturePath)
        }
        if GraphMailStore.shared.isConfigured(forInbox: inbox.rawValue),
           let cfg = GraphMailStore.shared.clientConfig(),
           let mailbox = GraphMailStore.shared.mailboxAddress(forInbox: inbox.rawValue) {
            do {
                let msgs = try await graph.unread(mailbox: mailbox, config: cfg)
                WakeLog.shared.log("emailTriage: graph read \(msgs.count) unread for \(mailbox)")
                return msgs
            } catch {
                WakeLog.shared.log("emailTriage: graph read failed for \(inbox.rawValue) (\(error.localizedDescription)); falling back to tab")
            }
        }
        return OutlookReader.readUnread(inbox: inbox, fixturePath: nil)
    }

    @discardableResult
    private func triage(inbox: SupportInbox, fixturePath: String?) async -> Int {
        let messages = await readUnread(inbox: inbox, fixturePath: fixturePath)
        guard !messages.isEmpty else { return 0 }

        var staged = 0
        var autoAttemptsThisSweep = 0
        for msg in messages {
            // A reply needs a destination. OWA list-row scraping often does not
            // expose the sender address, so skip (and log) rather than stage a
            // draft that can never be sent. The fixture path always carries an
            // address, so smoke tests are unaffected.
            guard !msg.fromEmail.trimmingCharacters(in: .whitespaces).isEmpty else {
                WakeLog.shared.log("emailTriage: no sender address parsed, skipping: \(msg.subject.prefix(60))")
                continue
            }
            // Skip if we already staged a draft for this exact sender+subject
            // that is still waiting or already sent, so the hourly sweep does
            // not pile up duplicates of the same unread thread.
            let dupId = Self.draftId(inbox: inbox, msg: msg)
            if let existing = SupportDraftStore.shared.drafts.first(where: { $0.id == dupId }),
               existing.status == .staged || existing.status == .sent {
                continue
            }
            // Reply-policy gate (pre-draft): a muted sender or a disabled email
            // KIND (no-reply/automated, marketing) is skipped BEFORE the expensive
            // classify+draft, so Jax spends no model call (and stages no draft) on
            // mail this brand should not auto-reply to. This is what stops the
            // no-reply / marketing drafts (e.g. Walmart Marketplace no-reply).
            let voice = Self.brandVoice(inbox: inbox)
            switch ReplyPolicyGate.decide(
                fromEmail: msg.fromEmail, fromName: msg.fromName, subject: msg.subject,
                isBulk: msg.isBulk, isAutoSubmitted: msg.isAutoSubmitted, brand: voice) {
            case .skip(let reason, let kind):
                WakeLog.shared.log("emailTriage: not drafting (\(reason)) for \(msg.fromEmail): \(msg.subject.prefix(60))")
                Self.recordFiltered(inbox: inbox, msg: msg, voice: voice, dupId: dupId, kind: kind)
                continue
            case .proceed:
                break
            }
            guard let result = await classifyAndDraft(inbox: inbox, msg: msg) else { continue }
            // Category filter (post-classify): the brand may have this support
            // category disabled in its reply rules. Skip staging (and record it as
            // filtered) if so.
            if !ReplyPolicyGate.allowsCategory(result.category, brand: voice) {
                WakeLog.shared.log("emailTriage: not drafting (category \(result.category.rawValue) disabled for \(voice)) for \(msg.fromEmail)")
                FilteredMailStore.shared.record(FilteredMail(
                    id: dupId, filteredAt: Date(), inbox: inbox, brand: voice,
                    fromName: msg.fromName, fromEmail: msg.fromEmail, subject: msg.subject,
                    preview: msg.preview, body: msg.body,
                    reason: "Category \(result.category.label) off",
                    kind: nil, category: result.category.rawValue))
                continue
            }
            if await stageClassified(inbox: inbox, msg: msg, voice: voice, dupId: dupId, result: result) {
                staged += 1
                // Phase 4: in LIVE mode for this brand, auto-send the safe ones, up
                // to a per-sweep circuit breaker. The breaker counts ATTEMPTS (sent
                // or gate-blocked/failed), not just successes, so a burst of unread
                // mail (or a classifier regression producing blockable drafts) can
                // never drive unbounded send attempts in one run. Beyond the cap,
                // drafts stay staged for review.
                if AutonomyLedger.shared.mode(forBrand: voice) == .live {
                    if autoAttemptsThisSweep >= Self.maxAutoSendsPerSweep {
                        WakeLog.shared.log("emailTriage: auto-send cap (\(Self.maxAutoSendsPerSweep)) reached this sweep; leaving \(msg.fromEmail) for review")
                    } else {
                        switch await maybeAutoSend(dupId: dupId, voice: voice) {
                        case .sent, .attempted: autoAttemptsThisSweep += 1
                        case .held: break
                        }
                    }
                }
            }
        }
        return staged
    }

    // Circuit breaker: the most replies one sweep may auto-send. A burst beyond
    // this is held for review rather than blasted out.
    static let maxAutoSendsPerSweep = 5

    // Phase 4 graduation: when a brand has been promoted to LIVE, auto-send a
    // freshly staged draft IF it clears every safety bar. High-stakes (needsReview:
    // refund / angry / fabrication-flagged) and low-confidence drafts always stay
    // for a human. The output gate (run inside sendDraft with grounding enforced)
    // is the final floor; a block leaves the draft staged + flagged. OBSERVE brands
    // never reach here, so nothing auto-sends until the user explicitly graduates
    // one.
    // Outcome of an auto-send consideration. `.held` never reached a send (not
    // eligible), `.attempted` reached sendDraft but did not deliver (gate block or
    // Resend error), `.sent` delivered. The circuit breaker counts .attempted and
    // .sent; .held is free.
    private enum AutoSendOutcome { case sent, attempted, held }

    private func maybeAutoSend(dupId: String, voice: String) async -> AutoSendOutcome {
        // Global hard stop wins over everything: if Jax autonomy is killed, nothing
        // auto-sends regardless of per-brand mode.
        guard !AutonomyController.shared.killed else { return .held }
        guard AutonomyLedger.shared.mode(forBrand: voice) == .live else { return .held }
        guard let draft = SupportDraftStore.shared.drafts.first(where: { $0.id == dupId }),
              draft.status == .staged else { return .held }
        guard !draft.needsReview, (draft.confidence ?? 0) >= 0.8 else {
            WakeLog.shared.log("emailTriage: LIVE but holding \(draft.fromEmail) for review (needsReview=\(draft.needsReview), confidence=\(draft.confidence ?? 0))")
            return .held
        }
        switch await sendDraft(dupId, auto: true) {
        case .success(let mid):
            WakeLog.shared.log("emailTriage: AUTO-SENT \(voice) reply to \(draft.fromEmail) (\(mid))")
            return .sent
        case .failure(let e):
            WakeLog.shared.log("emailTriage: auto-send not completed for \(draft.fromEmail): \(e.localizedDescription)")
            return .attempted
        }
    }

    // Build the staged draft from a classification result: clean the reply, run
    // the fabrication + catalog + cognition gates, and upsert it. Shared by the
    // hourly sweep and by "Draft anyway" (which reaches it bypassing the policy
    // gate). Returns true once a draft is staged.
    @discardableResult
    private func stageClassified(inbox: SupportInbox, msg: InboxMessage, voice: String,
                                 dupId: String, result: TriageResult) async -> Bool {
        let cleanReply = DashSanitizer.clean(result.reply)
        // Defense in depth, two layers. Both force human review so a slip
        // can never one-tap out:
        //   1) bannedTokensFound: fast literal scan (samples, coupons, ...).
        //   2) auditFabrication: an LLM that compares the reply to the brand
        //      rules and catches paraphrased fabrications the token list
        //      misses ("I can send you a couple to try").
        let banned = Self.bannedTokensFound(in: cleanReply, voice: voice)
        let (audited, auditReason) = await auditFabrication(reply: cleanReply, voice: voice)
        // POST grounding (catalog): catch a wrong-but-plausible product NUMBER the
        // fabrication auditor treats as an allowed fact. Only a voice with catalog
        // ground truth is checked; other voices pass.
        // The brief names the brand so GroundingGate can look it up; it used to
        // special-case one brand's token, which meant every other brand went to
        // the gate as a bare word it could not recognise. FactGuard reads its
        // brand keys from the catalog, so an unknown brand simply detects
        // nothing and the draft passes, exactly as before.
        let catalogVerdict = GroundingGate.vet(draft: cleanReply, brief: "\(voice) support reply")
        let catalogReason = catalogVerdict.surfaceable ? nil : catalogVerdict.refusalLine
        if let cr = catalogReason { WakeLog.shared.log("emailTriage: catalog grounding flagged \(msg.subject.prefix(40)): \(cr)") }
        // JAX cognition pass: route this triage decision through Jax (retrieve
        // you-ness memory, fire heuristics, never-guess ConfidenceGate) and
        // record a real CognitionEvent so the decision shows in the Cognition
        // Map. TRUE confusion escalates needsReview so a confusing email is
        // never auto-drafted with false confidence.
        let cog = await EmailCognition.assess(
            subject: msg.subject,
            thread: (msg.body?.isEmpty == false) ? msg.body! : msg.preview,
            category: String(describing: result.category), draft: cleanReply, voice: voice,
            correlationId: dupId)
        let reviewReason = Self.combinedReviewReason(
            banned: banned,
            auditReason: (audited ? auditReason : nil) ?? catalogReason ?? cog.humanReason)
        if reviewReason != nil {
            WakeLog.shared.log("emailTriage: review flagged (\(reviewReason!)) for \(msg.subject.prefix(40))")
        }
        let draft = SupportDraft(
            id: dupId,
            createdAt: Date(),
            inbox: inbox,
            brandVoice: voice,
            category: result.category,
            fromName: msg.fromName,
            fromEmail: msg.fromEmail,
            subject: msg.subject,
            incomingPreview: msg.preview,
            draftReply: cleanReply,
            originalReply: cleanReply,
            urgency: result.urgency,
            needsReview: result.needsReview || !banned.isEmpty || audited || (catalogReason != nil) || cog.needsHuman,
            reviewReason: reviewReason,
            sourceMessageId: msg.messageId,
            status: .staged,
            confidence: cog.verdict.confidence
        )
        SupportDraftStore.shared.upsert(draft)
        return true
    }

    // Record a gate-skipped message into the Filtered list so the skip is visible
    // and actionable. The kind comes straight from the gate's decision: nil means
    // a muted sender (kind is irrelevant), a value means a disabled kind so the UI
    // can offer "Enable this kind". No re-derivation, so it cannot drift from the
    // gate's own classification.
    private static func recordFiltered(inbox: SupportInbox, msg: InboxMessage,
                                       voice: String, dupId: String, kind: EmailKind?) {
        FilteredMailStore.shared.record(FilteredMail(
            id: dupId, filteredAt: Date(), inbox: inbox, brand: voice,
            fromName: msg.fromName, fromEmail: msg.fromEmail, subject: msg.subject,
            preview: msg.preview, body: msg.body,
            reason: kind?.label ?? "Muted sender",
            kind: kind?.rawValue, category: nil))
    }

    // LLM compliance auditor (belt and suspenders beyond bannedTokensFound).
    // Catches PARAPHRASED fabrications the token list misses ("I can send you a
    // couple to try" instead of "sample"). Audits the drafted reply against the
    // brand's own rules and flags anything offered/claimed that the rules do not
    // support. A reply that defers or asks a question is NOT flagged. Local-first
    // via AmbientLLM; on any error it does NOT flag (the prompt guard + token
    // scanner remain), so an LLM outage never blocks the whole queue.
    // Returns (flagged, shortReason).
    func auditFabrication(reply: String, voice: String) async -> (Bool, String?) {
        let system = """
        You are a strict compliance auditor for a brand's customer-support
        replies. You are given the brand's ALLOWED FACTS and a NOT-SUPPORTED
        list, then a DRAFTED REPLY. Decide whether the reply commits the brand to
        anything it does not support.

        Flag (fabricated:true) if the reply offers, promises, confirms, or
        implies anything in the NOT-SUPPORTED list or anything not in ALLOWED
        FACTS. This includes SOFT or IMPLIED offers ("I'd be happy to work
        something out", "you'll have it by Friday") and AGREEING with a
        customer's own assumption about an ingredient or attribute (echoing the
        customer's premise does NOT make it allowed).

        Do NOT flag a reply that declines, defers, or asks a question. Naming a
        not-supported item in order to DENY it ("we do not offer samples",
        "there is no coupon") is CORRECT, do not flag. Stating an ALLOWED FACT
        (for example the real 15% Subscribe and Save saving on a recurring order)
        is CORRECT, do not flag. Only flag a NEW commitment the brand does not
        support. Never use em dashes or en dashes.

        End your reply with a single JSON object and nothing after it:
        {"fabricated": true, "what": "<=8 words"} or {"fabricated": false, "what": ""}
        """
        let user = """
        \(Self.auditRules(voice: voice))

        DRAFTED REPLY:
        \(reply)
        """
        do {
            let res = try await AmbientLLM.completeTagged(
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 400, temperature: 0.0, featureTag: "support_fabrication_audit"
            )
            guard let obj = Self.extractJSONObject(Self.stripThink(res.text)) else {
                // Safe bias: we could not read a verdict (qwen think ran past the
                // budget, malformed JSON, etc). The auditor never blocks a send,
                // it only flags for review, so an unverifiable draft should be
                // SEEN by a human, not silently passed.
                return (true, "auditor inconclusive")
            }
            // Accept a real JSON bool or a stringified "true"/"false".
            let flagged: Bool
            if let b = obj["fabricated"] as? Bool { flagged = b }
            else if let s = obj["fabricated"] as? String { flagged = s.lowercased() == "true" }
            else { flagged = false }
            guard flagged else { return (false, nil) }
            let what = (obj["what"] as? String).map {
                DashSanitizer.clean($0).trimmingCharacters(in: .whitespaces)
            } ?? ""
            return (true, what.isEmpty ? "unsupported claim" : what)
        } catch {
            // Same safe bias on outage: flag rather than silently pass.
            return (true, "auditor inconclusive")
        }
    }

    // Compact, auditor-focused fact ledger for a brand. Deliberately NOT the full
    // drafting systemPrompt (whose voice/sign-off/style instructions dilute a
    // weak local model's attention): just what the brand supports vs does not.
    // Built from the user's own brand profile; with no profile the ledger is
    // empty, which is the strictest possible reading (nothing is an allowed
    // fact) rather than an error.
    static func auditRules(voice: String) -> String {
        let profile = SupportBrandProfileStore.profile(for: voice)
        guard !profile.isEmpty else {
            return """
            BRAND: not configured. There is no fact sheet for this brand, so
            NOTHING counts as an allowed fact.
            ALLOWED FACTS: only what the customer stated in their own message,
            plus an offer to look into it and follow up.
            NOT SUPPORTED (flag if the reply offers, confirms, or implies any):
            any product, price, discount, coupon, sample, shipping promise,
            refund or return window, ingredient, allergen, attribute, safety
            judgment, delivery date, timeline, or policy.
            """
        }
        var out = "BRAND: \(profile.displayName(fallback: voice))."
        if profile.facts.isEmpty {
            out += "\nALLOWED FACTS: none recorded, so treat every specific claim as unsupported."
        } else {
            out += "\nALLOWED FACTS (the only things the brand supports):\n"
            out += profile.facts.map { "- \($0)" }.joined(separator: "\n")
        }
        out += "\nNOT SUPPORTED (flag if the reply offers, confirms, or implies any):\n"
        out += profile.forbidden.isEmpty
            ? "anything that is not in ALLOWED FACTS above."
            : profile.forbidden.map { "- \($0)" }.joined(separator: "\n")
        return out
    }

    private struct TriageResult {
        let category: SupportCategory
        let urgency: SupportUrgency
        let needsReview: Bool
        let reply: String
    }

    private func classifyAndDraft(inbox: SupportInbox, msg: InboxMessage) async -> TriageResult? {
        let voice = Self.brandVoice(inbox: inbox)
        let system = Self.systemPrompt(voice: voice)
        // Prefer the full body (which includes the quoted thread) over the short
        // list preview, so the drafter can read the whole conversation.
        let hasThread = !(msg.body ?? "").isEmpty
        let conversation = hasThread ? msg.body! : msg.preview
        // Phase 2: apply what Jax learned from the user's past edits. The brand's most
        // recent lessons are injected so this draft already reflects the
        // corrections, closing the learn loop.
        let lessonsBlock = CorrectionLessonStore.shared.promptBlock(forBrand: voice, limit: 6) ?? ""
        let user = """
        An unread support email arrived. Classify it, judge urgency, and draft a reply.

        From: \(msg.fromName) <\(msg.fromEmail)>
        Subject: \(msg.subject)
        \(hasThread
          ? "FULL EMAIL THREAD below (the newest message is at the top; earlier quoted messages, usually prefixed with \">\", follow). Read the WHOLE thread before drafting:"
          : "Message (inbox preview, may be truncated):")
        \(conversation)
        \(lessonsBlock)

        Return ONLY a JSON object, no prose, no markdown fences:
        {
          "category": "refund" | "shipping" | "product" | "other",
          "urgency": "high" | "normal" | "low",
          "needs_review": true | false,
          "reply": "the full reply body, ready to send, signed appropriately"
        }
        THREAD AWARENESS (critical): draft a reply that ADVANCES the conversation
        given everything already said. Do NOT ask for information the customer has
        already provided, and do NOT re-ask a question they already answered or
        said they cannot answer. If they said they cannot find something (e.g. an
        order number) and asked you to look it up, acknowledge that and offer the
        next step you can actually take (look it up by their email address or name,
        or escalate to a person), instead of repeating the request.

        Urgency "high" for an angry, upset, time-sensitive, refund, chargeback,
        or legal-sounding message; "low" for a simple FYI or thank-you; "normal"
        otherwise. Set needs_review true whenever the reply commits to anything
        sensitive (money, a refund, a legal point, an apology for a real failure)
        or the customer is clearly upset, so a person reads it carefully before send.
        The reply must follow the brand voice rules in the system prompt. Do not
        invent order numbers, tracking numbers, or policies you were not given;
        if specifics are needed and not already refused, ask the customer politely.
        Never use em dashes or en dashes.
        """
        do {
            let res = try await AmbientLLM.completeTagged(
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 700,
                temperature: 0.4,
                featureTag: "support_triage"
            )
            let cleaned = Self.stripThink(res.text)
            guard let obj = Self.extractJSONObject(cleaned) else {
                WakeLog.shared.log("emailTriage: could not parse JSON from drafter for \(msg.subject.prefix(40))")
                return nil
            }
            let catRaw = (obj["category"] as? String)?.lowercased() ?? "other"
            let category = SupportCategory(rawValue: catRaw) ?? .other
            let urgencyRaw = (obj["urgency"] as? String)?.lowercased() ?? "normal"
            var urgency = SupportUrgency(rawValue: urgencyRaw) ?? .normal
            var needsReview = (obj["needs_review"] as? Bool) ?? false
            // Refunds and chargebacks always get the human-review flag and at
            // least normal urgency, regardless of what the model returned.
            if category == .refund {
                needsReview = true
                if urgency == .low { urgency = .normal }
            }
            let reply = (obj["reply"] as? String) ?? ""
            guard !reply.isEmpty else { return nil }
            return TriageResult(category: category, urgency: urgency, needsReview: needsReview, reply: reply)
        } catch {
            WakeLog.shared.log("emailTriage: drafter failed for \(msg.subject.prefix(40)): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Send (called from the UI on the user's tap)

    @discardableResult
    func sendDraft(_ id: String, auto: Bool = false) async -> Result<String, Error> {
        guard let draft = SupportDraftStore.shared.drafts.first(where: { $0.id == id }) else {
            return .failure(ResendError.notFound("draft \(id)"))
        }
        // Idempotency: only a staged draft may be sent. This makes the send safe
        // against two UI surfaces (or an auto-send racing a manual tap) firing the
        // same id, which would otherwise double-deliver and double-count the ledger.
        guard draft.status == .staged else {
            return .failure(NSError(domain: "SupportSend", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "draft \(id) is \(draft.status.rawValue), not staged"]))
        }
        // The autonomy kill switch stops ALL auto-sends regardless of caller (so a
        // direct sendDraft(auto:true) cannot bypass it). Manual sends are the
        // user's explicit action and are unaffected.
        if auto, AutonomyController.shared.killed {
            return .failure(NSError(domain: "SupportSend", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "autonomy kill switch is on"]))
        }
        // Send AS the mailbox this thread arrived on, which is the only address
        // this copy of Grux is entitled to use. Unconfigured means there is no
        // such address, so the send is refused rather than sent from someone
        // else's identity.
        let from = Self.fromAddress(inbox: draft.inbox)
        let replyTo = Self.replyToAddress(inbox: draft.inbox)
        guard !from.isEmpty else {
            return .failure(NSError(domain: "SupportSend", code: 4,
                                    userInfo: [NSLocalizedDescriptionKey: "no sending address is configured for the \(draft.inbox.rawValue) inbox"]))
        }
        let subject = draft.subject.lowercased().hasPrefix("re:") ? draft.subject : "Re: \(draft.subject)"
        // Phase 3 OUTPUT GATE: vet the FINAL outbound text before it can leave.
        // Tier-1 checks (banned offers, em/en dash, empty) block every send; catalog
        // grounding is enforced only for auto-sends, where no human reviewed it. A
        // block refuses the send, flags the draft with the reason, and records it
        // against the brand's autonomy track record.
        switch OutputGate.vet(replyText: draft.draftReply, voice: draft.brandVoice, enforceGrounding: auto) {
        case .block(let reason):
            AutonomyLedger.shared.recordGateBlock(brand: draft.brandVoice)
            SupportDraftStore.shared.update(id) {
                $0.needsReview = true
                $0.reviewReason = "output gate: \(reason)"
                $0.lastError = "Output gate blocked send: \(reason)"
            }
            WakeLog.shared.log("emailTriage: OUTPUT GATE blocked \(auto ? "auto-" : "")send for \(draft.fromEmail): \(reason)")
            return .failure(NSError(domain: "OutputGate", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Output gate blocked send: \(reason)"]))
        case .allow:
            break
        }
        do {
            let result = try await ResendClient().send(
                from: from,
                to: [draft.fromEmail],
                subject: subject,
                text: draft.draftReply,
                // Wrap the reply in the brand's real HTML email format; the plain
                // text above remains the fallback for text-only clients.
                html: BrandEmailTemplate.html(voice: draft.brandVoice, replyText: draft.draftReply),
                listUnsubscribe: nil,                 // transactional support reply
                replyTo: replyTo,
                inReplyTo: draft.sourceMessageId.isEmpty ? nil : draft.sourceMessageId
            )
            SupportDraftStore.shared.update(id) {
                $0.status = .sent
                $0.sentMessageId = result.id
                $0.lastError = nil
            }
            let edited = draft.draftReply != draft.originalReply
            logSent(draft: draft, subject: subject, messageId: result.id, edited: edited)
            // Phase 4: record the send against the brand's autonomy track record so
            // graduation readiness reflects how often Jax got it right unedited.
            AutonomyLedger.shared.recordSent(brand: draft.brandVoice, edited: edited)
            // Phase 2: the send already succeeded; if the user edited the draft, learn
            // a durable lesson from the correction (no-ops for cosmetic edits).
            if edited { await CorrectionLearner.learn(from: draft) }
            return .success(result.id)
        } catch {
            // Keep the draft STAGED (not .failed) so a transient Resend/network
            // error stays in the active queue and is retryable, mirroring the
            // output-gate block path. lastError carries the reason for the UI; the
            // status-guard above makes a retry idempotent. (.failed is never set, so
            // a draft can never be stranded outside both the active and done lists.)
            SupportDraftStore.shared.update(id) {
                $0.lastError = error.localizedDescription
            }
            return .failure(error)
        }
    }

    // Append a sent record to ~/.grux/support/sent-YYYY-MM-DD.jsonl. Captures
    // both the original draft and the final (possibly edited) text so the
    // drafts can be calibrated to the user's voice over time.
    private func logSent(draft: SupportDraft, subject: String, messageId: String, edited: Bool) {
        let dir = SupportDraftStore.rootDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("sent-\(f.string(from: Date())).jsonl")
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "to": draft.fromEmail,
            "subject": subject,
            "category": draft.category.rawValue,
            "urgency": draft.urgency.rawValue,
            "needs_review": draft.needsReview,
            "voice": draft.brandVoice,
            "inbox": draft.inbox.rawValue,
            "messageId": messageId,
            "edited": edited,
            "original": draft.originalReply,
            "final": draft.draftReply
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // Persist in-editor edits to subject + reply (called on each keystroke from
    // the UI). originalReply is left untouched so edit-capture can compare.
    func persistEdit(_ id: String, subject: String, reply: String) {
        SupportDraftStore.shared.update(id) {
            $0.subject = subject
            $0.draftReply = reply
        }
    }

    // Mark a draft dismissed (leaves activeDrafts, lands in the Done section).
    func dismiss(_ id: String) {
        SupportDraftStore.shared.update(id) { $0.status = .dismissed }
    }

    // Hide a sender (the "Hide sender" control on a draft card / Mailbox row).
    // Mutes the address so future sweeps never draft for it, and dismisses every
    // staged draft already waiting from that exact address.
    func hideSenderEmail(_ email: String) {
        SenderSuppressionStore.shared.muteEmail(email)
        dismissStagedDrafts { $0.caseInsensitiveCompare(email) == .orderedSame }
    }

    // Hide a whole domain (accepts "walmart.com" or "@walmart.com"). Mutes it and
    // dismisses every staged draft from that domain or any subdomain of it.
    func hideSenderDomain(_ domain: String) {
        SenderSuppressionStore.shared.muteDomain(domain)
        let bare = (domain.hasPrefix("@") ? String(domain.dropFirst()) : domain).lowercased()
        dismissStagedDrafts { addr in
            guard let d = SenderSuppressionStore.domain(of: addr) else { return false }
            return d == bare || d.hasSuffix("." + bare)
        }
    }

    private func dismissStagedDrafts(_ match: (String) -> Bool) {
        for draft in SupportDraftStore.shared.drafts
        where draft.status == .staged && match(draft.fromEmail) {
            dismiss(draft.id)
        }
    }

    // MARK: Filtered-mail actions (the Jax HQ "Filtered" list)

    // Draft anyway: override the policy gate for ONE filtered message. Rebuilds
    // the message from the stored record and runs the normal classify + stage
    // path (skipping the gate + category filter), then drops it from the list.
    @discardableResult
    func draftFiltered(_ id: String) async -> Bool {
        guard let item = FilteredMailStore.shared.items.first(where: { $0.id == id }) else { return false }
        let msg = InboxMessage(
            fromName: item.fromName, fromEmail: item.fromEmail, subject: item.subject,
            preview: item.preview, messageId: "", body: item.body)
        guard let result = await classifyAndDraft(inbox: item.inbox, msg: msg) else { return false }
        let ok = await stageClassified(inbox: item.inbox, msg: msg, voice: item.brand, dupId: id, result: result)
        if ok { FilteredMailStore.shared.remove(id) }
        return ok
    }

    // Mute the domain of a filtered message and clear every filtered row from it.
    func muteFilteredDomain(_ id: String) {
        guard let item = FilteredMailStore.shared.items.first(where: { $0.id == id }),
              let dom = item.domain else { return }
        hideSenderDomain(dom)
        FilteredMailStore.shared.removeDomain(dom)
    }

    // Mute the exact sender of a filtered message and clear its filtered rows.
    func muteFilteredSender(_ id: String) {
        guard let item = FilteredMailStore.shared.items.first(where: { $0.id == id }) else { return }
        hideSenderEmail(item.fromEmail)
        FilteredMailStore.shared.removeSender(item.fromEmail)
    }

    // Enable the email kind that filtered this message, brand-wide, then drop it
    // from the list (a future sweep will draft it).
    func enableFilteredKind(_ id: String) {
        guard let item = FilteredMailStore.shared.items.first(where: { $0.id == id }),
              let raw = item.kind, let kind = EmailKind(rawValue: raw) else { return }
        ReplyPolicyStore.shared.setKind(kind, enabled: true, for: item.brand)
        FilteredMailStore.shared.remove(id)
    }

    // Re-draft an existing staged draft in place (the "Regenerate" button).
    // Reuses the stored incoming context, refreshes draftReply + originalReply +
    // category + urgency + needsReview. Returns true on success.
    @discardableResult
    func regenerate(_ id: String) async -> Bool {
        guard let draft = SupportDraftStore.shared.drafts.first(where: { $0.id == id }) else { return false }
        let msg = InboxMessage(
            fromName: draft.fromName,
            fromEmail: draft.fromEmail,
            subject: draft.subject,
            preview: draft.incomingPreview,
            messageId: draft.sourceMessageId
        )
        guard let result = await classifyAndDraft(inbox: draft.inbox, msg: msg) else { return false }
        let cleanReply = DashSanitizer.clean(result.reply)
        let banned = Self.bannedTokensFound(in: cleanReply, voice: draft.brandVoice)
        let (audited, auditReason) = await auditFabrication(reply: cleanReply, voice: draft.brandVoice)
        let reviewReason = Self.combinedReviewReason(banned: banned, auditReason: audited ? auditReason : nil)
        SupportDraftStore.shared.update(id) {
            $0.category = result.category
            $0.urgency = result.urgency
            $0.needsReview = result.needsReview || !banned.isEmpty || audited
            $0.reviewReason = reviewReason
            $0.draftReply = cleanReply
            $0.originalReply = cleanReply
        }
        return true
    }

    // MARK: - Brand voice + addressing

    // The brand voice for a message: the inbox it arrived on. One inbox, one
    // brand, so the voice key is the inbox key and the whole per-brand chain
    // (prompt, reply policy, autonomy ledger, lessons) stays keyed the same way.
    private static func brandVoice(inbox: SupportInbox) -> String { inbox.rawValue }

    // The account this inbox maps to, from the user's own mail configuration.
    // nil when they have not added one, which is the ship default.
    private static func account(for inbox: SupportInbox) -> EmailAccount? {
        EmailAccountStore.shared.accounts.first { $0.supportInbox == inbox }
    }

    // The verified sender for an inbox: the configured account's send-as address,
    // else its mailbox, else the Graph mailbox mapped to the inbox. Empty when
    // none of those is configured. Grux has no address of its own, so empty means
    // "cannot send" and sendDraft refuses rather than sending as somebody else.
    private static func fromAddress(inbox: SupportInbox) -> String {
        if let acct = Self.account(for: inbox) {
            let sendAs = acct.fromAddress.trimmingCharacters(in: .whitespaces)
            if !sendAs.isEmpty { return sendAs }
        }
        return Self.replyToAddress(inbox: inbox)
    }

    // The bare mailbox address for an inbox (no display name). Also the only
    // address the send-path smoke tests are allowed to deliver to.
    private static func replyToAddress(inbox: SupportInbox) -> String {
        if let acct = Self.account(for: inbox) {
            let addr = acct.emailAddress.trimmingCharacters(in: .whitespaces)
            if !addr.isEmpty { return addr }
        }
        return (GraphMailStore.shared.mailboxAddress(forInbox: inbox.rawValue) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    // Brand-voice system prompt. The style floor (concision, no em/en dashes,
    // trade-secret silence on the stack, anti-fabrication) is fixed; everything
    // brand-specific comes from the user's own profile for this voice. With no
    // profile the drafter has no facts, which is the honest state for a fresh
    // install and the safest one for the customer on the other end.
    private static func systemPrompt(voice: String) -> String {
        let shared = """
        You are drafting a customer-support email reply on the user's behalf. Be
        warm, direct, and concise. Solve the customer's problem or ask the one
        question you need to. No corporate filler. Never use em dashes or en
        dashes anywhere: use commas, periods, colons, parentheses, or a pipe.
        Never reveal any technical stack, vendors, model providers, or internal
        systems; that is privileged trade-secret information. Sign off simply.

        ANTI-FABRICATION (most important rule): only state things that are in the
        BRAND FACTS below or in the customer's own message. NEVER invent, offer,
        promise, or imply any product, offer, discount, coupon, sample, free or
        expedited shipping, refund or return window, warranty, loyalty program,
        timeline, or policy that is not explicitly listed in BRAND FACTS or asked
        for by the customer. If you do not know whether the brand offers
        something, do NOT offer it: ask the customer for the detail you need, or
        say you will look into it and follow up. A clarifying question is always
        better than a confident guess that might be false.
        """
        let profile = SupportBrandProfileStore.profile(for: voice)
        guard !profile.isEmpty else {
            return shared + """

            BRAND FACTS: none. No brand profile has been set up for this inbox,
            so you have NO facts: no products, no prices, no offers, no policies,
            no timelines. Do not name a brand, do not state or imply any
            offering, and do not sign as anyone in particular. Work only from
            what the customer's own message says: answer what you can, ask for
            the one detail you need, or say you will look into it and follow up.
            """
        }
        var out = shared + "\n\nBrand: \(profile.displayName(fallback: voice))."
        if !profile.voice.isEmpty { out += " Voice: \(profile.voice)" }
        if !profile.signOff.isEmpty { out += "\nSign as \"\(profile.signOff)\"." }
        if profile.facts.isEmpty {
            out += "\n\nBRAND FACTS: none recorded. State no offering, price, or"
                + " policy; ask or offer to follow up instead."
        } else {
            out += "\n\nBRAND FACTS (the only offerings you may reference):\n"
                + profile.facts.map { "- \($0)" }.joined(separator: "\n")
        }
        if !profile.forbidden.isEmpty {
            out += "\n\nFORBIDDEN (these do NOT exist, never offer or mention them):\n"
                + profile.forbidden.map { "- \($0)" }.joined(separator: "\n")
        }
        out += "\n\nAnything not listed above is something you DO NOT have. Never"
            + " state, confirm, or deny it. Ask or offer to follow up. Never guess."
        return out
    }

    // MARK: - Helpers

    // The universal floor, applied to every brand: no brand offers one of these
    // by accident, so flagging them can never be wrong for a brand Grux has
    // never heard of. Anything narrower is that brand's own policy and lives on
    // its roster entry in ~/.grux/brands.json, because the per-brand list this
    // replaced was one company's business rules compiled into everybody's copy.
    //
    // What belongs in a brand's own list: unambiguous over-promises, the kind a
    // benign reply never contains ("expedited shipping"). What does NOT:
    // attribute CLAIMS (vegan, gluten-free, and the like). Those appear
    // benignly in acknowledgments, would false-block manual sends, and a word
    // like "organic" can sit inside a brand's own signature. They are left to
    // the stage-time LLM auditor, which sets needsReview and so blocks
    // auto-send without blocking the user.
    static let universalBannedOffers = ["coupon", "promo code", "free shipping"]

    // Lightweight regression check for the no-fabricated-offers rule. Flags
    // phrases that suggest the model offered something a brand does not do (for
    // example a brand that runs no samples or coupons). Shown in the smoke result
    // so a prompt regression is caught without reading every reply by hand.
    static func bannedTokensFound(in text: String, voice: String) -> [String] {
        // Union rather than override: a brand's own list ADDS to the floor, so a
        // missing or misspelled roster entry weakens the extras, never the
        // baseline. An unconfigured brand gets exactly the floor.
        let tokens = Array(Set(Self.universalBannedOffers + BrandRoster.bannedOffers(forId: voice)))
        // Flag a token only when it appears in a sentence that is NOT a denial.
        // "we do not offer samples" is correct behavior and should not flag;
        // "we have a coupon for you" should.
        // Normalize curly apostrophes so "don’t" matches the negation list, and
        // break " but " into its own clause so a denial of one thing ("no
        // coupon, but here's a sample") cannot whitewash an offer of another.
        // We deliberately do NOT split on bare commas: a natural denial list
        // ("we don't do samples, coupons, or discounts") should stay one
        // negated clause rather than over-flagging every item after the comma.
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: " but ", with: ". ")
        let clauses = normalized.components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
        let negations = ["no ", "not ", "n't", "without", "don't", "do not", "cannot", "can not", "never"]
        var hits: Set<String> = []
        for token in tokens {
            for c in clauses where c.contains(token) {
                let negated = negations.contains { c.contains($0) }
                if !negated { hits.insert(token) }
            }
        }
        return hits.sorted()
    }

    // Builds the short human-readable reason shown on a flagged draft, merging
    // the token-scan hits and the LLM audit verdict. nil when nothing flagged.
    static func combinedReviewReason(banned: [String], auditReason: String?) -> String? {
        var parts: [String] = []
        if !banned.isEmpty { parts.append("possible offer: \(banned.joined(separator: ", "))") }
        if let auditReason, !auditReason.isEmpty { parts.append("audit: \(auditReason)") }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    static func draftId(inbox: SupportInbox, msg: InboxMessage) -> String {
        let basis = "\(inbox.rawValue)|\(msg.fromEmail)|\(msg.subject)".lowercased()
        // Stable across process launches (Swift's String.hashValue is randomly
        // seeded per run, which would silently break the persisted-draft dedup
        // after every relaunch). SHA256 prefix is deterministic.
        let digest = SHA256.hash(data: Data(basis.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "support-\(hex)"
    }

    // qwen3 can emit <think>...</think> reasoning even with think:false on
    // older Ollama builds. Strip every such block before JSON parsing, the
    // same guard CloneExtractor + DecisionLog use.
    static func stripThink(_ s: String) -> String {
        guard s.contains("<think>") else { return s }
        var out = s
        while let start = out.range(of: "<think>") {
            if let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Brace-scan the first balanced {...} object out of a possibly-chatty
    // response (models sometimes wrap JSON in prose or fences despite the ask).
    static func extractJSONObject(_ s: String) -> [String: Any]? {
        guard let open = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = open
        while idx < s.endIndex {
            let c = s[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let json = String(s[open...idx])
                        if let data = json.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            return obj
                        }
                        return nil
                    }
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    // A small, realistic fixture so the smoke test exercises the full pipeline
    // (read -> classify -> draft -> stage -> send) without a live inbox.
    //
    // One fixture for every inbox. It used to branch per brand and hand each of
    // one person's two companies its own hand-written sample mail, which cannot
    // be written for a brand Grux has never heard of. These three cover the
    // classifier's whole range instead (shipping, product, refund), so a run
    // against any inbox exercises more of the pipeline than either branch did.
    // Nothing here names a brand: the drafter gets the brand voice from the
    // inbox it is run against.
    static func writeBuiltinFixture(for inbox: SupportInbox) -> String {
        let dir = SupportDraftStore.rootDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("smoke-fixture-\(inbox.rawValue).json")
        let sample: [InboxMessage] = [
            InboxMessage(fromName: "Dana R.", fromEmail: "grux.smoketest@example.com",
                         subject: "Order never showed up",
                         preview: "Hi, I ordered 9 days ago and the tracking has not moved since it shipped. Can you check on it?",
                         messageId: ""),
            InboxMessage(fromName: "Marcus T.", fromEmail: "grux.smoketest2@example.com",
                         subject: "Will this work for what I need",
                         preview: "Trying to decide before I buy and I am not sure this is the right one for me. Can you help me pick?",
                         messageId: ""),
            InboxMessage(fromName: "Priya N.", fromEmail: "grux.smoketest3@example.com",
                         subject: "Refund for the deposit",
                         preview: "Hi, our plans changed after we spoke. Is it possible to get a refund on the deposit?",
                         messageId: "")
        ]
        if let data = try? JSONEncoder().encode(sample) {
            try? data.write(to: url, options: .atomic)
        }
        return url.path
    }
}

// What a brand sells and what it refuses to promise, in the user's own words.
// Grux ships knowing NONE of this: it has no idea what anybody sells, and a
// support drafter that invents an answer is worse than one that asks. So the
// profile set is empty by default and both the drafter and the fabrication
// auditor degrade to "you have no facts, ask instead of guessing".
struct SupportBrandProfile: Codable, Equatable {
    var name: String = ""          // shown to the model, e.g. "Northwind Coffee"
    var voice: String = ""         // one sentence of tone guidance
    var signOff: String = ""       // how a reply signs itself
    var facts: [String] = []       // the ONLY things a reply may state
    var forbidden: [String] = []   // things that do not exist, never offer them

    private enum CodingKeys: String, CodingKey {
        case name, voice, signOff, facts, forbidden
    }

    init(name: String = "", voice: String = "", signOff: String = "",
         facts: [String] = [], forbidden: [String] = []) {
        self.name = name
        self.voice = voice
        self.signOff = signOff
        self.facts = facts
        self.forbidden = forbidden
    }

    // The input is a file a person writes by hand, so every key is optional. A
    // profile carrying only a name must decode; Swift's synthesized decoder
    // would throw on the first missing key and take the whole file with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        signOff = try c.decodeIfPresent(String.self, forKey: .signOff) ?? ""
        facts = try c.decodeIfPresent([String].self, forKey: .facts) ?? []
        forbidden = try c.decodeIfPresent([String].self, forKey: .forbidden) ?? []
    }

    var isEmpty: Bool {
        name.isEmpty && voice.isEmpty && signOff.isEmpty
            && facts.isEmpty && forbidden.isEmpty
    }

    func displayName(fallback: String) -> String { name.isEmpty ? fallback : name }
}

// Reads the profiles from ~/.grux/support/brand-facts.json, keyed by brand voice
// (the same key the reply policy and the autonomy ledger use):
//
//   { "<voice>": { "name": "...", "voice": "...", "signOff": "...",
//                  "facts": ["..."], "forbidden": ["..."] } }
//
// A missing file, an unreadable file, or a voice with no entry all resolve to
// the empty profile. Nothing here can throw and nothing needs setting up for
// triage to run: an unconfigured brand simply drafts with no facts.
@MainActor
enum SupportBrandProfileStore {
    static var url: URL {
        SupportDraftStore.rootDir.appendingPathComponent("brand-facts.json")
    }

    static func profile(for voice: String) -> SupportBrandProfile {
        let all = Persistence.load([String: SupportBrandProfile].self,
                                   from: url, fallback: [:])
        return all[voice.lowercased()] ?? SupportBrandProfile()
    }
}
