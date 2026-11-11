import XCTest
@testable import Grux

// D128: Jax Command's Memory card read "0 voice corpus items indexed" and "No corpus
// indexed yet" over "HOT SEMANTIC LANES JAX 619 YOU 556 FACTS 1, 1,176 total", under a
// setup card saying "Nothing is indexed until you choose.". Three lines disagreed on
// whether anything of the person's was stored. They were two stores under one heading:
// the corpus (the person's own sent mail, messages and notes, indexed only from the
// sources they pick) and the chat memory (what they and the assistant said in chat,
// kept while Settings, Memory is on). The card now names each store's source, and the
// setup line says what it is about.
final class JaxMemoryCardCopyTests: XCTestCase {

    private let mixed: [SemanticMemoryKind: Int] = [
        .chatUser: 556, .chatAssistant: 619, .fact: 1, .corpus: 50,
    ]

    func testTheCorpusLinesSayTheyAreAboutThePersonsOwnWriting() {
        XCTAssertFalse(JaxMemorySection.corpusHeadlineText.contains("corpus"), JaxMemorySection.corpusHeadlineText)
        XCTAssertTrue(JaxMemorySection.corpusHeadlineText.contains("your own writing"), JaxMemorySection.corpusHeadlineText)
        let empty = JaxMemorySection.corpusEmptyText(assistant: "Robin")
        XCTAssertTrue(empty.hasPrefix("None of your own writing"), empty)
        XCTAssertTrue(empty.contains("Robin"), empty)
    }

    func testTheChatMemoryLinesNameWhereTheyCameFrom() {
        XCTAssertFalse(JaxMemorySection.lanesTitle.lowercased().contains("semantic"), JaxMemorySection.lanesTitle)
        XCTAssertFalse(JaxMemorySection.lanesTitle.lowercased().contains("lanes"), JaxMemorySection.lanesTitle)
        let caption = try? XCTUnwrap(JaxMemorySection.lanesCaption(assistant: "Robin"))
        XCTAssertEqual(caption, "What you and Robin said in chat, and what Robin learned while you used Grux, kept on this Mac while Memory is on. Separate from your own writing above.")
    }

    func testEachChipSaysWhoSaidIt() {
        XCTAssertEqual(JaxMemorySection.laneLabel(.chatUser, assistant: "Robin"), "you said")
        XCTAssertEqual(JaxMemorySection.laneLabel(.chatAssistant, assistant: "Robin"), "Robin said")
        XCTAssertEqual(JaxMemorySection.laneLabel(.fact, assistant: "Robin"), "facts")
    }

    // The total sat beside the chips but counted the corpus too: with 50 corpus items it
    // read 1,226 over chips adding to 1,176.
    func testTheTotalIsTheSumOfTheChipsItSitsBeside() {
        let chips = JaxMemorySection.hotLanes(mixed).map(\.1).reduce(0, +)
        XCTAssertEqual(chips, 1_176)
        XCTAssertEqual(JaxMemorySection.lanesTotal(mixed), 1_176)
    }

    func testTheSetupLineSaysWhatNothingIsIndexedFrom() {
        let line = SetupRequirement.stepCorpusSourcesConfirmed.remediation
        XCTAssertTrue(line.hasSuffix("Nothing from them is indexed until you choose."), line)
    }

    // D179 item 4: the empty line said "Run a corpus sweep", a control Jax Command does
    // not have. Wave 63 round 1: it then named "Choose what gets indexed", a setup step
    // whose confirm indexes nothing. Round 2: it then named first run's "Teach Grux your
    // voice" screen, which the default first run never shows. The card now lists every
    // source with an Index button on each readable one, and the line points at those.
    func testTheEmptyLineNamesAControlThatExists() {
        let fresh = JaxMemorySection.corpusEmptyText(assistant: "Robin", anyReady: true)
        XCTAssertFalse(fresh.lowercased().contains("sweep"), fresh)
        XCTAssertFalse(fresh.contains("Choose what gets indexed"), fresh)
        XCTAssertFalse(fresh.contains("first run"), "a screen most first runs never show: \(fresh)")
        XCTAssertTrue(fresh.contains("Index"), fresh)
        XCTAssertTrue(fresh.contains("below"), fresh)
        let none = JaxMemorySection.corpusEmptyText(assistant: "Robin", anyReady: false)
        XCTAssertFalse(none.contains("Index a source"), "no Index button shows when nothing is readable: \(none)")
        XCTAssertFalse(none.contains("first run"), none)
        XCTAssertTrue(none.contains("each says why"), none)
        for ready in [false, true] {
            let ran = JaxMemorySection.corpusEmptyText(assistant: "Robin", anySourceRan: true, anyRunning: false, anyReady: ready)
            XCTAssertTrue(ran.hasPrefix("None of your own writing"), ran)
            XCTAssertFalse(ran.contains("Choose what gets indexed"), ran)
            XCTAssertFalse(ran.contains("you picked"), "a sweep from the trigger reads sources nobody picked: \(ran)")
            XCTAssertFalse(ran.contains("had nothing"), "a failed read is not one that found nothing: \(ran)")
            XCTAssertTrue(ran.contains("Each source below says where it stands"), ran)
        }
    }

    /// While any source is reading, the line says so, whether or not another
    /// already finished empty; it never says the picks had nothing mid-read.
    func testARunningReadIsSaidAndWinsOverAFinishedEmptyOne() {
        for ran in [false, true] {
            for ready in [false, true] {
                let line = JaxMemorySection.corpusEmptyText(assistant: "Robin", anySourceRan: ran, anyRunning: true, anyReady: ready)
                XCTAssertTrue(line.contains("reading"), line)
                XCTAssertFalse(line.contains("had nothing"), line)
            }
        }
    }

    /// An Index button shows only on a source that can be read now and is not already reading.
    func testIndexShowsOnlyOnAReadableIdleSource() {
        func status(_ p: CorpusPermission, running: Bool) -> CorpusCoordinator.SourceStatus {
            .init(source: .notes, permission: p, lastRunAt: nil, lastNote: "", totalIndexed: 0,
                  lastRunIndexed: 0, isRunning: running)
        }
        XCTAssertTrue(JaxMemorySection.canIndex(status(.ready, running: false)))
        XCTAssertFalse(JaxMemorySection.canIndex(status(.ready, running: true)))
        for p in [CorpusPermission.needsFullDiskAccess, .needsAutomation, .needsAccount, .needsPassword, .needsKeychain, .noData, .unknown] {
            for r in [false, true] {
                XCTAssertFalse(JaxMemorySection.canIndex(status(p, running: r)), "\(p) running \(r)")
            }
        }
    }

    /// Wave 63 round 3: "each says what it needs" sat over Notes' "Status unknown until
    /// first run." (Notes closed) and two "No data found yet" rows that named no folder.
    /// Every row with nothing indexed that cannot be read now says why in words a person
    /// can act on, and the two import rows name their folder.
    func testEveryUnreadableRowSaysWhyAndWhatToDo() {
        func status(_ src: CorpusSource, _ p: CorpusPermission, indexed: Int = 0) -> CorpusCoordinator.SourceStatus {
            .init(source: src, permission: p, lastRunAt: nil, lastNote: "", totalIndexed: indexed,
                  lastRunIndexed: 0, isRunning: false)
        }
        let perms: [CorpusPermission] = [.needsFullDiskAccess, .needsAutomation, .needsAccount, .needsPassword, .needsKeychain, .noData, .unknown]
        for src in CorpusSource.allCases {
            XCTAssertNil(JaxMemorySection.needLine(status(src, .ready)), "\(src)")
            for p in perms {
                XCTAssertNil(JaxMemorySection.needLine(status(src, p, indexed: 2)), "\(src) \(p) indexed")
                let line = JaxMemorySection.needLine(status(src, p))
                XCTAssertNotNil(line, "\(src) \(p)")
                XCTAssertNotEqual(line, "Status unknown until first run.", "\(src) \(p)")
                XCTAssertNotEqual(line, "No data found yet for this source.", "\(src) \(p)")
            }
        }
        let chats = JaxMemorySection.needLine(status(.chatHistory, .noData)) ?? ""
        XCTAssertTrue(chats.contains(".json or .zip"), chats)
        XCTAssertTrue(chats.contains("jax/imports"), chats)
        let voice = JaxMemorySection.needLine(status(.voiceRecording, .noData)) ?? ""
        XCTAssertTrue(voice.contains(".m4a"), voice)
        XCTAssertTrue(voice.contains("jax/voice"), voice)
        let notes = JaxMemorySection.needLine(status(.notes, .unknown)) ?? ""
        XCTAssertTrue(notes.contains("Open the Notes app"), notes)
        XCTAssertEqual(JaxMemorySection.needLine(status(.iMessage, .needsFullDiskAccess)),
                       CorpusPermission.needsFullDiskAccess.humanReason)
        XCTAssertEqual(JaxMemorySection.folder(for: .chatHistory), ChatHistoryImporter.importsDir)
        XCTAssertEqual(JaxMemorySection.folder(for: .voiceRecording), VoiceRecordingsIngester.voiceDir)
        for src in [CorpusSource.gmailSent, .iMessage, .notes] { XCTAssertNil(JaxMemorySection.folder(for: src)) }
    }

    /// The card lists the sources even when nothing is indexed, runs a source from its
    /// own Index button, and passes the real state to the line.
    func testTheCardOffersIndexOnEachReadableSource() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Jax/JaxCommandView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("anyRunning: sources.contains { $0.isRunning }"), "the card never says a read is running")
        XCTAssertTrue(view.contains("anyReady: sources.contains { Self.canIndex($0) }"), "the line ignores whether any Index button shows")
        guard let row = view.range(of: "private func corpusRow(") else { return XCTFail("corpusRow moved") }
        let body = String(view[row.lowerBound...].prefix(2400))
        XCTAssertTrue(body.contains("Self.needLine(source)"), "an unreadable row never says what it needs")
        XCTAssertTrue(body.contains("Button(\"Show folder\")"), "an import row names a hidden folder with no way to it")
        XCTAssertFalse(body.contains("on this Mac and learn"), "Gmail is read from Google's server, not this Mac")
        XCTAssertTrue(body.contains("if Self.canIndex(source)"), body)
        XCTAssertTrue(body.contains("Button(\"Index\")"), body)
        XCTAssertTrue(body.contains("CorpusCoordinator.shared.run(source.source)"), body)
        XCTAssertFalse(view.contains("if sources.allSatisfy({ $0.totalIndexed == 0 }) {\n                    JaxEmptyLine(icon: \"tray\",\n                                 text: Self.corpusEmptyText(assistant: UserIdentity.assistantName,\n                                                                 anySourceRan: sources.contains { $0.lastRunAt != nil },\n                                                                 anyRunning: sources.contains { $0.isRunning }))\n                } else {"),
                       "the rows still hide while nothing is indexed")
    }

    /// First run's own dead end said "come back from Settings", where no such control is.
    func testFirstRunsDeadEndPointsAtTheCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let steps = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/OnboardingSteps.swift"), encoding: .utf8)
        XCTAssertFalse(steps.contains("come back from Settings"))
        XCTAssertTrue(steps.contains("Jax Command"), "the dead end names no place to come back to")
    }

    /// A status saved while one source was reading (another source's finish or a
    /// permission refresh writes every row) came back after a quit still reading,
    /// so the card would say "Grux is reading the sources now" for good. Nothing
    /// reads at launch.
    func testARestoredStatusIsNeverStillReading() {
        let saved = CorpusCoordinator.SourceStatus(
            source: .notes, permission: .ready, lastRunAt: nil, lastNote: "x",
            totalIndexed: 0, lastRunIndexed: 0, isRunning: true)
        let restored = CorpusCoordinator.restored([saved])
        XCTAssertEqual(restored.count, 1)
        XCTAssertFalse(restored[0].isRunning)
        XCTAssertEqual(restored[0].source, .notes)
        XCTAssertEqual(restored[0].permission, .ready)
    }

    // Wave 63 round 4: a read the person started that failed was shown with a guessed
    // reason: Whisper not loaded read "Not checked yet. Reopen this tab to check.", a
    // Gmail login failure read "No Gmail account configured". While a read's verdict
    // still stands, the row says what that read reported.

    private func ready(_ src: CorpusSource) -> CorpusCoordinator.SourceStatus {
        .init(source: src, permission: .ready, lastRunAt: nil, lastNote: "Ready", totalIndexed: 0,
              lastRunIndexed: 0, isRunning: false)
    }

    func testAFailedReadSaysWhatTheReadReported() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let voice = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                            note: "Whisper model not loaded; check first-run download"),
            to: ready(.voiceRecording), at: at)
        let vLine = JaxMemorySection.needLine(voice) ?? ""
        XCTAssertTrue(vLine.contains("Whisper model not loaded"), vLine)
        XCTAssertFalse(vLine.contains("Not checked yet"), vLine)
        let gmail = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .needsAccount,
                            note: "Gmail login failed: The network connection was lost."),
            to: ready(.gmailSent), at: at)
        let gLine = JaxMemorySection.needLine(gmail) ?? ""
        XCTAssertTrue(gLine.contains("Gmail login failed"), gLine)
        XCTAssertFalse(gLine.contains(CorpusPermission.needsAccount.humanReason), gLine)
        let notes = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown, note: "Notes export failed"),
            to: ready(.notes), at: at)
        let nLine = JaxMemorySection.needLine(notes) ?? ""
        XCTAssertTrue(nLine.contains("Notes export failed"), nLine)
        XCTAssertFalse(nLine.contains("Open the Notes app"), nLine)
        XCTAssertEqual(voice.lastRunAt, at)
        XCTAssertEqual(voice.lastRunPermission, .unknown)
    }

    /// Once a later probe disagrees with the read (access granted or taken away since),
    /// the probe's own reason shows again; the read's note is stale.
    func testALaterProbeOverridesAnOldReadsVerdict() {
        var s = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown, note: "Notes export failed"),
            to: ready(.notes), at: Date())
        s.permission = .needsAutomation
        XCTAssertEqual(JaxMemorySection.needLine(s), CorpusPermission.needsAutomation.humanReason)
    }

    /// Wave 63 round 6: "The sources Grux read had nothing it could use" was fooled by
    /// each new way a read can fail (a Gmail folder in another language read as empty).
    /// The line makes no claim about what reads found; the rows say it.
    func testNoLineSaysTheSourcesHadNothing() throws {
        for ran in [false, true] { for running in [false, true] { for ready in [false, true] {
            let line = JaxMemorySection.corpusEmptyText(assistant: "Robin", anySourceRan: ran, anyRunning: running, anyReady: ready)
            XCTAssertFalse(line.contains("had nothing"), line)
        } } }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Jax/JaxCommandView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("anySourceRan: sources.contains { $0.lastRunAt != nil }"), "the card's line reads a guess at what reads found")
    }

    /// A read that ran and indexed nothing says what it reported on its row, readable
    /// or not, and a failed one says how to check again.
    func testAReadThatIndexedNothingSaysWhatItReported() {
        let at = Date()
        let voice = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 3, permission: .ready,
                            note: "Transcribed 0 recordings (3 skipped)"), to: ready(.voiceRecording), at: at)
        XCTAssertEqual(JaxMemorySection.needLine(voice), "Last read: Transcribed 0 recordings (3 skipped)")
        let folder = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .noData,
                            note: "Could not locate the Gmail Sent folder"), to: ready(.gmailSent), at: at)
        let fLine = JaxMemorySection.needLine(folder) ?? ""
        XCTAssertTrue(fLine.hasPrefix("Last read: Could not locate the Gmail Sent folder"), fLine)
        let sync = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                            note: "Sent sync error: The network connection was lost."), to: ready(.gmailSent), at: at)
        XCTAssertTrue((JaxMemorySection.needLine(sync) ?? "").hasSuffix("Reopen this tab to check it again."))
        var indexed = voice; indexed.totalIndexed = 4
        XCTAssertNil(JaxMemorySection.needLine(indexed))
    }

    /// Wave 63 round 7 P3 16: a note that already ends a sentence read
    /// "IMAP timed out (FETCH).. Reopen this tab to check it again." A note keeps its own
    /// closing mark and gains a period only when it has none.
    func testAFailedReadNoteNeverDoublesItsFullStop() {
        let cases: [(String, String)] = [
            ("IMAP timed out (FETCH).", "IMAP timed out (FETCH)."),
            ("Sent sync error: The network connection was lost.  ", "Sent sync error: The network connection was lost."),
            ("Is Gmail reachable?", "Is Gmail reachable?"),
            ("Login refused!\n", "Login refused!"),
            ("Export stopped\u{2026}", "Export stopped\u{2026}"),
            ("Notes export failed", "Notes export failed."),
        ]
        for (note, shown) in cases {
            let failed = CorpusCoordinator.applying(
                CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown, note: note),
                to: ready(.gmailSent), at: Date())
            let line = JaxMemorySection.needLine(failed) ?? ""
            XCTAssertEqual(line, "Last read: \(shown) Reopen this tab to check it again.", note)
            XCTAssertFalse(line.contains(".."), line)
        }
    }

    /// The chip beside a row said "not run" over "Last read: Sent sync error".
    func testTheChipNeverSaysNotRunAfterARead() {
        let failed = CorpusCoordinator.applying(
            CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown, note: "Notes export failed"),
            to: ready(.notes), at: Date())
        XCTAssertEqual(JaxMemorySection.statusHint(failed), "read failed")
        var never = ready(.notes); never.permission = .unknown
        XCTAssertEqual(JaxMemorySection.statusHint(never), "not checked")
        for p in [CorpusPermission.ready, .noData, .needsAccount, .needsPassword, .needsKeychain, .needsAutomation, .needsFullDiskAccess, .unknown] {
            var st = failed; st.permission = p
            XCTAssertNotEqual(JaxMemorySection.statusHint(st), "not run", "\(p)")
        }
    }

    /// D192 item 2, sense pass 26: the Gmail row read "needs access" over "No Gmail
    /// account configured", a permission to grant where there is no account to read.
    /// The chip names what is missing: a permission says access, an account says set up.
    func testTheChipSaysSetUpWhenAnAccountIsMissing() {
        var st = ready(.gmailSent)
        let expected: [(CorpusPermission, String)] = [
            (.needsAccount, "not set up"),
            (.needsPassword, "no password"),
            (.needsKeychain, "keychain locked"),
            (.needsFullDiskAccess, "needs access"),
            (.needsAutomation, "needs access"),
        ]
        for (p, chip) in expected {
            st.permission = p
            XCTAssertEqual(JaxMemorySection.statusHint(st), chip, "\(p)")
        }
    }

    /// Wave 63 round 5: Gmail's mid-read failure ("Sent sync error") came back with a
    /// .ready verdict, so the card read "had nothing it could use" over a read that
    /// failed. Class guard: in every ingester a .ready verdict is a finished read, whose
    /// note says what it indexed or transcribed.
    func testAReadyVerdictIsAlwaysAFinishedRead() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/Grux/Jax/Corpus")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        var seen = 0
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            var rest = Substring(text)
            while let at = rest.range(of: "permission: .ready,") {
                let after = rest[at.upperBound...].prefix(200)
                let note = after.range(of: "note: \"").map { after[$0.upperBound...].prefix(12) } ?? ""
                XCTAssertTrue(note.hasPrefix("Indexed") || note.hasPrefix("Transcribed"),
                              "\(f): a .ready verdict on a read that did not finish: \(note)")
                seen += 1
                rest = rest[at.upperBound...]
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 5, "the guard found no results to check")
    }

    /// Wave 66 round 2: Gmail's login failure came back `.needsAccount`, so after a
    /// wrong app password the chip read "not set up" beside "Gmail login failed" for
    /// an account that is set up. Class guard: no account is said only where no
    /// account or password was found (`.blocked(.needsAccount)`), never by a read
    /// that tried one; a read that failed is `.unknown`, whose chip reads "read failed".
    func testNoAccountIsNeverTheVerdictOfAReadThatTriedOne() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/Grux/Jax/Corpus")
        var hits: [String] = []
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            if text.contains("permission: .needsAccount,") { hits.append(f) }
        }
        XCTAssertEqual(hits, [], "a read that tried an account says .needsAccount")
        var failed = ready(.gmailSent)
        failed.permission = .unknown
        failed.lastRunPermission = .unknown
        failed.lastRunAt = Date()
        failed.lastNote = "Gmail login failed: authentication failed"
        XCTAssertEqual(JaxMemorySection.statusHint(failed), "read failed")
    }

    /// Wave 66 round 3: after Gmail refused the password, reopening the tab probed
    /// only that a password is stored, so the row read "ready" with an Index button
    /// over a password Gmail had just refused, and nothing said to fix it. A refused
    /// login stands until a later read, and the row names the fix, before and after
    /// the reopen.
    func testARefusedGmailLoginSaysHowToFixItUntilAReadWorks() throws {
        let refused = GmailSentIngester.readFailure(IMAPClient.IMAPError.loginFailed("[AUTHENTICATIONFAILED] Invalid credentials"), duringLogin: true)
        XCTAssertEqual(refused.permission, .unknown)
        var st = ready(.gmailSent)
        st.permission = refused.permission
        st.lastRunPermission = refused.permission
        st.lastRunAt = Date()
        st.lastNote = refused.note
        // Right after the read: no Index button, so the line says to reopen.
        XCTAssertEqual(JaxMemorySection.statusHint(st), "login failed")
        XCTAssertFalse(JaxMemorySection.canIndex(st))
        let before = try XCTUnwrap(JaxMemorySection.needLine(st))
        XCTAssertTrue(before.contains("in Mail, Accounts") && before.contains("app password"), before)
        XCTAssertTrue(before.contains("reopen this tab"), before)
        XCTAssertFalse(before.contains("press Index"), before)
        // After the reopen the probe says a password is stored: Index is back to retry,
        // and the row still says the last login was refused.
        st.permission = .ready
        XCTAssertEqual(JaxMemorySection.statusHint(st), "login failed")
        XCTAssertTrue(JaxMemorySection.canIndex(st))
        let after = try XCTUnwrap(JaxMemorySection.needLine(st))
        XCTAssertTrue(after.contains("in Mail, Accounts") && after.contains("press Index"), after)
        // A later read that worked ends it.
        st.lastRunPermission = .noData
        st.permission = .noData
        st.lastNote = "Could not locate the Gmail Sent folder"
        XCTAssertEqual(JaxMemorySection.statusHint(st), "no data")
    }

    /// Wave 66 round 4: Mail, Accounts cannot change a stored password ("Add +
    /// test" adds a second account and the read keeps using the first), so the line
    /// names the step that works: remove the account and add it again. An account
    /// removed since reads as no account again, and a retry running reads as one.
    func testTheRefusedLoginLineNamesAStepThatWorks() throws {
        let refused = GmailSentIngester.readFailure(IMAPClient.IMAPError.loginFailed("Invalid credentials"), duringLogin: true)
        var st = ready(.gmailSent)
        st.permission = .unknown
        st.lastRunPermission = .unknown
        st.lastRunAt = Date()
        st.lastNote = refused.note
        for permission in [CorpusPermission.unknown, .ready] {
            st.permission = permission
            let line = try XCTUnwrap(JaxMemorySection.needLine(st))
            XCTAssertTrue(line.contains("remove the Gmail account in Mail, Accounts and add it again"), line)
            XCTAssertFalse(line.contains("enter one in Mailbox"), line)
        }
        // Retrying: Index is pressed, the row says indexing, the line does not say reopen.
        st.permission = .ready
        st.isRunning = true
        XCTAssertEqual(JaxMemorySection.statusHint(st), "indexing")
        XCTAssertFalse(try XCTUnwrap(JaxMemorySection.needLine(st)).contains("reopen this tab"))
        // Removed since: the probe says no account, and the row says so.
        st.isRunning = false
        st.permission = .needsAccount
        XCTAssertEqual(JaxMemorySection.statusHint(st), "not set up")
        XCTAssertFalse(JaxMemorySection.needLine(st)?.contains("app password, not your Google password") ?? false)
    }

    /// The network down is not a refused password: no "app password" fix is named.
    func testAnUnreachableGmailIsAFailedReadNotARefusedLogin() throws {
        for (error, login) in [(IMAPClient.IMAPError.connectFailed("offline") as Error, false),
                               (IMAPClient.IMAPError.timeout("LOGIN") as Error, true)] {
            let r = GmailSentIngester.readFailure(error, duringLogin: login)
            XCTAssertEqual(r.permission, .unknown)
            var st = ready(.gmailSent)
            st.permission = r.permission
            st.lastRunPermission = r.permission
            st.lastRunAt = Date()
            st.lastNote = r.note
            XCTAssertEqual(JaxMemorySection.statusHint(st), "read failed", r.note)
            let line = try XCTUnwrap(JaxMemorySection.needLine(st))
            XCTAssertFalse(line.contains("app password"), line)
            XCTAssertFalse(r.note.contains("login failed"), r.note)
        }
    }
}
