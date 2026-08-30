import Foundation
import GruxMCPCore

// MARK: - grux_repair

/// What `~/.grux/setup-status.json` is at this instant.
///
/// Five states rather than a boolean, because the sentence a person needs is different in
/// every one of them and one is not a fault at all. A missing document on a Mac that has
/// just installed Grux is the expected shape of a fresh install, not damage, and the reply
/// has to be able to say so.
private enum StatusDocument {
    case missing
    case unreadable
    case wrongSchema(found: Int)
    /// Parses, current schema, and no longer describes this Mac. This is the case
    /// `grux_refresh_status` exists for: something was installed and Grux never noticed.
    case outOfDate
    case current

    var isFault: Bool {
        if case .current = self { return false }
        return true
    }
}

/// The id a caller types. One constant so the list and the runner cannot disagree.
private let statusDocumentID = "setup-status"
private let statusDocumentTitle = "The setup status document"

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
extension GruxControlTools {

    /// Fix something doctor found, one thing at a time, never a sweep.
    ///
    /// ## There is exactly one repair, and that is the honest count
    ///
    /// `grux doctor` checks four things: Grux.app is installed, the control socket is
    /// there, the setup status document reads, and the version that document reports.
    /// Reconciled against the app one at a time, one of the four has a function behind it.
    ///
    /// Grux.app missing is a download, and no code in the app can perform it. Grux not
    /// running cannot be repaired from in here AT ALL, because every repair runs inside
    /// Grux: reaching this line proves the app is installed and running, so both of those
    /// findings are already answered by the fact that anybody is reading the answer. The
    /// version is read out of the status document, so it is the third check wearing a
    /// different label rather than a fourth thing to fix.
    ///
    /// ## Three more mechanisms were surveyed and deliberately left out
    ///
    /// `CapabilityResolver.refreshNotificationStatus()` genuinely repairs a stale cache,
    /// and its answer arrives inside a `getNotificationSettings` completion handler. This
    /// call is synchronous and on the main actor, so anything it read back would be the
    /// cache from before its own refresh. A repair that can only report itself is the exact
    /// failure this command is shaped against, and blocking the main actor on a semaphore
    /// to get around that would hold the socket shut.
    ///
    /// `Persistence.acknowledgeDecodeFailure(_:)` is not a repair. It lifts the guard that
    /// stops Grux writing over a file that did not decode, which is consenting to lose what
    /// is in it. It is reported below as something needing a person, with the path of the
    /// preserved copy, and it is not offered as a fix.
    ///
    /// `FeatureSelection.unmetDependencies()` finds a real live fault, and the codebase has
    /// already settled that it must NOT be corrected for anybody: `FeatureSelection`,
    /// `setFeatures` and `grux enable` all say in as many words that a selection which
    /// cannot do what was asked is allowed to exist while somebody thinks about it. Also
    /// reported, also not offered.
    static func repair(what: String?) -> [String: Any] {
        let asked = (what ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return repairList() }
        guard asked.lowercased() == statusDocumentID else {
            // A REFUSAL, NOT A GUESS. There is one repair, so an id this does not recognise
            // cannot be narrowed to something the caller meant, and running the only one
            // there is because it is the only one there is would repair something nobody
            // named. The CLI holds the list, so it answers a misspelling with a did-you-mean
            // before it ever gets here; this is the backstop for a direct MCP caller.
            return MCPWire.textFailure(
                "No repair called \(asked). There is one, \(statusDocumentID). Call "
                + "grux_repair with no id to see it alongside everything that needs a "
                + "person instead.")
        }
        return runStatusDocumentRepair()
    }

    // MARK: - The list

    /// Every repair, satisfied ones included, plus what repair will not touch.
    ///
    /// A satisfied repair is LISTED rather than hidden. Hiding it means the set a person
    /// sees changes shape depending on what happens to be wrong, so they can never learn
    /// what the set is, and a short menu that keeps rearranging itself reads as unreliable.
    private static func repairList() -> [String: Any] {
        let doc = statusDocument()
        let row: [String: Any] = [
            "id": statusDocumentID,
            "title": statusDocumentTitle,
            "path": SetupStatusFile.url.path,
            "applies": doc.isFault,
            "now": sentence(for: doc),
            "fix": "Recompute it from this Mac, write it again atomically, then read it "
                 + "back off the disk to check that a reader landing there now gets "
                 + "today's answer.",
        ]
        let body: [String: Any] = ["repairs": [row], "needsAPerson": unfixableFaults()]
        return MCPWire.textResult(jsonText(body))
    }

    /// Faults this Mac has right now that repair will not touch, each with the reason.
    ///
    /// Measured, never a static list. Naming a problem that is not happening is the same
    /// disservice as hiding one that is: a person reading this has to be able to trust that
    /// an empty answer means nothing else is wrong.
    private static func unfixableFaults() -> [[String: String]] {
        var out: [[String: String]] = []

        // A SELECTION THAT CANNOT DO WHAT WAS ASKED. Settled decision, recorded in three
        // places: warn, never correct. `dependsOn` is empty for thirty eight of thirty nine
        // rows, so this is normally empty too.
        for unmet in FeatureSelection.unmetDependencies() {
            let labels = unmet.needs.map { id in
                FeatureRegistry.rows.first { $0.id == id }?.label ?? id
            }
            let turnOn = unmet.needs.map { "grux enable \($0)" }.joined(separator: " and ")
            out.append([
                "id": "feature.\(unmet.feature.id)",
                "label": unmet.feature.label,
                "what": "It is on and \(labels.joined(separator: ", ")) "
                      + "\(unmet.needs.count == 1 ? "is" : "are") off, so it has nothing to "
                      + "work from.",
                "why": "Grux never corrects a selection underneath you: a half configured "
                     + "one is allowed to exist while you think about it. Run \(turnOn), or "
                     + "grux disable \(unmet.feature.id).",
            ])
        }

        // A STORE THAT DID NOT DECODE. The bytes are preserved and writes to the original
        // are refused, which is the app protecting the only copy. Acknowledging that guard
        // would let the next save replace the file, so it is a decision about losing data
        // rather than a repair, and it is not offered as one.
        for failure in Persistence.decodeFailures {
            let name = (failure.path as NSString).lastPathComponent
            let copy = failure.quarantined.isEmpty
                ? "The copy could not be taken, so the only bytes left are the ones still at "
                  + failure.path + "."
                : "The bytes are preserved at \(failure.quarantined)."
            out.append([
                "id": "store.\(name)",
                "label": name,
                "what": "It exists and did not decode, so Grux is refusing to write over it "
                      + "rather than replace it with an empty one.",
                "why": copy + " Nothing in the app can turn them back into a document it "
                     + "understands, so somebody has to look at \(failure.path).",
            ])
        }

        return out
    }

    // MARK: - The one repair

    private static func runStatusDocumentRepair() -> [String: Any] {
        let before = statusDocument()
        let path = SetupStatusFile.url.path

        func reply(changed: Bool, verified: Bool, needsAPerson: Bool, after: String)
            -> [String: Any] {
            let body: [String: Any] = [
                "id": statusDocumentID,
                "title": statusDocumentTitle,
                "path": path,
                "wasWrong": before.isFault,
                "changed": changed,
                "verified": verified,
                "needsAPerson": needsAPerson,
                "before": sentence(for: before),
                "after": after,
            ]
            return MCPWire.textResult(jsonText(body))
        }

        guard before.isFault else {
            // NOTHING TO DO HERE IS A REAL ANSWER. Reporting a repair that repaired nothing
            // is how a person stops believing the ones that did.
            return reply(changed: false, verified: true, needsAPerson: false,
                         after: sentence(for: before))
        }

        // THE ONE REFUSAL THAT IS NOT A DISK PROBLEM, and it is reachable rather than
        // theoretical. `SetupStatusFile.write` returns false without touching the real path
        // when the process is not Grux.app, because a document written by something that
        // cannot answer for its contents is worse than no document: the test suite once put
        // the xctest runner's version into a real home directory this way. A second Grux
        // built into .build and launched by hand serves this socket whenever no other Grux
        // is already listening, which the comment inside `GruxControlSocket.start` records
        // happening on 2026-08-28, so a hand launched build lands here.
        guard SetupStatusFile.isRunningAsTheApp else {
            return reply(changed: false, verified: false, needsAPerson: true,
                         after: "Nothing was written. The Grux answering this socket is not "
                              + "Grux.app, and it will not write \(path) because the "
                              + "document would carry that build's version rather than the "
                              + "app's. Quit the copy you launched by hand, open "
                              + "/Applications/Grux.app, and run this again.")
        }

        let wrote = SetupStatusFile.write()

        // VERIFIED BY READING THE FILE BACK OFF THE DISK. `write` reports that the bytes
        // went out, which is a claim about this process. What matters is the claim about
        // the next reader: does somebody opening that path now get today's answer. Those
        // two come apart on a full disk, on a read-only home directory, and on any
        // permission change since the last successful write.
        let after = statusDocument()
        guard !after.isFault else {
            return reply(changed: wrote, verified: false, needsAPerson: true,
                         after: wrote
                            ? "Grux wrote \(path) and reading it straight back still does "
                              + "not give the current answer, so something else on this Mac "
                              + "is editing or replacing that file."
                            : "Grux could not write \(path). Check that ~/.grux exists, that "
                              + "it belongs to you, and that the disk is not full.")
        }

        return reply(changed: true, verified: true, needsAPerson: false,
                     after: sentence(for: after))
    }

    // MARK: - Reading the document

    private static func statusDocument() -> StatusDocument {
        let url = SetupStatusFile.url
        // EXISTENCE FIRST. "Never written" is the expected state of a fresh install and
        // "there but unreadable" means something edited it, and collapsing the two would
        // send somebody hunting for a corruption that is really a Grux that has not launched.
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let found = try? JSONDecoder().decode(SetupStatusFile.Status.self, from: data)
        else { return .unreadable }
        guard found.schema == SetupStatusFile.schemaVersion else {
            return .wrongSchema(found: found.schema)
        }

        // STALE IS MEASURED, NOT GUESSED AT WITH AN AGE THRESHOLD. Any number of minutes
        // chosen here would call a correct document stale on a Mac nobody touched all week,
        // and call a wrong one fresh in the minute after an install. Comparing it against
        // what `current()` would write this instant answers the question actually being
        // asked: would a reader of this file get today's answer. `generatedAt` is cleared
        // on both sides because it differs by construction and carries none of the answer.
        var onDisk = found
        var live = SetupStatusFile.current()
        onDisk.generatedAt = ""
        live.generatedAt = ""
        return onDisk == live ? .current : .outOfDate
    }

    private static func sentence(for doc: StatusDocument) -> String {
        switch doc {
        case .missing:
            return "There is no document at that path, which is what this Mac looks like "
                 + "before Grux has finished a launch. Nothing reading it can answer a "
                 + "single question about this machine."
        case .unreadable:
            return "The file is there and will not parse. Grux writes it atomically, so a "
                 + "half written one is not possible, which means something else edited it."
        case .wrongSchema(let found):
            return "It says schema \(found) and this Grux writes schema "
                 + "\(SetupStatusFile.schemaVersion), so a reader refuses it rather than "
                 + "guessing at a shape that changed underneath it."
        case .outOfDate:
            return "It parses, and it no longer describes this Mac. Something has changed "
                 + "since it was written, so anything reading it is answering from before "
                 + "that change."
        case .current:
            return "It parses, it is schema \(SetupStatusFile.schemaVersion), and it says "
                 + "exactly what this Mac looks like right now."
        }
    }
}
