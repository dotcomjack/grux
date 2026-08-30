import Foundation
import AppKit

// Indexes the user's Apple Notes (longer-form thinking they wrote themselves).
//
// We use the AppleScript bridge (NSAppleScript) rather than parsing the
// NoteStore SQLite, because note bodies in NoteStore are gzipped protobuf and
// brittle to decode across macOS versions, whereas the Notes scripting
// dictionary returns clean plaintext bodies. The tradeoff is the Automation
// permission gate: the first run triggers a TCC prompt ("Grux wants to control
// Notes"). If denied, NSAppleScript returns errAEEventNotPermitted (-1743) and
// we surface needsAutomation rather than crashing.
//
// AppleScript runs on a background-safe path off the main actor via a detached
// task; NSAppleScript itself must run on a thread with a run loop, so we hop to
// the main thread for the execute call (cheap, notes export is not hot-path).
actor NotesIngester: CorpusIngester {
    nonisolated let source: CorpusSource = .notes

    private let rag: RAGClient
    private var ledger: CorpusLedger
    private let perRunCap = 1_000

    init(rag: RAGClient) {
        self.rag = rag
        self.ledger = CorpusLedger.load(source: .notes)
    }

    /// A PROBE THAT RAISES A MODAL IS NOT A PROBE.
    ///
    /// This used to send `tell application "Notes" to return count of notes`, and asking a
    /// question is enough: macOS answers an Apple event it has no decision for by putting
    /// "Grux OS wants access to control Notes.app" on the screen, and approving it LAUNCHES
    /// Notes to answer. Measured on a Mac that had never run Grux: the dialog arrived before
    /// any Grux window was guaranteed to be up, because the app is LSUIElement. Nobody had
    /// asked for Notes to be indexed and no Grux screen had explained why.
    ///
    /// The protocol says a probe is "cheap, side-effect-free" (CorpusIngester.swift:22) and a
    /// TCC prompt is neither. `AEDeterminePermissionToAutomateTarget` with
    /// `askUserIfNeeded: false` asks TCC what it has ALREADY decided and never prompts.
    ///
    /// The cost is that a permitted probe can no longer distinguish `.ready` from `.noData`,
    /// because counting the notes is the send this removes. `.ready` is the honest answer:
    /// permission is what the row reports, and an empty Notes library is discovered by the
    /// ingest the person actually asks for.
    ///
    /// MEASURED on this machine, since the return values are not all obvious:
    ///
    ///     com.apple.Notes  -> 0     (noErr, already permitted)
    ///     com.apple.iCal   -> 0
    ///     com.apple.Stocks -> -600  (procNotFound: the app is NOT RUNNING)
    ///     com.example.nope -> -600
    ///
    /// So the target has to be up for TCC to have anything to say, and nothing here launches
    /// it, which is the second half of the bug: `tell application "Notes"` opened Notes to
    /// answer. `-600` therefore means "cannot tell yet", and `.unknown` already renders as
    /// "Status unknown until first run.", which is true: the run the person asks for is
    /// where the consent dialog belongs.
    func probe() async -> CorpusPermission {
        switch Self.automationPermission(forBundleId: "com.apple.Notes") {
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent):
            return .needsAutomation
        case OSStatus(noErr):
            return .ready
        default:
            // Includes procNotFound (-600), which is the ordinary state of a Mac where
            // nobody has opened Notes today.
            return .unknown
        }
    }

    /// What TCC has already decided about controlling `bundleId`, without asking anybody.
    ///
    /// `errAEEventWouldRequireUserConsent` is the specific answer this exists to get: it
    /// means the decision has not been made, which is exactly the state that used to raise
    /// the dialog. Reporting it as `needsAutomation` puts the ask on the Corpus screen, which
    /// has room to say why.
    nonisolated static func automationPermission(forBundleId bundleId: String) -> OSStatus {
        var target = AEAddressDesc()
        let data = Array(bundleId.utf8)
        let created = OSStatus(AECreateDesc(typeApplicationBundleID, data, data.count, &target))
        guard created == OSStatus(noErr) else { return created }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    func ingest() async -> CorpusRunResult {
        // Export id\tbody pairs. We use a unit-separator delimiter set unlikely
        // to appear in note text: records split on \u{1E}, fields on \u{1F}.
        let script = #"""
        set out to ""
        set RS to (ASCII character 30)
        set FS to (ASCII character 31)
        tell application "Notes"
            repeat with n in notes
                try
                    set noteId to id of n as string
                    set noteBody to (plaintext of n) as string
                    set noteMod to (modification date of n)
                    set out to out & noteId & FS & noteBody & FS & (noteMod as «class isot» as string) & RS
                end try
            end repeat
        end tell
        return out
        """#

        let result = await Self.runAppleScript(script)
        let raw: String
        switch result {
        case .denied:  return .blocked(.needsAutomation)
        case .failure: return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                                              note: "Notes export failed")
        case .success(let s): raw = s
        }

        let records = raw.components(separatedBy: "\u{1E}").filter { !$0.isEmpty }
        var indexed = 0, skipped = 0
        var docs: [RAGClient.Document] = []

        for rec in records.prefix(perRunCap) {
            let fields = rec.components(separatedBy: "\u{1F}")
            guard fields.count >= 2 else { continue }
            let noteId = fields[0]
            let body = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let isoMod = fields.count >= 3 ? fields[2] : ""
            guard body.count >= 20 else { skipped += 1; continue }

            // Dedupe on id + a body hash so an edited note re-indexes.
            let key = "note-\(noteId)-\(CorpusIndexer.stableHash(body))"
            guard ledger.insert(key) else { skipped += 1; continue }

            let ts = Self.parseISO(isoMod).map { Int($0.timeIntervalSince1970 * 1000) }
            await MainActor.run {
                CorpusIndexer.indexLocal(source: .notes, text: body, timestampMillis: ts)
            }
            docs.append(RAGClient.Document(
                id: CorpusIndexer.docId(source: .notes, key: key),
                source: "idea",
                text: body,
                ts: ts.map { $0 / 1000 },
                brandHint: ""
            ))
            indexed += 1
        }

        let pushed = await CorpusIndexer.pushToRAG(rag, source: .notes, docs: docs)
        ledger.save(source: .notes)
        return CorpusRunResult(indexed: indexed, pushedToRAG: pushed, skipped: skipped, permission: .ready,
                               note: "Indexed \(indexed) notes (\(skipped) unchanged)")
    }

    // MARK: - AppleScript runner

    enum ScriptOutcome {
        case success(String)
        case denied
        case failure
    }

    // NSAppleScript must run on the main thread (it needs a run loop). We hop
    // there, run it, and classify a TCC denial vs other errors.
    @MainActor
    static func runAppleScript(_ source: String) async -> ScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .failure }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 errAEEventNotPermitted, -600 procNotFound (Notes not running
            // yet can also surface here, but a denial is the common case).
            if code == -1743 || code == -10004 { return .denied }
            return .failure
        }
        return .success(result.stringValue ?? "")
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
