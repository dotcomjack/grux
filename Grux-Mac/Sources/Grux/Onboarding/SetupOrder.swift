import Foundation

/// P-F-1, Task F3: what the selected features need, in an order with real
/// logic rather than a fixed list.
///
/// The rules, in precedence order:
///
/// 1. Whatever needs nothing is already done, and is SHOWN done rather than
///    asked about. So is anything already satisfied on this Mac.
/// 2. Then what the most selected features need, so one grant unlocks the most.
/// 3. Then what is cheapest for the person: a toggle before a paste, a paste
///    before minutes on somebody else's website, and a macOS permission last,
///    because a refused prompt costs a trip to System Settings to undo.
/// 4. Anything optional is offered once, at the end, as a list that can be
///    skipped whole.
///
/// One ordering fact outranks all four: a step never comes before the
/// permission it cannot run without. The first look captures a frame, so it
/// follows Screen Recording even though a toggle is cheaper than a prompt.
///
/// Pure throughout: `satisfied` is passed in, so every combination is
/// checkable from one desk, including the states a developer's own Mac can
/// never be in. The live answer is `CapabilityResolver.isSatisfied`.
@MainActor
enum SetupOrder {

    /// What an item costs the person, cheapest first.
    enum Cost: Int, Comparable, CaseIterable {
        /// A switch or a button inside Grux.
        case toggle
        /// A key or an address copied in.
        case paste
        /// Minutes on somebody else's website: an OAuth, an app password, an install.
        case elsewhere
        /// A macOS prompt. Expensive to recover from when refused.
        case permission

        static func < (a: Cost, b: Cost) -> Bool { a.rawValue < b.rawValue }
    }

    nonisolated static func cost(of requirement: SetupRequirement) -> Cost {
        switch requirement {
        // A mail server wants an address and an app password from the mail
        // provider's own settings, which is the inbox being "the heaviest ask"
        // that `OnboardingModel.connectionOrder` already puts last.
        case .endpointImap, .endpointMicrosoftGraph, .endpointSocialAccounts, .stepAgentCliInstalled:
            return .elsewhere
        default:
            break
        }
        let id = requirement.rawValue
        if id.hasPrefix("perm.") { return .permission }
        if id.hasPrefix("step.") { return .toggle }
        return .paste
    }

    /// Steps that cannot run before a permission.
    nonisolated static let prerequisites: [SetupRequirement: [SetupRequirement]] = [
        .stepFirstFrameReviewed: [.permScreenRecording],
    ]

    /// The model gate has its own screen in the flow, which accepts either a
    /// key or a local model, so the plan never asks for either a second time.
    nonisolated static let handledByTheModelGate: Set<SetupRequirement> = [.keyAnthropic, .endpointOllama]

    /// The Decisions key has its own screen at the end of the extras (`decisionsKey`
    /// in `screens(for:)`), so the plan never offers it as a generic extra as well.
    nonisolated static let handledByItsOwnScreen: Set<SetupRequirement> = [.keyTypesafe]

    /// Listening is not a registry row, and it is on by default by decision,
    /// so it is planned beside the features: its item is the microphone, and
    /// setting it up is the consent screen and then the macOS prompt.
    nonisolated static let listeningId = "listening"

    struct Item: Equatable {
        let requirement: SetupRequirement
        /// Feature ids that need it, in the order they were selected.
        let neededBy: [String]
        var cost: Cost { SetupOrder.cost(of: requirement) }
    }

    struct Plan: Equatable {
        /// Feature ids that already work, shown done.
        let ready: [String]
        let required: [Item]
        let optional: [Item]
    }

    enum Rule: CaseIterable {
        /// Rule 2: needed by more selected features first.
        case mostFeatures
        /// Rule 3: cheaper for the person first.
        case cheapest
    }

    nonisolated static let rules: [Rule] = [.mostFeatures, .cheapest]

    /// The plan for these features on a Mac where `satisfied` holds.
    ///
    /// A granted microphone is not consent to listen, so listening stays in
    /// the plan until it has actually started.
    static func plan(features: [FeatureRow], listening: Bool, listeningStarted: Bool,
                     satisfied: (SetupRequirement) -> Bool,
                     skip: Set<SetupRequirement> = handledByTheModelGate.union(handledByItsOwnScreen)) -> Plan {
        var ready: [String] = []
        var need: [SetupRequirement: [String]] = [:]
        var firstSeen: [SetupRequirement] = []
        func note(_ r: SetupRequirement, for id: String, in table: inout [SetupRequirement: [String]]) {
            if table[r] == nil { firstSeen.append(r) }
            table[r, default: []].append(id)
        }
        for row in features {
            let unmet = FeatureRegistry.unmetBlocking(of: row, satisfied: satisfied).filter { !skip.contains($0) }
            if unmet.isEmpty { ready.append(row.id) }
            for r in unmet { note(r, for: row.id, in: &need) }
        }
        if listening {
            if listeningStarted { ready.append(listeningId) } else { note(.permMicrophone, for: listeningId, in: &need) }
        }
        var extra: [SetupRequirement: [String]] = [:]
        for row in features {
            for r in row.optional + row.optionalSteps
            where need[r] == nil && !skip.contains(r) && !satisfied(r) {
                note(r, for: row.id, in: &extra)
            }
        }
        let required = sorted(firstSeen.compactMap { r in need[r].map { Item(requirement: r, neededBy: $0) } })
        let optional = sorted(firstSeen.compactMap { r in extra[r].map { Item(requirement: r, neededBy: $0) } })
        return Plan(ready: ready, required: required, optional: optional)
    }

    /// Items by the rules in `rules` order, contract order breaking ties, and
    /// then no step ahead of the permission it needs.
    static func sorted(_ items: [Item], rules: [Rule] = rules) -> [Item] {
        let contract = Dictionary(uniqueKeysWithValues: SetupRequirement.allCases.enumerated().map { ($1, $0) })
        let byRules = items.sorted { a, b in
            for rule in rules {
                switch rule {
                case .mostFeatures where a.neededBy.count != b.neededBy.count:
                    return a.neededBy.count > b.neededBy.count
                case .cheapest where a.cost != b.cost:
                    return a.cost < b.cost
                default:
                    continue
                }
            }
            return (contract[a.requirement] ?? 0) < (contract[b.requirement] ?? 0)
        }
        var out: [Item] = []
        var pending = byRules
        while !pending.isEmpty {
            let waiting = Set(pending.map(\.requirement))
            let next = pending.firstIndex { item in
                !(prerequisites[item.requirement] ?? []).contains(where: waiting.contains)
            } ?? 0
            out.append(pending.remove(at: next))
        }
        return out
    }

    // MARK: - Screens

    /// What one screen of the setup shows. `remaining` counts the screens that
    /// still ask for something, this one included, so "3 left" is always true.
    enum Screen: Equatable {
        /// Rule 1: what already works. Asks nothing.
        case ready([String])
        /// One item, one decision.
        case one(Item, remaining: Int)
        /// Every required item at once, for someone who wants the whole list.
        case all([Item], remaining: Int)
        /// "N extras: go through them, or skip them all." One decision.
        case offerExtras(count: Int, remaining: Int)
        /// Every extra at once, skippable whole.
        case extras([Item], remaining: Int)
        /// The Decisions key, offered among the extras as decided: it is not a
        /// registry requirement (every gate works without it, on this Mac), so
        /// it has no `Item` and gets its own screen, counted in "N left".
        case decisionsKey(remaining: Int)

        var decisions: Int {
            switch self {
            case .ready: return 0
            case .one, .offerExtras, .decisionsKey: return 1
            case .all(let items, _), .extras(let items, _): return items.count
            }
        }

        var remaining: Int {
            switch self {
            case .ready: return 0
            case .one(_, let n), .all(_, let n), .offerExtras(_, let n), .extras(_, let n), .decisionsKey(let n): return n
            }
        }
    }

    /// The screens for a plan. One at a time: every screen asks for at most one
    /// thing, and the extras are one offer to take or skip whole, walked one by
    /// one only once taken. Otherwise the whole plan is one list and the
    /// extras another.
    ///
    /// `decisionsKey` adds the Decisions key to the extras: counted in the
    /// offer, walked last once the extras are taken, and skipped with them.
    static func screens(for plan: Plan, oneAtATime: Bool, extrasAccepted: Bool,
                        decisionsKey: Bool = false) -> [Screen] {
        var out: [Screen] = []
        if !plan.ready.isEmpty { out.append(.ready(plan.ready)) }
        let extrasCount = plan.optional.count + (decisionsKey ? 1 : 0)
        if oneAtATime {
            let extrasScreens = extrasCount == 0 ? 0 : 1 + (extrasAccepted ? extrasCount : 0)
            var left = plan.required.count + extrasScreens
            for item in plan.required { out.append(.one(item, remaining: left)); left -= 1 }
            if extrasCount > 0 {
                out.append(.offerExtras(count: extrasCount, remaining: left)); left -= 1
                if extrasAccepted {
                    for item in plan.optional { out.append(.one(item, remaining: left)); left -= 1 }
                    if decisionsKey { out.append(.decisionsKey(remaining: left)) }
                }
            }
        } else {
            var left = (plan.required.isEmpty ? 0 : 1) + (plan.optional.isEmpty ? 0 : 1) + (decisionsKey ? 1 : 0)
            if !plan.required.isEmpty { out.append(.all(plan.required, remaining: left)); left -= 1 }
            if !plan.optional.isEmpty { out.append(.extras(plan.optional, remaining: left)); left -= 1 }
            if decisionsKey { out.append(.decisionsKey(remaining: left)) }
        }
        return out
    }
}
