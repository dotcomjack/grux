import Foundation

// Mac-side store for the Social Ops Cockpit. Holds the latest snapshot of every
// brand x platform cell, restores a cache on launch, pulls live state from the
// companion service, and mirrors a human/CLI readable ~/.grux/social-ops.md. Built on the
// exact PRDigestStore pattern: @MainActor ObservableObject singleton, cache in
// Application Support, soft-fail to cache on a pull error, and a stale flag
// when we degrade to cache.
//
// Source service: the configured social-ops host's /api/social-ops/state,
// with LAN + localhost fallbacks (see SocialOpsService.baseURLs).

@MainActor
final class SocialOpsStore: ObservableObject {
    static let shared = SocialOpsStore()

    @Published private(set) var snapshot: SocialOpsSnapshot?
    @Published private(set) var lastUpdated: Date?      // last successful fetch or push
    @Published private(set) var isFetching: Bool = false
    // The standing verdict of the last completed pull, nil when it succeeded
    // (or none has completed). ONE published value rather than the three
    // fields it derives, because the triple was written in lockstep at every
    // verdict site across five stores, and lockstep by hand is how the
    // mislabel classify() exists to prevent almost shipped again.
    @Published private(set) var lastVerdict: PrivateServiceFetch.Classification?
    var lastError: String? { lastVerdict?.displayMessage }
    // True when lastError is the "nothing configured, absence is normal" state
    // rather than a real fault. Typed off the thrown Failure kind so no view
    // ever has to compare lastError against the explanation string.
    var lastErrorIsAbsence: Bool { lastVerdict?.isAbsence ?? false }
    // True when the last pull failed and we are showing a cached snapshot.
    var servingStale: Bool { lastVerdict?.servingStale ?? false }
    // A failed operator command or sweep. Deliberately a separate channel from
    // lastError: refresh() nils lastError at its top, and the section renders
    // lastError only over a stale or empty grid, so with a healthy snapshot a
    // failed command or sweep used to show nothing at all (the per-cell text
    // in lastActionByCell collapses with the controls the moment the command
    // fires). Cleared at the start of the next command or sweep attempt (or
    // by its success) or by the user acknowledging the banner, never by a
    // fetch. Same argument as MetaAdsStore.commandError.
    @Published private(set) var commandError: String?
    // Most recent action outcome per cell ("muted", "re-auth: 2FA needed"), keyed
    // by "brand|platform". Persists under the cell after the transient feedback.
    @Published private(set) var lastActionByCell: [String: String] = [:]

    private var loaded = false
    // Coalesces refreshes: any number of requests during one pull owe one
    // follow-up pass, and a cancelled awaiter cannot swallow another
    // caller's request. The whole argument lives on RefreshGate.
    private let refreshGate = RefreshGate()
    // Start-order guard, same reason as MetaAdsStore: pullAfterWrite() runs
    // outside the gate. pullAdoption already guards the SNAPSHOT by payload
    // timestamp, but the verdict writes below had nothing.
    private var pullSequence = PrivateServiceFetch.PullSequence()

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("social-ops.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("social-ops.md")
    }

    private init() {}

    // Restore the last cached snapshot on launch so the dashboard has something
    // to show before the first live pull lands.
    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(SocialOpsSnapshot.self, from: data) {
            self.snapshot = cached
        }
    }

    // PULL path: ask the companion service for the latest state. Adopt only when strictly
    // newer than what we hold so an out-of-order push between launch and this
    // pull is not clobbered (mirrors PRDigestStore's <= reject rule).
    //
    // Error state is NOT cleared at the top: the fields hold the last
    // completed verdict until this pull lands one of its own. Clearing here
    // unmounted the absence card mid-recovery (its mount keys on the flag),
    // which cancelled the very pull it was awaiting.
    func refresh() async {
        await refreshGate.run(isFetching: { self.isFetching = $0 }) {
            await self.pullOnce()
        }
    }

    @discardableResult
    private func pullOnce() async -> Bool {
        let seq = pullSequence.begin()
        do {
            let fresh = try await SocialOpsService.fetchState()
            guard pullSequence.claimWrite(seq) else { return false }
            if let adopted = Self.pullAdoption(of: fresh, over: snapshot) {
                apply(adopted)
                return true
            } else {
                // A no-op by timestamp is still an ANSWER to a request
                // this machine sent, so the host is proven (see
                // markHeldSnapshotPullProven) even though nothing new is
                // held.
                markHeldSnapshotPullProven()
                self.lastUpdated = Date()
                self.lastVerdict = nil
                // The host answered, but the grid did not move, so a command
                // awaiting this pull learns nothing it may narrate from.
                return false
            }
        } catch is CancellationError {
            // The awaiting task was torn down mid-pull (a section unmounting
            // cancels its recovery refresh). No verdict exists, so every
            // error field stays exactly as it was: writing one here is how a
            // cancelled pull once recorded a fabricated absence on this
            // singleton. The gate owns any request that coalesced behind
            // this pass.
            return false
        } catch {
            // Keep the cache. The absence x cache rule lives in classify():
            // absence over a PULL-proven snapshot is an outage named
            // technically; over a push-fed one it is the normal state.
            guard let verdict = PrivateServiceFetch.classify(error, cache: cacheProvenance)
            else { return false }
            guard pullSequence.claimWrite(seq) else { return false }
            self.lastVerdict = verdict
            WakeLog.shared.log("social-ops: pull failed: \(verdict.displayMessage)")
            return false
        }
    }

    /// A pull GUARANTEED to have started AFTER this call, for the
    /// read-after-write every command path needs.
    ///
    /// `refresh()` cannot serve them, and that is not a bug in the gate. Its
    /// first statement is "if a pass is in flight, mark pending and RETURN",
    /// which is the coalescing that stops N callers causing N pulls. But it
    /// means `await refresh()` returns having pulled NOTHING whenever a poll
    /// tick is mid-flight, and a command that awaited it then narrated from
    /// pre-command state and returned it as success: the exact
    /// wrong-state-reported-as-applied defect these branches exist to
    /// prevent. A coalesced pass may have STARTED BEFORE the write landed,
    /// so it is worthless as evidence about the write.
    ///
    /// So the command path calls the pass body directly, outside the gate.
    /// Two concurrent passes are safe: both apply on the MainActor and the
    /// adoption rule keeps the newer payload. `isFetching` is deliberately not raised: the
    /// command owns the user-visible busy state.
    @discardableResult
    private func pullAfterWrite() async -> Bool {
        await pullOnce()
    }

    // The one adoption rule for BOTH request-response entry points, the
    // refresh pull and the command echo: adopt only when strictly newer than
    // what we hold, so an older or equal payload cannot roll a concurrent
    // push backwards, and stamp ingress .pull AUTHORITATIVELY after decode.
    // The wire never chooses its own provenance: init(from:) honors an
    // ingress key only for the persisted legacy cache, and this stamp writes
    // over whatever it decoded. nil means "do not apply", and the caller
    // still owes markHeldSnapshotPullProven, because a discarded payload was
    // still an answer. Static and pure so the rule is provable without the
    // singleton's disk writes.
    nonisolated static func pullAdoption(of fresh: SocialOpsSnapshot,
                                         over current: SocialOpsSnapshot?) -> SocialOpsSnapshot? {
        if let current, fresh.generatedAt <= current.generatedAt { return nil }
        var adopted = fresh
        adopted.ingress = .pull
        return adopted
    }

    // The flip half of the proof, pure for the same reason as pullAdoption:
    // only a push-fed snapshot upgrades, to .pull, payload untouched. nil
    // means no flip, which is what lets the caller persist exactly when a
    // value comes back and keeps the no-op branches true no-ops otherwise.
    nonisolated static func pullProvenUpgrade(of current: SocialOpsSnapshot?) -> SocialOpsSnapshot? {
        guard var current, current.ingress == .push else { return nil }
        current.ingress = .pull
        return current
    }

    // A request this machine sent was just ANSWERED, even though its payload
    // was discarded as a timestamp no-op: the answer itself proves the host,
    // so a held push-fed snapshot upgrades its provenance and persists once.
    // Without this, a loopback install that both pushes and pulls holds
    // .pushFed forever, and the day the companion dies classify() reads
    // (.absence, .pushFed) as the normal state: total silence over rotting
    // data.
    private func markHeldSnapshotPullProven() {
        guard let upgraded = Self.pullProvenUpgrade(of: snapshot) else { return }
        self.snapshot = upgraded
        persist(upgraded)
    }

    // How the snapshot we hold entered this store, for classify()'s absence x
    // cache rule. `ingress` is stamped on every write path (pull adoption,
    // command echo, ingest) and persists with the cache; a legacy cache
    // decodes to .pull (see the decoder note on SocialOpsSnapshot).
    private var cacheProvenance: PrivateServiceFetch.CacheProvenance {
        guard let snapshot else { return .empty }
        return snapshot.ingress == .push ? .pushFed : .pullProven
    }

    // INGEST path: the companion service delivered a fresh snapshot via the local inbox
    // (a change-event refresh). Accept only if newer so a replay cannot roll us
    // backwards.
    @discardableResult
    func ingest(_ fresh: SocialOpsSnapshot) -> Bool {
        if let current = snapshot, fresh.generatedAt <= current.generatedAt {
            return false
        }
        var s = fresh
        s.ingress = .push
        apply(s)
        WakeLog.shared.log("social-ops: ingested push (\(s.records.count) cells)")
        return true
    }

    // Issue an operator command to the companion service, then refresh so the grid reflects
    // the resulting cell change. Soft-fails: on error we keep the current grid
    // and surface the message.
    @discardableResult
    func sendCommand(brand: String, platform: SocialPlatform, action: SocialOpAction) async -> (ok: Bool, message: String) {
        let key = "\(brand)|\(platform.rawValue)"
        // NOT cleared here. SocialOpsStore held the clear-on-dispatch that
        // MetaAdsStore.runCommand removed and documents as a defect: it
        // erases a standing fault before the new command has any verdict, so
        // a failed sweep vanishes the moment any cell control is tapped and a
        // torn-down replacement writes nothing in its place. Cleared on this
        // command's own success, below.
        var movedByThisCommand = false
        do {
            if let updated = try await SocialOpsService.sendCommand(
                brand: brand, platform: platform, action: action) {
                // The echo goes through the same adoption rule as refresh():
                // it is wire-decoded, so its ingress is stamped rather than
                // trusted, and an older or equal echo is discarded so it
                // cannot roll a concurrent push backwards.
                if let adopted = Self.pullAdoption(of: updated, over: snapshot) {
                    apply(adopted, supersedesInFlightPulls: true)
                    movedByThisCommand = true
                } else {
                    // Discarded as a timestamp no-op, but the answered
                    // command still proves the host, and the completed round
                    // trip is a pull verdict, so it clears the same way as
                    // refresh()'s no-op branch.
                    markHeldSnapshotPullProven()
                    self.lastUpdated = Date()
                    self.lastVerdict = nil
                    // AND THEN PULL, because the message below reads the cell
                    // off the held snapshot and the echo just told us that
                    // snapshot is not newer than what we already had. A
                    // companion that answers a per-cell command with its last
                    // SWEEP snapshot produces exactly this, so the grid stayed
                    // put and the command reported the state it was asked to
                    // change: "unmuted" for a mute that applied, returned as
                    // ok: true. Adoption is still refused (an equal-or-older
                    // echo must not roll a concurrent push backwards); this
                    // just declines to narrate from it.
                    // The pull runs (the grid should still catch up), but it
                    // does NOT license narration. See below.
                    await pullAfterWrite()
                }
            } else {
                await pullAfterWrite()
            }
            // NARRATE ONLY FROM STATE THIS COMMAND MOVED. The pull above is
            // guaranteed to have STARTED after the write, but a companion
            // that has not re-swept answers it with the same timestamp, so
            // pullAdoption discards it and the held cell is still the
            // pre-command one. Reading it then reported a mute that applied
            // as "unmuted", with ok: true, and cached that into
            // lastActionByCell and onto the phone.
            // ONLY THE ECHO LICENSES NARRATION, because only the echo is the
            // companion answering THIS command.
            //
            // The pull was let in as evidence and it is not evidence. Adoption
            // asks "is this newer than what we held", and what we held can be
            // minutes stale: hold a 10:00 snapshot, the companion re-sweeps
            // its own cache at 10:05, the reader mutes a cell at 10:06, the
            // ack carries no body, and the pull returns the 10:05 snapshot.
            // 10:05 > 10:00 so it adopts, and the cell is read off state that
            // PREDATES the mute: "unmuted", ok: true, cached into
            // lastActionByCell and relayed to the phone as success.
            //
            // A pre-POST timestamp was the proposed fix and is rejected here:
            // it compares this Mac's clock against the companion's, so skew
            // either reopens the hole or wedges the panel permanently on
            // "not caught up". The echo needs no clock. The cost of this rule
            // is a pessimistic sentence after an ack-only command whose pull
            // did bring post-command state; the cost of the old one was a
            // confident wrong one. On a control plane that trade is not close.
            guard movedByThisCommand else {
                let pending = "\(action.rawValue) sent; the grid has not caught up yet"
                lastActionByCell[key] = pending
                // A SUCCESS, so it clears the fault like any other. This is
                // the COMMON path, not the rare one: a companion that has not
                // re-swept answers with an equal-or-older snapshot every time,
                // so the clear below was reached almost never and a failed
                // sweep's banner sat over successful commands indefinitely,
                // outranking the stale-grid banner beneath it.
                commandError = nil
                return (true, pending)
            }
            let msg = actionResultMessage(brand: brand, platform: platform, action: action)
            lastActionByCell[key] = msg
            commandError = nil
            return (true, msg)
        } catch is CancellationError {
            // Torn down mid-command. No verdict exists, so nothing is
            // written to commandError: stamping one fabricates a fault for a
            // command nothing refused.
            //
            // THE TUPLE STILL GOES SOMEWHERE. It used to return an empty
            // message on the reasoning that a cancelled caller is gone, but
            // SocialOpsCoordinator's phone-action handler is an unstructured
            // Task that is NOT the cancelled one, and it relays this
            // straight into notifySocialOpsAck(status: "failed", message:).
            // The phone got a failure toast with no text in it. Saying the
            // command did not complete is honest about exactly what is
            // known, and unlike commandError it claims no fault.
            return (false, "the command was cancelled before it completed")
        } catch {
            self.commandError = error.localizedDescription
            WakeLog.shared.log("social-ops: command failed (\(action.rawValue) \(brand)/\(platform.rawValue)): \(error.localizedDescription)")
            let msg = "command failed: \(error.localizedDescription)"
            lastActionByCell[key] = msg
            return (false, msg)
        }
    }

    // Trigger a live re-check of every cell on the companion service. Fire and
    // forget: it sweeps async and pushes the resulting grid back to Grux's inbox.
    @discardableResult
    func sweep() async -> Bool {
        // NOT cleared on dispatch, the rule MetaAdsStore.runCommand states:
        // erasing a standing fault before this attempt has any verdict means
        // a failed sweep vanishes the instant anything else is tapped, and a
        // torn-down replacement writes nothing in its place. Cleared on this
        // sweep's own success.
        do {
            try await SocialOpsService.triggerSweep()
            commandError = nil
            return true
        } catch is CancellationError {
            // Torn down mid-request: no verdict, so nothing is written.
            return false
        } catch {
            self.commandError = error.localizedDescription
            WakeLog.shared.log("social-ops: sweep failed: \(error.localizedDescription)")
            return false
        }
    }

    // The user dismissed the command fault banner. Without this exit the
    // channel clears only at the next command or sweep attempt, and its banner
    // branch outranks the fetch banner, so a stale command fault would
    // suppress any newer genuine fetch failure until then. Same shape as
    // MetaAdsStore.acknowledgeCommandError.
    func acknowledgeCommandError() {
        commandError = nil
    }

    // Human-readable outcome of an action, read off the freshly-applied cell.
    private func actionResultMessage(brand: String, platform: SocialPlatform, action: SocialOpAction) -> String {
        let rec = snapshot?.records.first { $0.brand == brand && $0.platform == platform }
        switch action {
        case .mute:
            return (rec?.muted ?? false) ? "muted" : "unmuted"
        case .reauth:
            if rec?.twoFAChallenge == true { return "re-auth: 2FA needed" }
            if rec?.loggedIn == true { return "re-authed" }
            return "re-auth: \(rec?.lastError.isEmpty == false ? rec!.lastError : "did not complete")"
        case .retry:
            return rec?.lastPostResult == "ok" ? "retry ok" : "retry sent"
        case .approve:
            return "approved"
        case .sweep:
            return "sweep started"
        }
    }

    /// - Parameter supersedesInFlightPulls: true ONLY for a command echo.
    ///   Unconditional was wrong twice over: a poll's own apply retired the
    ///   command's read-after-write pull (see MetaAdsStore.apply for the
    ///   sequence), and ingest(), the companion's PUSH path, reintroduced
    ///   exactly the global counter the push channel bumps that this store's
    ///   own command guard was rewritten to stop depending on. A push needs
    ///   no supersede here: pullAdoption already refuses an older payload by
    ///   timestamp, which is the protection the echo lacks.
    private func apply(_ s: SocialOpsSnapshot, supersedesInFlightPulls: Bool = false) {
        if supersedesInFlightPulls { pullSequence.supersedeInFlight() }
        self.snapshot = s
        self.lastUpdated = Date()
        self.lastVerdict = nil
        persist(s)
        // Fire native red-cell alerts on EVERY update path (pull, push, command),
        // not only on companion push events. alertOnNewReds dedups via knownRedCells,
        // so repeated calls for unchanged state are no-ops.
        SocialOpsCoordinator.shared.alertOnNewReds()
    }

    private func persist(_ s: SocialOpsSnapshot) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(s)
    }

    // Human + CLI readable mirror at ~/.grux/social-ops.md, same convention as
    // pr-digest.md. Lets a smoke test grep the grid without parsing app state.
    private func writeMarkdownMirror(_ s: SocialOpsSnapshot) {
        var lines: [String] = []
        lines.append("# Social Ops Cockpit")
        lines.append("")
        let reds = s.records.filter { $0.status == .red }.count
        let ambers = s.records.filter { $0.status == .amber }.count
        let greens = s.records.filter { $0.status == .green }.count
        lines.append("Generated: \(s.generatedAt) | source: \(s.source) | \(s.records.count) cells (\(greens) green, \(ambers) amber, \(reds) red)")
        lines.append("")
        // Worst first: red, then amber, then the rest, so the rot is on top.
        let order: [SocialStatus: Int] = [.red: 0, .amber: 1, .muted: 2, .unknown: 3, .green: 4]
        for r in s.records.sorted(by: {
            (order[$0.status] ?? 9, $0.brand, $0.platform.rawValue)
                < (order[$1.status] ?? 9, $1.brand, $1.platform.rawValue)
        }) {
            var detail = "\(r.brand) | \(r.platform.rawValue) | \(r.status.rawValue)"
            if !r.lastError.isEmpty { detail += " | \(r.lastError)" }
            lines.append(detail)
        }
        lines.append("")
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}
