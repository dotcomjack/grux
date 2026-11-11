import Foundation

// MARK: - Who wants a capability

extension SetupStatus {

    /// Only the features the owner chose. Everything user facing is scoped to these: a
    /// capability wanted solely by a feature that is OFF is not something Grux will ask for,
    /// and saying otherwise is the over-asking the whole flow exists to stop.
    public var chosenFeatures: [Feature] { features.filter(\.chosen) }

    /// How a capability relates to one feature.
    public enum Want: String, Sendable {
        /// The feature cannot run without it.
        case blocking
        /// The feature runs on a lesser path without it.
        case optional
        /// One of several, any of which will do.
        case grouped
    }

    public struct Wanter: Equatable, Sendable {
        public let feature: Feature
        public let want: Want
        public init(feature: Feature, want: Want) {
            self.feature = feature
            self.want = want
        }
    }

    /// Every CHOSEN feature that mentions this capability, and how.
    ///
    /// Grouped beats blocking on purpose: a capability inside an any-of group is not
    /// individually required even when it also appears in `requires`, which is exactly how
    /// `chat` would otherwise read as needing both a hosted key and a local model.
    public func wanters(of id: String) -> [Wanter] {
        chosenFeatures.compactMap { f in
            if f.anyOf.contains(where: { $0.capabilities.contains(id) }) {
                return Wanter(feature: f, want: .grouped)
            }
            if f.requires.contains(id) || f.steps.contains(id) {
                return Wanter(feature: f, want: .blocking)
            }
            if f.optional.contains(id) || f.optionalSteps.contains(id) {
                return Wanter(feature: f, want: .optional)
            }
            return nil
        }
    }
}

// MARK: - The one next thing

/// The single most useful thing to do now, decided in ONE place.
///
/// `grux next` and `grux doctor` both answer "is anything in my way", and they disagreed:
/// on a Mac with Mailbox on and no mail server, `next` named Mail server as blocking Mailbox
/// while `doctor` printed "Everything this command can check is in order." Both now read
/// this, so the two cannot drift into giving a person opposite answers.
public enum NextStep: Equatable, Sendable {
    /// Nothing is turned on.
    case chooseFeatures
    /// A capability that `blocking` cannot run without, and that is one way (of several)
    /// for `orUnblocks` to run: it completes their unmet any-of group on its own.
    case unblock(SetupStatus.Capability, blocking: [SetupStatus.Feature],
                 orUnblocks: [SetupStatus.Feature])
    /// An any-of group chosen features cannot run without: `needed` of `options` (the
    /// unsatisfied members, cheapest first) would do. W25a: a group was never a candidate,
    /// so Chat or Research with neither the key nor a local model read as nothing required.
    case chooseOne(of: [SetupStatus.Capability], needed: Int, blocking: [SetupStatus.Feature])
    /// A chosen feature depends on features that are off.
    case turnOn(needs: [String], for: SetupStatus.Feature)
    /// Nothing blocks anything. These would only make features better.
    case nothingRequired(optionalMissing: [SetupStatus.Capability])
    /// Claude's sign-in expired on the last agent run. First, as the app's Now list puts it
    /// whatever is chosen: something that worked stopped. `blocking` names the chosen
    /// features that require the Claude Code CLI, and may be empty.
    case signIn(blocking: [SetupStatus.Feature])

    /// What a step does for each feature, in words both `grux next` and `grux doctor`
    /// print: never "cannot run without it" about a feature that has another way to run.
    public static func unblockClauses(blocking: [String], orUnblocks: [String],
                                      list: ([String]) -> String) -> String {
        let needs = blocking.isEmpty ? nil : list(blocking) + " cannot run without it"
        // "Needs", never "can run with": a feature with an either-or group may still lack
        // something else (Research also needs the web search key).
        let oneWay = orUnblocks.isEmpty ? nil
            : list(orUnblocks) + (orUnblocks.count == 1 ? " needs" : " need") + " it or another option"
        return [needs, oneWay].compactMap { $0 }.joined(separator: ", and ")
    }

    /// True when nothing stands between a chosen feature and running.
    public var isClear: Bool {
        if case .nothingRequired = self { return true }
        return false
    }

    /// The decision with the app's stored sign-in verdict (D103).
    public static func pick(_ status: SetupStatus, signInExpired: Bool) -> NextStep {
        // A missing CLI is the step, not the sign-in: signing in to a CLI that is not on
        // this Mac cannot run (the app's setup card decides the same, `listsAgentSignIn`).
        let cliMissing = status.capabilities.contains { $0.id == ClaudeSignIn.agentStep && !$0.satisfied }
        // Whenever Now shows the row (`Relevance.now` reads the verdict alone): Design
        // Studio's subscription route and workflow agents set it too (wave 28 round 2).
        if signInExpired, !cliMissing {
            // Named as unable to run: only what requires the CLI. Chat lists it as optional
            // and runs without it.
            return .signIn(blocking: status.chosenFeatures.filter { $0.steps.contains(ClaudeSignIn.agentStep) })
        }
        return pick(status)
    }

    public static func pick(_ status: SetupStatus) -> NextStep {
        let chosen = status.chosenFeatures
        if chosen.isEmpty { return .chooseFeatures }

        // Blocking first, and among blocking, the capability that unblocks the MOST chosen
        // features. Ties broken by effort: a job you can run beats a dialog you must click,
        // which beats a credential you have to go and sign up for.
        let effort = ["step": 0, "perm": 1, "endpoint": 2, "key": 3]
        func cost(_ c: SetupStatus.Capability) -> Int { effort[c.kind] ?? 9 }
        // A single capability (`needed` 0) or an unmet any-of group (`needed` of `caps`).
        struct Candidate {
            let caps: [SetupStatus.Capability]
            let needed: Int
            var blocks: [SetupStatus.Feature]
            /// For a single capability, the features in `blocks` that require it on their
            /// own; the rest have another option in their group.
            var requiredBy: Set<String> = []
            var label: String { caps.map(\.label).joined(separator: " ") }
        }
        // Every chosen feature's any-of group with too few members met: the options left,
        // cheapest first, and how many of them it still needs. W25a: a member of a group is
        // `.grouped`, never `.blocking`, so without this nothing named an unmet group at all.
        struct Unmet { let feature: SetupStatus.Feature; let options: [SetupStatus.Capability]; let needed: Int }
        var unmet: [Unmet] = []
        for f in chosen {
            for group in f.anyOf {
                let members = group.capabilities.compactMap { id in
                    status.capabilities.first { $0.id == id }
                }
                let met = members.filter(\.satisfied).count
                let options = members.filter { !$0.satisfied }
                    .sorted { (cost($0), $0.label) < (cost($1), $1.label) }
                guard met < group.min, !options.isEmpty else { continue }
                unmet.append(Unmet(feature: f, options: options,
                                   needed: min(group.min - met, options.count)))
            }
        }
        // A capability unblocks every feature that requires it on its own AND every feature
        // whose unmet group it completes alone: the key that Focus log needs and that also
        // settles Chat's model choice unblocks two features, not one (W25 round 2).
        var candidates: [Candidate] = status.capabilities.compactMap { cap in
            guard !cap.satisfied else { return nil }
            let required = Set(status.wanters(of: cap.id).filter { $0.want == .blocking }
                .map(\.feature.id))
            let blocking = chosen.filter { f in
                required.contains(f.id) || unmet.contains { u in
                    u.feature.id == f.id && u.needed == 1 && u.options.contains { $0.id == cap.id }
                }
            }
            guard !blocking.isEmpty else { return nil }
            return Candidate(caps: [cap], needed: 0, blocks: blocking, requiredBy: required)
        }
        for u in unmet {
            if let i = candidates.firstIndex(where: {
                $0.needed == u.needed && $0.caps.map(\.id) == u.options.map(\.id)
            }) {
                if !candidates[i].blocks.contains(where: { $0.id == u.feature.id }) {
                    candidates[i].blocks.append(u.feature)
                }
            } else {
                candidates.append(Candidate(caps: u.options, needed: u.needed, blocks: [u.feature]))
            }
        }
        // A group competes by its cheapest option: that is the effort it asks of a person.
        if let best = candidates.max(by: { a, b in
            if a.blocks.count != b.blocks.count { return a.blocks.count < b.blocks.count }
            let ea = cost(a.caps[0]), eb = cost(b.caps[0])
            if ea != eb { return ea > eb }
            return a.label > b.label
        }) {
            // A step that unblocks exactly what a one-of choice holding it unblocks is that
            // choice: say "one of these", not one option as though it were the only way.
            if best.needed == 0, let choice = candidates.first(where: { c in
                c.needed == 1 && c.blocks.count == best.blocks.count
                    && c.caps.contains { $0.id == best.caps[0].id }
            }) {
                return .chooseOne(of: choice.caps, needed: 1, blocking: choice.blocks)
            }
            return best.needed == 0
                ? .unblock(best.caps[0],
                           blocking: best.blocks.filter { best.requiredBy.contains($0.id) },
                           orUnblocks: best.blocks.filter { !best.requiredBy.contains($0.id) })
                : .chooseOne(of: best.caps, needed: best.needed, blocking: best.blocks)
        }

        for f in chosen {
            let missing = f.dependsOn.filter { id in !chosen.contains { $0.id == id } }
            if !missing.isEmpty { return .turnOn(needs: missing, for: f) }
        }

        return .nothingRequired(optionalMissing: status.capabilities.filter {
            !$0.satisfied && !status.wanters(of: $0.id).isEmpty
        })
    }
}

// MARK: - The rail only moves forward

/// Which beats a command's rails may still draw.
///
/// The six beats are an order, and a screen that marks PROVE and then marks HAND OFF under
/// it reads as a step going backwards. `grux next` did exactly that: PROVE at the top, HAND
/// OFF at the bottom, two different steps marked for one answer. A beat that comes before
/// one already drawn prints its content under the rail already on screen instead.
public struct RailCursor: Sendable {
    public private(set) var furthest: Beat?
    public init() {}

    /// Whether `beat` gets a rail of its own, recording it when it does.
    public mutating func draws(_ beat: Beat) -> Bool {
        let order = Beat.allCases
        if let furthest, let was = order.firstIndex(of: furthest),
           let now = order.firstIndex(of: beat), now < was {
            return false
        }
        furthest = beat
        return true
    }
}
