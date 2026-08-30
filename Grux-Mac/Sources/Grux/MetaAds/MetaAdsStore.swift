import SwiftUI

// Observable store for the Meta Ads tab. Mirrors EmpireSnapshotStore: failover
// pull from the companion engine (port 3857), a persisted last-good JSON so the pane has
// something before the first live pull, a ~/.grux/meta-ads-snapshot.md mirror for
// CLI smoke tests, and a polling timer. Consumed by U2 (tab view) / U3 (sections) /
// U5 (Empire roll-up).
//
// SAFETY: this store reads a SIMULATE / OBSERVE snapshot. Mode flips and the kill
// switch are forwarded to the engine, which is the only component that can act
// live, and only when double-gated (bootstrapped account AND AUTONOMOUS). Flipping
// mode on an act_PLACEHOLDER account cannot spend.

@MainActor
final class MetaAdsStore: ObservableObject {
    static let shared = MetaAdsStore()

    @Published private(set) var snapshot: MetaAdsSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isFetching = false
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
    // A COUNT, NOT A BOOL, because the halt bypasses the gate and two writes
    // can therefore be in flight at once. As a Bool the owning command's
    // defer lowered the flag while the halt it overtook was still on the
    // wire, so every control re-enabled beside a live Emergency Stop: the
    // exact two-writes race the flag exists to prevent, reintroduced by the
    // exemption that fixed the dead kill switch. Every command takes a hold
    // now, bypassing or not; only the REFUSAL is exempted.
    @Published private(set) var inFlightWrites = 0
    var isMutating: Bool { inFlightWrites > 0 }
    // A failed control-plane write (kill switch, mode flip). Deliberately a
    // separate channel from lastError: refresh() clears lastError on every
    // 30s poll tick, and a successful GET leaving it nil used to erase a
    // failed Emergency Stop within seconds. Cleared at the start of the next
    // command attempt (or by its success) or by the user acknowledging the
    // banner, never by a fetch.
    @Published private(set) var commandError: String?

    private var loaded = false
    private var pollTimer: Timer?
    // Coalesces refreshes: any number of requests during one pull owe one
    // follow-up pass, and a cancelled awaiter cannot swallow another
    // caller's request. The whole argument lives on RefreshGate.
    private let refreshGate = RefreshGate()
    // Start-order guard: pullAfterWrite() runs outside the gate, so a command
    // pull and the 30s poll pull can be in flight together. apply() had no
    // ordering guard at all, so the slower-but-earlier one won.
    private var pullSequence = PrivateServiceFetch.PullSequence()
    // Bumped on every commandError WRITE. A command clears the channel on its
    // own success only when this has not moved since it started, so it can
    // tell "the fault I am replacing" from "a fault somebody else recorded
    // while I was on the wire". Needed because the HALT bypasses the gate on
    // purpose and therefore runs BESIDE another command.
    private var commandErrorGeneration: UInt64 = 0
    // Whether the standing fault is a FAILED HALT. The generation counter
    // above only distinguishes a fault recorded CONCURRENTLY with a command;
    // sequentially it cannot help, so a halt that failed at 10:00 was wiped
    // by an unrelated Approve that succeeded at 10:05, and MetaAdsOpsSection
    // renders only commandError, so the record of a kill-switch write that
    // never reached the engine vanished unacknowledged while spend continued.
    //
    // "A success clears the fault" and "a failed halt stays visible until
    // acted on" cannot both hold, and on the one control where the wrong
    // answer costs money the halt wins. Only acknowledgement, or a halt that
    // itself succeeds, takes this one down.
    private var commandErrorIsHalt = false

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("meta-ads-snapshot.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("meta-ads-snapshot.md")
    }

    private init() {}

    // MARK: - Load cache

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(MetaAdsSnapshot.self, from: data) {
            self.snapshot = cached
        }
    }

    // MARK: - Refresh

    // Error state is NOT cleared at the top: the fields hold the last
    // completed verdict until this pull lands one of its own. Clearing here
    // unmounted the absence card mid-recovery (its mount keys on the flag),
    // which cancelled the very pull it was awaiting.
    func refresh() async {
        await refreshGate.run(isFetching: { self.isFetching = $0 }) {
            await self.pullOnce()
        }
    }

    private func pullOnce() async {
        let seq = pullSequence.begin()
        do {
            let fresh = try await MetaAdsService.fetchLatest()
            guard pullSequence.claimWrite(seq) else { return }
            apply(fresh)
        } catch is CancellationError {
            // The awaiting task was torn down mid-pull. No verdict exists, so
            // every error field stays exactly as it was: writing one here is
            // how a cancelled pull once recorded a fabricated absence on this
            // singleton. The gate owns any request that coalesced behind
            // this pass.
            return
        } catch {
            // The absence x cache rule lives in classify(). There is no push
            // path here, so a warm snapshot always proves an engine once
            // answered a PULL from this machine: absence over it reclassifies
            // to an outage with the technical message, which for the
            // removed-key case names the defaults key (run's
            // unconfiguredDetail) instead of counting zero bases.
            guard let verdict = PrivateServiceFetch.classify(
                error, cache: snapshot == nil ? .empty : .pullProven) else { return }
            // A failure that is stale on arrival must not stamp an error
            // over a newer pull's good data.
            guard pullSequence.claimWrite(seq) else { return }
            self.lastVerdict = verdict
            WakeLog.shared.log("meta-ads: pull failed: \(verdict.displayMessage)")
        }
    }

    // MARK: - Control plane

    // The user dismissed the command fault banner. Without this exit the
    // channel clears only at the next command attempt, and its banner branch
    // outranks the fetch banner, so a stale command fault would suppress any
    // newer genuine fetch failure until the next command or app relaunch.
    //
    // DISMISSING IS THE ACTING-ON. The halt-stickiness rule says a failed
    // Emergency Stop is cleared only by acknowledgement or by a halt that
    // succeeds, and this is the acknowledgement, so it must lower the flag
    // too. It did not, and the flag is checked on BOTH the success and the
    // catch arm, so after one dismissed halt failure the channel went
    // permanently deaf: every later non-halt fault evaluated
    // `!true || false` and was never written at all. No banner on either
    // surface, for the process lifetime, recoverable only by attempting
    // another halt. A rule meant to keep one fault visible ended up hiding
    // all the others.
    //
    // Three sites write commandError (here, the success arm, the catch arm)
    // and this was the one that did not maintain the flag beside it.
    func acknowledgeCommandError() {
        commandError = nil
        commandErrorIsHalt = false
    }

    // A press that arrives while another command is in flight. It is REFUSED,
    // not queued: two control-plane writes racing to the engine is what the
    // guard exists to stop, and a queue would apply the second one after the
    // first had already moved the state it was chosen against.
    //
    // Refused is not the same as dropped, and the old bare `return` made them
    // the same thing. The press produced no error, no change and no
    // affordance, which on the Emergency Stop is the worst possible silence:
    // somebody hits the kill switch, nothing happens, and nothing tells them
    // to hit it again. The controls now disable while isMutating (see
    // MetaAdsView.killButton), so this is the race that slips past the
    // disabled state rather than the normal path.
    // Internal, not private: MetaAdsStoreErrorChannelTests pins that the HALT
    // is never refused with THIS sentence, which it cannot tell from an
    // ordinary timeout failure without naming it.
    static let commandInFlightMessage =
        "Another engine command is still being applied. Wait for it to finish, then try again."

    // THE INVARIANT: ONE FLAG GOVERNS EVERY CONTROL-PLANE POST, and this is
    // the only place that raises it. Every write to the engine, from any
    // surface, runs through here.
    //
    // It did not used to. isMutating was raised only by setMode and setKill,
    // whose one caller was the Emergency Stop button, while
    // MetaAdsModeControl and MetaAdsActionBar called MetaAdsService directly
    // behind their own @State flags, each private to one view instance. So
    // three surfaces disabled themselves and each other on a flag two of
    // them never raised: pressing AUTONOMOUS held a POST open for up to 12s
    // per base with Emergency Stop still live beside it, which is precisely
    // the race those .disabled() clauses were added to close.
    //
    // `label` names the write in the log line and nothing else. The banner
    // shows the provider's own sentence, because a reader learns more from
    // why it failed than from which verb failed.
    /// What ONE command did, returned to the caller that asked for it.
    ///
    /// THE CHANNEL IS NOT A RETURN VALUE. `commandError` is published and four
    /// surfaces render it, so a caller that ran a write and then SAMPLED it
    /// after the await was reading whatever any other surface had written in
    /// between. Reachable through the UI in one gesture: tap Approve, tap
    /// Emergency Stop while it flies, the halt is refused and stamps the
    /// in-flight sentence, the approve then succeeds, and the action bar
    /// reports "Approve failed" for a command the engine applied. The verdict
    /// about MY command comes back to ME; the channel stays for the banner.
    enum CommandOutcome: Equatable {
        case applied
        /// THE GATE said no, not the engine. Nothing was sent.
        ///
        /// A TYPE, NOT A MESSAGE IN THE SHARED CHANNEL, and that distinction
        /// retires a whole class of bug. The refusal used to be written into
        /// `commandError`, where its advice ("wait for it to finish, then
        /// try again") outlived the command it referred to, so four separate
        /// rounds each added a rule about WHEN to clear it: on the winner's
        /// completion, but not on a bypassing halt's start, but not on an
        /// unrelated command's start either, and the views copied the string
        /// into their own @State where none of those rules reached it.
        /// Transient advice does not belong in a sticky channel. It comes
        /// back to the caller that earned it and expires when they stop
        /// showing it.
        case refused(String)
        /// The ENGINE refused it, or the transport did. A real fault, sticky
        /// until acknowledged.
        case failed(String)
        /// Torn down mid-flight. No verdict about the engine exists, so a
        /// caller must say NOTHING rather than claim either result.
        case cancelled
    }

    /// - Parameter bypassesInFlightGate: reserved for the HALT, see `setKill`.
    ///   It exempts the command from being REFUSED, and from nothing else: a
    ///   bypassing command still takes its own hold, so it can neither lower
    ///   a hold it did not take nor have its own lowered out from under it.
    // NOT @discardableResult. The attribute is why MetaAdsView's command-bar
    // chip could ignore a returned .refused while its four siblings all
    // handled it, and why the compiler could not say so. A control-plane
    // verdict that nobody reads is an invisible refusal, which is the defect
    // this whole wave exists to remove. A call site that genuinely does not
    // care must now write `_ =`, which is at least greppable.
    /// - Parameter write: performs the POST and returns TRUE if it published
    ///   fresher state itself (an echoed snapshot it applied). Returned by the
    ///   closure rather than inferred, because inferring it is what broke:
    ///   a global apply counter read either side of the write answered "did
    ///   ANY apply happen", and the 30s poll's own apply satisfied that, so a
    ///   command skipped its read-after-write and left the panel on a pull
    ///   that STARTED BEFORE the write while still returning .applied. A
    ///   per-command question needs per-command state, threaded, never
    ///   inferred from a counter every other actor can move.
    func runCommand(_ label: String,
                    bypassesInFlightGate: Bool = false,
                    isHalt: Bool = false,
                    _ write: @MainActor () async throws -> Bool) async -> CommandOutcome {
        let faultGenerationAtStart = commandErrorGeneration
        if !bypassesInFlightGate, inFlightWrites > 0 {
            // Returned, not published. See CommandOutcome.refused.
            return .refused(Self.commandInFlightMessage)
        }
        // EVERY command takes a hold, including the halt. Holding is what
        // keeps the other controls disabled for as long as ANY write is on
        // the wire; the bypass above is only about who may be refused.
        //
        // NOTHING IS CLEARED HERE. Clearing commandError at the START of a
        // command erased a FAILED Emergency Stop the moment any unrelated
        // command was dispatched, before that command had any verdict at
        // all, so the surface went silent about a live spend risk. A real
        // fault is now cleared only by the reader acknowledging it or by a
        // newer fault replacing it.
        inFlightWrites += 1
        defer { inFlightWrites -= 1 }
        do {
            // A SUCCESS CLEARS THE FAULT. Round 13 removed the clear-on-START
            // (it erased a failed Emergency Stop the moment any unrelated
            // command was dispatched) and added no clear anywhere else, so a
            // control that failed once wore its amber banner over every
            // subsequent success. Worse, MetaAdsView and MetaAdsOpsSection
            // gate the absence card and the empty state on commandError ==
            // nil, so one failed command permanently suppressed the
            // explanatory empty state on a fresh install. Clearing HERE, on a
            // verdict rather than on a dispatch, is what the field's own doc
            // always claimed.
            // READ-AFTER-WRITE IS THE STORE'S JOB, NOT THE CALLER'S.
            // `pullAfterWrite` was added as the seam for this and left
            // private, so setMode and setKill used it and the eight
            // power-tool sites in the action bar and the variant spawner
            // went on awaiting the coalescing `refresh()`, which can return
            // having pulled nothing. A rule every call site must remember
            // is a rule that gets forgotten, so the loop closes it here:
            // when a write does not itself publish fresher state, this pulls.
            let published = try await write()
            if !published { await pullAfterWrite() }
            // CLEARS THE FAULT THIS COMMAND SUPERSEDED, NOT ONE RECORDED
            // WHILE IT RAN. setKill(on: true) bypasses the gate so a halt
            // runs beside another command: tap Approve, tap Emergency Stop,
            // the halt fails fast against an unreachable engine and stamps
            // the channel, then the approve completes and used to wipe it.
            // The failed halt vanished from four surfaces at once.
            if commandErrorGeneration == faultGenerationAtStart,
               !commandErrorIsHalt || isHalt {
                commandError = nil
                commandErrorIsHalt = false
            }
            return .applied
        } catch is CancellationError {
            // Torn down mid-command. No verdict exists, so nothing is
            // written: stamping commandError here fabricates a fault for a
            // command nothing refused.
            return .cancelled
        } catch {
            // A STICKY HALT FAULT OUTRANKS A LATER ONE IN THE SHARED
            // CHANNEL. Stickiness guarded only the success door: the catch
            // arm wrote unconditionally, so a halt that failed against an
            // unreachable engine was erased by the next Approve that ALSO
            // failed, and the record that the kill switch never landed left
            // every surface unacknowledged while spend continued. The new
            // fault is not lost, it goes back to its own caller as
            // .failed(...) and that surface renders it; what it may not do is
            // evict the halt from the channel four views read.
            if !commandErrorIsHalt || isHalt {
                self.commandError = error.localizedDescription
                commandErrorGeneration &+= 1
                commandErrorIsHalt = isHalt
            }
            WakeLog.shared.log("meta-ads: \(label) failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
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
    /// adoption rule keeps the newer payload. `isFetching` is deliberately
    /// not raised, because the command already holds the control-disabling
    /// flag and a second spinner would claim a second user-visible refresh.
    private func pullAfterWrite() async {
        await pullOnce()
    }

    // Flip a brand's engine mode. The engine echoes the updated snapshot when it
    // can; otherwise we re-pull. Spend-safe: act_PLACEHOLDER brands cannot go live.
    func setMode(brand: String, mode: String) async -> CommandOutcome {
        await runCommand("setMode") {
            guard let s = try await MetaAdsService.setMode(brand: brand, mode: mode)
            else { return false }
            self.apply(s, supersedesInFlightPulls: true)
            return true
        }
    }

    // Toggle the global kill switch. Fail-safe: on == true only pauses / blocks.
    //
    // A HALT IS NEVER QUEUED BEHIND ANOTHER WRITE. Routing every command
    // through one gate handed the in-flight guard a veto over Emergency
    // Stop: Force scale holds a POST open for up to 12s PER BASE and then
    // awaits a refresh for as long again, and STOP ALL pressed during that
    // window was refused with "wait for it to finish, then try again". For
    // an ad-spend kill switch that is the wrong resolution in the only
    // moment the control exists for. So a halt bypasses the gate and goes
    // out beside whatever is running.
    //
    // Only the HALT bypasses. Resuming (on == false) is an ordinary write
    // and takes its turn, because nothing is urgent about turning spend back
    // on and letting it overtake an in-flight command would be a way to
    // un-pause an engine somebody is mid-way through pausing. Concurrency is
    // safe either way: both writes land on the MainActor, and the halt is
    // fail-safe, so the worst ordering leaves the engine paused.
    func setKill(on: Bool) async -> CommandOutcome {
        // isHalt is `on`, NOT "this is the setKill call site". Keying the
        // sticky rule on a shared label made a failed RESUME sticky too, and
        // a failed resume that no successful command can clear also suppresses
        // the empty state and the absence card, which both gate on
        // commandError == nil. Only stopping spend is the safety-critical
        // direction; starting it again is an ordinary write.
        await runCommand("setKill", bypassesInFlightGate: on, isHalt: on) {
            guard let s = try await MetaAdsService.setKill(on: on) else { return false }
            self.apply(s, supersedesInFlightPulls: true)
            return true
        }
    }

    // MARK: - Polling

    // Light polling so the pane stays fresh while the tab is open. Idempotent:
    // calling start twice keeps a single timer.
    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Apply + persist

    /// THE ONE WRITE PATH for a snapshot, whatever produced it.
    ///
    /// A command echo retires every pull already on the wire: the engine
    /// answered with post-command state, so a poll that started earlier
    /// describes a moment that no longer exists. Without this the echo
    /// published without advancing the sequence, and the older poll's
    /// response then claimed its write and reverted the panel to the
    /// pre-command mode, clearing the verdict on its way past.
    /// - Parameter supersedesInFlightPulls: true ONLY for a command echo.
    ///
    /// It used to be unconditional, which broke the very thing it was added
    /// for. `pullOnce` succeeds by `claimWrite(seq)` then `apply(fresh)`, so
    /// an ordinary poll's apply retired every pull that had started AFTER it,
    /// including the command's own read-after-write pull: poll starts (seq 1),
    /// the command POSTs and starts its pull (seq 2), the older poll lands
    /// first, claims 1, and supersede sets written = started = 2, so the
    /// command's fresher answer then fails `2 > 2` and is discarded whole. The
    /// panel keeps the pre-command snapshot while the command returns
    /// .applied, which is the revert this mechanism exists to prevent,
    /// produced by the mechanism.
    ///
    /// The echo is the one write with no sequence of its own AND no adoption
    /// rule to fall back on, so it is the one write that needs this.
    private func apply(_ s: MetaAdsSnapshot, supersedesInFlightPulls: Bool = false) {
        if supersedesInFlightPulls { pullSequence.supersedeInFlight() }
        self.snapshot = s
        self.lastUpdated = Date()
        self.lastVerdict = nil
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(s)
    }

    // Human + CLI readable mirror at ~/.grux/meta-ads-snapshot.md so a smoke test
    // can grep the result without parsing app state. Same convention as the empire
    // and pr-digest mirrors.
    private func writeMarkdownMirror(_ s: MetaAdsSnapshot) {
        func money(_ cents: Int?) -> String {
            guard let c = cents else { return "n/a" }
            return String(format: "$%.2f", Double(c) / 100.0)
        }
        var lines: [String] = []
        lines.append("# Meta Ads Engine Snapshot")
        lines.append("")
        let sim = (s.source?.simulate ?? true) ? "SIMULATE" : "LIVE"
        let boot = (s.source?.bootstrapped ?? false) ? "bootstrapped" : "act_PLACEHOLDER"
        lines.append("Generated: \(s.generatedAt) | mode: \(s.mode) | \(sim) | \(boot) | kill: \(s.killSwitchOn ? "ON" : "off")")
        lines.append("")
        for b in s.brands {
            let k = b.kpis
            let p = b.pacing
            lines.append("## \(b.displayName) (\(b.effectiveMode(default: s.mode)))")
            lines.append("spend today \(money(k.spendTodayCents)) / \(money(p.dailyCapCents)) cap | week \(money(k.spendWeekCents)) / \(money(p.weeklyCapCents)) cap")
            lines.append("impr \(k.impressions) | clicks \(k.clicks) | conv \(k.conversions) | cpa \(money(k.cpaCents)) | ctr \(k.ctr.map { String(format: "%.3f", $0) } ?? "n/a") | roas \(k.roas.map { String(format: "%.2f", $0) } ?? "n/a")")
            let winners = b.families.filter { $0.bucket == .winners }.count
            let contenders = b.families.filter { $0.bucket == .contenders }.count
            let graveyard = b.families.filter { $0.bucket == .graveyard }.count
            lines.append("families: \(winners) winners | \(contenders) contenders | \(graveyard) graveyard")
            lines.append("")
        }
        if !s.journal.isEmpty {
            lines.append("## Decision Journal (latest)")
            for e in s.journal.prefix(10) {
                let applied = e.applied ? "APPLIED" : "logged"
                lines.append("- [\(e.ts)] \(e.brand ?? "-") \(e.action) (\(applied)): \(e.rationale ?? "")")
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}
