import XCTest
@testable import Grux

/// NOTHING SHIPS OFF AND UNDISCOVERABLE.
///
/// The lock in CLAUDE.md says a feature that is off and unfindable is a
/// deleted feature with dead code behind it. The registry is the list of
/// everything Grux can do, so every row in it must have exactly one door.
@MainActor
final class RegistryReachabilityTests: XCTestCase {

    func test_everyRegistryRowHasARecordedDoor() {
        let recorded = Set(FeatureRegistry.dispositions.keys)
        let ids = Set(FeatureRegistry.rows.map(\.id))
        let orphans = ids.subtracting(recorded).sorted()
        XCTAssertTrue(orphans.isEmpty,
                      "registry rows with no recorded door: \(orphans)")
    }

    /// The other direction, which is how a door outlives the thing behind it.
    func test_noDoorIsRecordedForSomethingThatNoLongerExists() {
        let recorded = Set(FeatureRegistry.dispositions.keys)
        let ids = Set(FeatureRegistry.rows.map(\.id))
        let ghosts = recorded.subtracting(ids).sorted()
        XCTAssertTrue(ghosts.isEmpty, "doors recorded for rows that do not exist: \(ghosts)")
    }

    /// The counts from the approved design, so a row cannot change door
    /// without somebody deciding to.
    func test_theDispositionsReconcileToTheApprovedCounts() {
        let rows = FeatureRegistry.rows
        XCTAssertEqual(rows.count, 37, "the registry changed size; re-derive the counts below from the spec")
        func count(_ match: (FeatureRow.Disposition) -> Bool) -> Int {
            FeatureRegistry.dispositions.values.filter(match).count
        }
        XCTAssertEqual(count { $0 == .rail }, 12, "rail rows")
        XCTAssertEqual(count { $0 == .studio }, 3, "behind Studio")
        XCTAssertEqual(count { if case .folds = $0 { return true }; return false }, 9, "folds")
        XCTAssertEqual(count { $0 == .developer }, 4, "behind Developer")
        XCTAssertEqual(count { $0 == .labs }, 7, "behind Labs")
        XCTAssertEqual(count { $0 == .brandScoped }, 2, "brand scoped")
        XCTAssertEqual(count { $0 == .ripped }, 0, "ripped (domains was deleted outright in C13)")
        XCTAssertEqual(FeatureRegistry.dispositions.count, 37, "the table and the registry disagree in size")
    }

    func test_everyFoldNamesSomethingThatActuallyExists() {
        let ids = Set(FeatureRegistry.rows.map(\.id))
        for (id, d) in FeatureRegistry.dispositions {
            guard case .folds(let parent) = d else { continue }
            XCTAssertTrue(ids.contains(parent) || FeatureRegistry.namedFoldTargets.contains(parent),
                          "\(id) folds into \(parent), which is nothing")
        }
    }

    /// A fold into a fold is a door that does not open: Speakers inside
    /// Meetings is fine, Speakers inside something that is itself hidden is
    /// the lock being broken one level down.
    func test_noFoldLandsInsideAnotherFold() {
        for (id, d) in FeatureRegistry.dispositions {
            guard case .folds(let parent) = d else { continue }
            guard !FeatureRegistry.namedFoldTargets.contains(parent) else { continue }
            if case .folds = FeatureRegistry.disposition(for: parent) {
                XCTFail("\(id) folds into \(parent), which is itself folded away")
            }
        }
    }

    /// The cluster call in the spec overrides three per-row answers in the
    /// older decision record. Pinned so a later session does not helpfully
    /// correct it back from the older document.
    func test_theAppAboutItselfClusterIsAllInLabs() {
        for id in ["reactor", "jax.hq", "jax.command", "cognition.map",
                   "feature.review", "self.upgrade"] {
            XCTAssertEqual(FeatureRegistry.disposition(for: id), .labs,
                           "\(id) left the Labs cluster")
        }
    }

    func test_settingsIsOnTheRailBecauseItIsAlwaysReachable() {
        XCTAssertEqual(FeatureRegistry.disposition(for: "settings"), .rail)
    }

    /// The lookup must be loud about a row nobody decided on, not plausible.
    func test_theTableIsTheOnlySourceAndItIsComplete() {
        for row in FeatureRegistry.rows {
            XCTAssertNotNil(FeatureRegistry.dispositions[row.id],
                            "\(row.id) would fall through to a guessed door")
        }
    }
}

/// The registry and the sidebar name the same surfaces differently, and a
/// door's contents are computed from the registry while a row opens a tab.
/// A missing mapping is a door that opens onto nothing, and `--open-tab`
/// falls through to chat SILENTLY, so nothing fails and the sweep reports
/// success on the wrong tab.
@MainActor
final class RegistryTabKeyTests: XCTestCase {

    func test_everyRowEitherOpensARealTabOrDeclaresItHasNone() {
        var broken: [String] = []
        for row in FeatureRegistry.rows {
            guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { continue }
            if SidebarIA.item(forKey: key) == nil { broken.append("\(row.id) -> \(key)") }
        }
        XCTAssertTrue(broken.isEmpty, "rows pointing at a tab that does not exist: \(broken)")
    }

    /// The thirteen rows whose names diverge are exactly the ones that need a
    /// mapping or an exemption. If that set changes, somebody renamed a row
    /// and this asks them to say which.
    func test_theDivergentNamesAreAllAccountedFor() {
        let keys = Set(SidebarIA.allItems.map(\.key))
        let divergent = FeatureRegistry.rows.map(\.id).filter { !keys.contains($0) }
        for id in divergent {
            let mapped = FeatureRegistry.idToTabKey[id] != nil
            let exempt = FeatureRegistry.rowsWithoutATab.contains(id)
            XCTAssertTrue(mapped || exempt,
                          "\(id) matches no tab key and is neither mapped nor declared tabless")
        }
        XCTAssertEqual(divergent.count, 11, "the divergent set changed; say what moved")  // domains left in C13, terminal.focus on 2026-09-27
    }

    /// A row declared tabless must genuinely have nowhere of its own to open,
    /// or the declaration is hiding a surface.
    func test_aRowDeclaredTablessHasNoTabHiding() {
        for id in FeatureRegistry.rowsWithoutATab {
            XCTAssertNil(SidebarIA.item(forKey: id),
                         "\(id) is declared tabless but has a tab")
        }
    }

    /// Nothing behind a door may be unreachable, which is the whole point of
    /// putting it behind a door rather than deleting it. A row opens a tab or
    /// it opens a window; what it may not do is open nothing.
    func test_everythingBehindADoorOpensSomething() {
        for disposition in [FeatureRow.Disposition.developer, .labs, .studio] {
            for row in SidebarIA.behind(disposition) {
                if let key = FeatureRegistry.tabKey(forRowId: row.id) {
                    XCTAssertNotNil(SidebarIA.item(forKey: key), "\(row.id) -> \(key)")
                } else {
                    XCTAssertNotNil(FeatureRegistry.rowsOpeningAWindow[row.id],
                                    "\(row.id) is behind a door, has no tab, and names no window")
                }
            }
        }
    }

    /// A row declared tabless must be reachable some OTHER way, or "tabless"
    /// is just a word for hidden.
    func test_aTablessRowIsStillReachableSomehow() {
        let foldsIntoSomething: Set<String> = Set(
            FeatureRegistry.dispositions.compactMap { id, d in
                if case .folds = d { return id }
                return nil
            })
        for id in FeatureRegistry.rowsWithoutATab {
            let ripped = FeatureRegistry.disposition(for: id) == .ripped
            let folded = foldsIntoSomething.contains(id)
            let window = FeatureRegistry.rowsOpeningAWindow[id] != nil
            XCTAssertTrue(ripped || folded || window,
                          "\(id) has no tab and no other route, which is the lock being broken")
        }
    }
}
