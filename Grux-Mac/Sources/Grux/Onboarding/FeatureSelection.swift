import Foundation

/// Which features the owner actually wants.
///
/// ## Why this did not exist until now
///
/// Grux had no concept of a feature being off. All thirty nine surfaces mounted, always, and
/// `FeatureRow.tier` drove only the BETA badge. "Pick the features you want" had nothing to
/// pick, which is why the promise on the website could not be kept: a permission queue
/// derived from a selection needs a selection to derive from.
///
/// ## Absence means everything is on
///
/// THE MOST IMPORTANT LINE IN THIS FILE. An install that predates CR-36 has nothing stored,
/// and it must not lose thirty nine features on upgrade. `nil` is not an empty selection, it
/// is "never asked", and the two answer the question differently on purpose. Only an
/// explicit choice turns anything off.
///
/// ## It does not weaken the discoverability rule, it is why that rule now has teeth
///
/// `CLAUDE.md` locks that nothing ships off and undiscoverable: named at first run, a
/// permanent home, and its off state explained. Giving thirty nine features an off switch is
/// the change most likely to break that, so all three are load bearing here. The CHOOSE
/// screen lists every feature rather than a curated subset. `grux list features` and the
/// Settings pane show every feature whether or not it was chosen. And the COST screen
/// explains the off state from the other direction, by naming what will never be asked for.
@MainActor
enum FeatureSelection {

    /// A storage format. Renaming it orphans every existing choice.
    static let defaultsKey = "grux.features.selected"

    /// What is stored, or nil when nobody has ever chosen.
    ///
    /// Unknown ids are DROPPED on read rather than kept. A feature deleted in an upgrade
    /// would otherwise sit in this set forever, counting toward a total nothing can show.
    static func stored(known: Set<String> = Set(FeatureRegistry.rows.map(\.id))) -> Set<String>? {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return nil
        }
        return Set(raw).intersection(known)
    }

    /// Has the owner ever chosen? Distinct from "chose nothing", which is a real answer.
    static var hasChosen: Bool {
        UserDefaults.standard.array(forKey: defaultsKey) != nil
    }

    static func isOn(_ id: String) -> Bool {
        guard let set = stored() else { return true }
        return set.contains(id)
    }

    /// Replace the whole selection. Sorted on write so the stored value is stable and a
    /// diff of the defaults plist is readable.
    static func choose(_ ids: some Sequence<String>) {
        let known = Set(FeatureRegistry.rows.map(\.id))
        let clean = Set(ids).intersection(known)
        UserDefaults.standard.set(clean.sorted(), forKey: defaultsKey)
        SetupStatusFile.write()
    }

    static func enable(_ id: String) {
        var set = stored() ?? Set(FeatureRegistry.rows.map(\.id))
        set.insert(id)
        choose(set)
    }

    static func disable(_ id: String) {
        var set = stored() ?? Set(FeatureRegistry.rows.map(\.id))
        set.remove(id)
        choose(set)
    }

    /// Back to never-asked, which means everything on. Not the same as choosing all thirty
    /// nine: this forgets that a choice was ever made, so a later first run asks again.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        SetupStatusFile.write()
    }

    /// Features that are ON and whose dependencies are OFF.
    ///
    /// The settled decision is to warn and offer to turn both off, never to silently
    /// disable a dependent and never to make the state impossible to express: somebody is
    /// allowed to want a half-configured Grux while they think about it.
    static func unmetDependencies() -> [(feature: FeatureRow, needs: [String])] {
        FeatureRegistry.rows.compactMap { row in
            guard isOn(row.id) else { return nil }
            let missing = row.dependsOn.filter { !isOn($0) }
            guard !missing.isEmpty else { return nil }
            return (row, missing)
        }
    }
}
