import XCTest
@testable import Grux

/// EVERY SURFACE IS REACHABLE FROM THE UI, not just from a trigger file.
///
/// `RegistryReachabilityTests` asserts every row records a door. That is not
/// the same claim as the door being RENDERED, and the gap between them is
/// exactly what shipped when the computed rail first landed: six surfaces had
/// a recorded disposition of "folds into <parent>", their rows were gone from
/// the rail, and no parent hosted them yet. They were reachable only by firing
/// `~/.grux/fire-open-tab` by hand, which is not a door, it is a debug hatch.
///
/// This is the test that catches a fold in progress.
@MainActor
final class RailReachabilityTests: XCTestCase {

    /// Everything a person can reach without typing a trigger file.
    private func reachableKeys(dev: Bool, brands: [String]) -> Set<String> {
        var keys: Set<String> = []
        for row in SidebarIA.rail(developerUnlocked: dev, brands: brands) {
            switch row.kind {
            case .surface(let key):
                keys.insert(key)
            case .door(let id):
                let d: FeatureRow.Disposition = id == "developer" ? .developer : .labs
                for r in SidebarIA.behind(d) {
                    if let k = FeatureRegistry.tabKey(forRowId: r.id) { keys.insert(k) }
                }
                if d == .labs { keys.formUnion(SidebarIA.labsOnlyKeys) }
            }
        }
        // A surface hosted inside a rail row is reached through that row's
        // switch, so it is reachable exactly when its host is.
        for (child, host) in LaunchRootView.hostedBy
        where keys.contains(LaunchRootView.tabKey(for: host)) {
            keys.insert(LaunchRootView.tabKey(for: child))
        }
        return keys
    }

    func test_everyRegistryRowIsReachableWithoutATriggerFile() {
        let reachable = reachableKeys(dev: true, brands: ["A Brand"])
        var unreachable: [String] = []
        for row in FeatureRegistry.rows {
            if row.disposition == .ripped { continue }
            // A row that folds into a parent is reachable through the parent
            // ONCE THAT FOLD HAS LANDED. Until then it must keep its own row.
            let pending = SidebarIA.awaitingTheirNewHome.contains { $0.key == row.id }
            if case .folds(let parent) = row.disposition {
                if !pending { continue }
                XCTAssertTrue(reachable.contains(row.id),
                              "\(row.id) folds into \(parent), the fold has not landed, and its row is gone")
                continue
            }
            guard let key = FeatureRegistry.tabKey(forRowId: row.id) else { continue }
            if !reachable.contains(key) { unreachable.append("\(row.id) -> \(key)") }
        }
        XCTAssertTrue(unreachable.isEmpty,
                      "surfaces reachable only by trigger file: \(unreachable)")
    }

    /// The list is scaffolding and must say so by shrinking. Every entry has
    /// to name a row that genuinely folds, or it is propping up a row that
    /// should simply be in the rail.
    func test_everyPendingMoveNamesARowThatIsActuallyMoving() {
        for entry in SidebarIA.awaitingTheirNewHome {
            let d = FeatureRegistry.disposition(for: entry.key)
            var moving = d == .studio
            if case .folds = d { moving = true }
            guard moving else {
                return XCTFail("\(entry.key) is propped up but its door is \(d), so it is not moving anywhere")
            }
            XCTAssertNotNil(SidebarIA.item(forKey: entry.key),
                            "\(entry.key) is kept in the rail but opens nothing")
        }
    }

    /// LANDED FOLDS. Each entry is a fold whose parent now hosts the child,
    /// so the child's prop is gone from the rail. The route is asserted, not
    /// assumed: a fold that loses its host is a surface that quietly vanishes,
    /// and the rail no longer carries a row to notice its absence by.
    func test_everyLandedFoldIsHostedByItsParent() throws {
        let landed: [(id: String, file: String, marker: String)] = [
            ("folders", "SettingsView.swift", "FoldersManagementView()"),
            // Projects is the second segment of Tasks, and the projects tab
            // renders in the same switch clause as Tasks.
            ("projects", "LaunchRootView.swift", "HostedSurface(.projects, \"Projects\")"),
            ("projects", "Shell/SurfacePane.swift", "case .tasks, .projects:"),
            // Media Studio and Research are segments of Studio, and their tabs
            // render in the same switch clause as Design Studio.
            ("creative", "LaunchRootView.swift", "HostedSurface(.creative, \"Media Studio\")"),
            ("research", "LaunchRootView.swift", "HostedSurface(.research, \"Research\")"),
            ("creative", "Shell/SurfacePane.swift", "case .designStudio, .creative, .research:"),
            ("research", "Shell/SurfacePane.swift", "case .designStudio, .creative, .research:"),
            // Skills is a picker in the Chat composer: a chip beside the model
            // chip opens the whole surface above the draft, and the skills tab
            // is Chat with it open.
            ("skills", "ChatView.swift", "modelChip\n            skillsChip"),
            ("skills", "ChatView.swift", "SkillsView(onUse:"),
            ("skills", "Shell/SurfacePane.swift", "case .chat, .skills: ChatView(opensSkills: selection == .skills)"),
            // Speakers and Workflows are segments of Meetings and Schedules,
            // on the same hosting mechanism as every other fold.
            ("speakers", "LaunchRootView.swift", "HostedSurface(.speakers, \"Speakers\")"),
            ("speakers", "Shell/SurfacePane.swift", "case .meetings, .speakers:"),
            ("workflows", "LaunchRootView.swift", "HostedSurface(.workflows, \"Workflows\")"),
            ("workflows", "Shell/SurfacePane.swift", "case .schedules, .workflows:"),
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        for f in landed {
            XCTAssertFalse(SidebarIA.awaitingTheirNewHome.contains { $0.key == f.id },
                           "\(f.id) has landed but is still propped in the rail")
            let text = try String(contentsOf: root.appendingPathComponent(f.file), encoding: .utf8)
            XCTAssertGreaterThan(text.count, 200, "\(f.file) did not load")
            XCTAssertTrue(text.contains(f.marker),
                          "\(f.id) folded into \(f.file) and its host is gone: \(f.marker)")
            // And the locked key still resolves, so nothing that scripts it breaks.
            XCTAssertNotNil(SidebarIA.item(forKey: f.id), "\(f.id) lost its tab key")
        }
    }

    /// THE KEY STILL OPENS THE CHILD, NOW INSIDE ITS PARENT.
    ///
    /// `--open-tab` falls back to chat on an unknown key without a word, so a
    /// fold that dropped a key would send every script to Chat and report
    /// success. Each folded key must map to its own Tab, that Tab must be
    /// hosted by the parent's Tab, and the parent's switch must list it, or a
    /// person arriving by key would land on a surface with no visible way back.
    func test_everyLandedKeyOpensItsParentAtTheChild() throws {
        let opens: [(key: String, parent: String)] = [
            ("projects", "tasks"),
            ("creative", "designStudio"),
            ("research", "designStudio"),
            ("skills", "chat"),
            ("speakers", "meetings"),
            ("workflows", "schedules"),
        ]
        for o in opens {
            let tab = try XCTUnwrap(LaunchRootView.tab(forKey: o.key),
                                    "\(o.key) no longer maps to a tab, so --open-tab falls through to chat")
            XCTAssertEqual(LaunchRootView.tabKey(for: tab), o.key,
                           "\(o.key) opens some other surface")
            let host = LaunchRootView.host(of: tab)
            XCTAssertEqual(LaunchRootView.tabKey(for: host), o.parent,
                           "\(o.key) is not hosted by \(o.parent)")
            XCTAssertNotNil(SidebarIA.rail(developerUnlocked: false, brands: []).first {
                $0.kind == .surface(key: o.parent)
            }, "\(o.key) lives inside \(o.parent), which has no rail row")
        }
        XCTAssertTrue(LaunchRootView.tasksSurfaces.map(\.tab).contains(.projects),
                      "Tasks no longer offers Projects in its switch")
        XCTAssertEqual(LaunchRootView.studioSurfaces.map(\.tab), [.designStudio, .creative, .research],
                       "Studio no longer offers all three of its surfaces, Design Studio first")
    }

    /// Three folds land inside surfaces that were never rail rows of their
    /// own. They need no propping, but "needs no propping" is not the same
    /// claim as "reachable", and the first version of this test only made the
    /// weaker one. Each route is named and asserted, so removing the host
    /// fails here rather than silently orphaning the surface.
    ///
    /// Routes as measured 2026-09-20:
    ///   integrations.webhooks  ->  WebhooksView() inside IntegrationsView
    ///                              (this fold has ALREADY LANDED)
    ///   mailbox.compose        ->  the Compose chip in Mail's toolbar, which
    ///                              opens ComposeEmailSheet() (this fold has
    ///                              ALREADY LANDED; P-C-3a corrected the route,
    ///                              which named the menu bar Compose, and that
    ///                              one is Outreach's cold email composer).
    ///                              Its own credential is asserted by the second
    ///                              marker: without the sending key the sheet
    ///                              shows the setup card, not a form.
    ///   approvals              ->  the tray at the foot of the rail on every
    ///                              tab (C10), and still inside JaxHQView
    func test_everyTablessFoldIsActuallyReachableByASpecificRoute() throws {
        let routes: [(id: String, file: String, marker: String)] = [
            ("integrations.webhooks", "Integrations/IntegrationsView.swift", "WebhooksView()"),
            ("mailbox.compose", "Email/Imap/MailboxView.swift", "ComposeEmailSheet()"),
            ("mailbox.compose", "Email/Imap/MailboxView.swift",
             "CapabilitySetupCard(featureKey: ComposeDoor.featureId)"),
            ("approvals", "Jax/JaxHQView.swift", "ApprovalQueue.shared"),
            ("approvals", "LaunchRootView.swift", "ApprovalsTrayButton()"),
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        for route in routes {
            XCTAssertFalse(SidebarIA.awaitingTheirNewHome.contains { $0.key == route.id },
                           "\(route.id) never had a rail row, so it needs no propping")
            XCTAssertNil(FeatureRegistry.tabKey(forRowId: route.id),
                         "\(route.id) is declared tabless; if it grew a tab, say so")
            let text = try String(contentsOf: root.appendingPathComponent(route.file), encoding: .utf8)
            XCTAssertGreaterThan(text.count, 200, "\(route.file) did not load")
            XCTAssertTrue(text.contains(route.marker),
                          "\(route.id) lost its only route: \(route.marker) is gone from \(route.file)")
        }
    }

    /// When the last fold lands this list empties and the block that renders
    /// it disappears. Until then, first run is fourteen rows PLUS the props.
    func test_theFirstRunCountAccountsForTheProps() {
        let rail = SidebarIA.rail(developerUnlocked: false, brands: [])
        XCTAssertEqual(rail.count, 14, "rail: \(rail.map(\.label))")
        // C11 moved the last prop (the Focus log, into Today). A row coming
        // back to this list is a surface that lost its home.
        XCTAssertTrue(SidebarIA.awaitingTheirNewHome.isEmpty,
                      "a folded surface is back on the rail as a prop")
    }
}
