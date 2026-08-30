import Foundation
import GruxSetupCore

/// Questions several commands ask of the status document, answered in one place.
///
/// `why`, `which`, `next` and `permissions` all need "who wants this capability, and is it
/// blocking or merely nice". Four copies of that would be four chances to disagree, and the
/// product rule is that the same word means the same thing on every surface.
enum Lookup {

    /// Only the features the owner chose. Everything user facing is scoped to these: a
    /// capability wanted solely by a feature that is OFF is not something Grux will ask for,
    /// and saying otherwise is the over-asking the whole flow exists to stop.
    static func chosen(_ status: SetupStatus) -> [SetupStatus.Feature] {
        status.features.filter(\.chosen)
    }

    /// How a capability relates to one feature.
    enum Want: String {
        /// The feature cannot run without it.
        case blocking
        /// The feature runs on a lesser path without it.
        case optional
        /// One of several, any of which will do.
        case grouped
    }

    struct Wanter {
        let feature: SetupStatus.Feature
        let want: Want
    }

    /// Every CHOSEN feature that mentions this capability, and how.
    ///
    /// Grouped beats blocking on purpose: a capability inside an any-of group is not
    /// individually required even when it also appears in `requires`, which is exactly how
    /// `chat` would otherwise read as needing both a hosted key and a local model.
    static func wanters(of id: String, in status: SetupStatus) -> [Wanter] {
        chosen(status).compactMap { f in
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

    /// The state to draw for a capability, given who wants it.
    ///
    /// "Nobody chose a feature that uses this" is a FIFTH answer, distinct from optional, and
    /// it is the one that makes the promise legible: skipped means Grux will never ask.
    static func state(of cap: SetupStatus.Capability, in status: SetupStatus) -> RowState {
        if cap.satisfied { return cap.selfAttested ? .attested : .satisfied }
        let wants = wanters(of: cap.id, in: status)
        if wants.isEmpty { return .skipped }
        return wants.contains(where: { $0.want == .blocking }) ? .needed : .optional
    }

    static func capability(_ id: String, in status: SetupStatus) -> SetupStatus.Capability? {
        status.capabilities.first { $0.id == id }
    }

    /// Find a capability by id, or by label, case insensitively.
    ///
    /// Somebody reading the screen sees "Microphone" and types that. Refusing it because the
    /// id is `perm.microphone` teaches them the schema for no reason, and the labels are
    /// unique so there is nothing to disambiguate.
    static func resolve(_ needle: String, in status: SetupStatus) -> SetupStatus.Capability? {
        if let exact = capability(needle, in: status) { return exact }
        let lowered = needle.lowercased()
        return status.capabilities.first { $0.label.lowercased() == lowered }
            ?? status.capabilities.first { $0.id.lowercased() == lowered }
    }

    /// The closest ids to something that did not resolve, for a "did you mean".
    ///
    /// Substring matching alone is not enough and this was measured: `grux which mikrophone`
    /// suggested nothing, because a transposed letter neither contains nor is contained by
    /// the right answer. A misspelling that just says "no such capability" sends somebody to
    /// read forty one rows looking for the one they nearly typed.
    static func nearest(_ needle: String, in status: SetupStatus, limit: Int = 3) -> [String] {
        let lowered = needle.lowercased()

        struct Scored { let id: String; let distance: Int }
        let scored: [Scored] = status.capabilities.map { cap in
            // Compare against the id, its last segment, and the label, and keep the best.
            // `perm.microphone` should be findable by "microphone" and by "Microphone".
            let tail = cap.id.split(separator: ".").last.map(String.init) ?? cap.id
            let candidates = [cap.id.lowercased(), tail.lowercased(), cap.label.lowercased()]
            let best = candidates.map { edits(lowered, $0) }.min() ?? Int.max
            // A substring hit is as good as one edit: typing "mic" should find Microphone
            // even though the edit distance is large.
            let contains = candidates.contains { $0.contains(lowered) && lowered.count >= 3 }
            return Scored(id: cap.id, distance: contains ? min(best, 1) : best)
        }

        // A cutoff scaled to the length of what was typed. Without it every miss suggests
        // three unrelated capabilities, which is worse than suggesting none.
        let cutoff = max(2, lowered.count / 3)
        return scored.filter { $0.distance <= cutoff }
            .sorted { ($0.distance, $0.id) < ($1.distance, $1.id) }
            .prefix(limit).map(\.id)
    }

    /// Levenshtein distance, two rows rather than a full matrix.
    ///
    /// Small enough to keep here. Bringing in a dependency to spell check a forty one item
    /// list would be the tail wagging the dog.
    static func edits(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
