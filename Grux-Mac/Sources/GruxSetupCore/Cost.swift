import Foundation

/// What a selection of features would ask for, and what it never would.
///
/// This is the arithmetic behind the only promise the product makes about setup: a
/// permission is requested because something you chose needs it, and for no other reason.
/// It is either true of a given selection or it is not, so it is computed rather than
/// asserted, and the same assertions that hold in the reviewed prototype hold here.
///
/// Everything comes from the status document's per-feature declaration. Nothing here reads
/// a contract, because a second copy of the contract is a second thing to keep in step.
public struct Cost: Equatable, Sendable {

    /// Missing any of these means the feature cannot run.
    public var blocking: [String]
    /// Missing any of these means the feature runs on a lesser path.
    public var degrading: [String]
    /// Either-or relations. `min` of the members is enough and the rest are excused.
    public var choices: [Choice]
    /// Every capability no chosen feature mentions, in any of its lists.
    ///
    /// THE INTERESTING ONE. Telling somebody what you will ask for is ordinary. Telling
    /// them, by name, the things you will never ask for because they did not pick the
    /// features that use them is the part that earns a permission dialog later.
    public var never: [String]
    /// Features that were chosen but whose dependencies were not. Not derivable from
    /// capabilities: `speakers` declares nothing and still needs Meetings running.
    public var unmetDependencies: [Dependency]

    public struct Choice: Equatable, Sendable {
        public var feature: String
        public var featureLabel: String
        public var capabilities: [String]
        public var min: Int
    }

    public struct Dependency: Equatable, Sendable {
        public var feature: String
        public var featureLabel: String
        public var needs: [String]
    }

    /// Price a selection against a status document.
    ///
    /// `selection` names feature ids. Unknown ids are reported by the caller rather than
    /// silently dropped, which is why this takes the resolved rows.
    public static func of(features chosen: [SetupStatus.Feature],
                          allCapabilities: [String],
                          allFeatures: [SetupStatus.Feature]) -> Cost {
        var blocking = Set<String>()
        var degrading = Set<String>()
        var choices: [Choice] = []

        for f in chosen {
            f.requires.forEach { blocking.insert($0) }
            f.steps.forEach { blocking.insert($0) }
            f.optional.forEach { degrading.insert($0) }
            f.optionalSteps.forEach { degrading.insert($0) }
            for g in f.anyOf {
                choices.append(Choice(feature: f.id, featureLabel: f.label,
                                      capabilities: g.capabilities, min: g.min))
            }
        }

        // A capability that blocks one feature and merely degrades another is BLOCKING.
        // Reporting it as optional would let somebody skip it and land in a broken tab.
        degrading.subtract(blocking)

        // ANY-OF GROUPS. `chat` declares an Anthropic key AND a local model in `requires`
        // with a group of min 1, meaning either will do. Reading `requires` alone would tell
        // somebody they need two credentials for a feature that needs one, which is exactly
        // the over-asking this whole flow exists to stop. A grouped capability leaves
        // `blocking` and the GROUP becomes the ask.
        var grouped = Set<String>()
        choices.forEach { grouped.formUnion($0.capabilities) }
        blocking.subtract(grouped)
        degrading.subtract(grouped)

        // Still TOUCHED, though. A grouped capability is something a chosen feature can use,
        // so it must never appear on the never-asked list.
        let touched = blocking.union(degrading).union(grouped)
        let never = allCapabilities.filter { !touched.contains($0) }

        let chosenIDs = Set(chosen.map(\.id))
        let labels = Dictionary(uniqueKeysWithValues: allFeatures.map { ($0.id, $0.label) })
        let unmet: [Dependency] = chosen.compactMap { f in
            let missing = f.dependsOn.filter { !chosenIDs.contains($0) }
            guard !missing.isEmpty else { return nil }
            return Dependency(feature: f.id, featureLabel: f.label,
                              needs: missing.map { labels[$0] ?? $0 })
        }

        return Cost(blocking: blocking.sorted(),
                    degrading: degrading.sorted(),
                    choices: choices,
                    never: never.sorted(),
                    unmetDependencies: unmet)
    }

    /// Everything a chosen feature can use, grouped or not. The complement of `never`, and
    /// the two must partition the contract exactly.
    public var touched: [String] {
        (Set(blocking).union(degrading).union(choices.flatMap(\.capabilities))).sorted()
    }

    public func ofKind(_ kind: String, in caps: [SetupStatus.Capability]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: caps.map { ($0.id, $0) })
        return (blocking + degrading).filter { byID[$0]?.kind == kind }
    }
}
