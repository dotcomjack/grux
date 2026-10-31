import XCTest
@testable import Grux

/// Every action that destroys something must ask first.
///
/// The audit that produced this found 33 destructive controls and only 7 files in
/// the entire app using a confirmation. `Reset all settings` wiped the whole
/// config on one click. `Clear memory` emptied semantic memory on one click.
/// `Remove` on a credential deleted a key that, for Anthropic, is shown exactly
/// once at creation and cannot be read back.
///
/// A source scan rather than a behaviour test, for the same reason the
/// Terminal-instruction guard is one: the failure is somebody adding the 34th
/// button, and nothing about the 33 fixed ones stops that.
///
/// ## Three shapes are acceptable
///
/// 1. `DestructiveButton`, which carries its own dialog.
/// 2. A button that DEFERS, setting a `pending`/`deleting`/`showConfirm` value
///    that a dialog on the parent view reads. This is the required shape inside a
///    `.contextMenu` or swipe action, because those dismiss when tapped and take
///    an attached dialog with them.
/// 3. A button INSIDE a `confirmationDialog` or `.alert` closure, which is the
///    confirmation itself.
///
/// ## And one is explicitly not a defect
///
/// Cheap, reversible actions that destroy no data. Clearing a search box or
/// deselecting a preset loses nothing. Putting a dialog on those is worse than
/// leaving them alone: it trains people to confirm without reading, which is
/// exactly what makes the real dialogs stop working.
final class DestructiveActionsGuardTests: XCTestCase {

    /// Verbs that suggest something is destroyed.
    private var destructiveVerbs: [String] { Self.destructiveVerbs }

    /// Labels that match a destructive verb but destroy NOTHING. Each is listed
    /// with what it actually does, so the list cannot quietly grow into a way of
    /// silencing real findings.
    static let harmless: Set<String> = [
        "Clear search",     // empties a text field
        "Clear Snooze",     // un-snoozes, restores notifications
        "Clear preset",     // deselects, the preset still exists
        "Clear active",     // deselects, the preset still exists
        "Reset to all",     // widens a filter back to everything
        "Reset",            // appearance and slider resets, no stored data
        "Restore defaults", // capture exclusion list back to shipped defaults
        "Clear filters",
        "Clear"
    ]

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        var out: [URL] = []
        let walker = FileManager.default.enumerator(at: sourcesDirectory,
                                                    includingPropertiesForKeys: nil)
        while let item = walker?.nextObject() as? URL {
            if item.pathExtension == "swift" { out.append(item) }
        }
        return out
    }

    /// The scan must reach the tree, or everything below passes by walking nothing.
    func testScanReachesTheSourceTree() throws {
        XCTAssertGreaterThan(try swiftFiles().count, 100,
                             "expected the Grux sources at \(sourcesDirectory.path)")
    }

    func testEveryDestructiveButtonAsksFirst() throws {
        var unguarded: [String] = []

        for file in try swiftFiles() {
            guard file.lastPathComponent != "DestructiveActionsGuardTests.swift",
                  file.lastPathComponent != "DestructiveButton.swift",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            let bound = Self.dialogBoundNames(SwiftSource.views(named: ["confirmationDialog", "alert"], in: text)
                .filter { $0.code.hasPrefix("confirmationDialog(") || $0.code.hasPrefix("alert(") })

            // Line ranges covered by a confirmation closure. A button in here IS
            // the confirmation.
            var guarded: [ClosedRange<Int>] = []
            for (i, line) in lines.enumerated() {
                guard line.contains("confirmationDialog(") || line.contains(".alert(") else { continue }
                let indent = line.prefix(while: { $0 == " " }).count
                var end = min(i + 60, lines.count - 1)
                for j in (i + 1)...min(i + 60, lines.count - 1) {
                    let t = lines[j]
                    if !t.trimmingCharacters(in: .whitespaces).isEmpty,
                       t.prefix(while: { $0 == " " }).count <= indent,
                       t.trimmingCharacters(in: .whitespaces).hasPrefix("}") { end = j; break }
                }
                guarded.append(i...end)
            }

            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                // `DestructiveButton("Delete"` and `DestructiveMenuButton("Delete"`
                // both contain the substring `Button("`, so a naive match flags
                // the very components that fix this. They ARE the guarded shape.
                if line.contains("DestructiveButton(") || line.contains("DestructiveMenuButton(") {
                    continue
                }
                guard line.contains("Button(\"") else { continue }
                guard let label = line.components(separatedBy: "\"").dropFirst().first else { continue }
                guard destructiveVerbs.contains(where: { label.contains($0) }) else { continue }
                if Self.harmless.contains(label) { continue }
                if guarded.contains(where: { $0.contains(i) }) { continue }

                // Deferring to a dialog on the parent is the correct shape inside
                // a context menu, so a button that only sets state is fine.
                // Only a value a dialog in this file presents from counts (wave 24: any
                // `showing... =` or `pending... =` assignment passed).
                let window = lines[i...min(i + 4, lines.count - 1)].joined(separator: "\n")
                if !Self.destroyingCall(window), Self.assignsADialogValue(window, bound) { continue }

                unguarded.append("\(file.lastPathComponent):\(i + 1) \"\(label)\": \(line.prefix(90))")
            }
        }

        XCTAssertTrue(unguarded.isEmpty,
                      "a destructive action fires with no confirmation. Use DestructiveButton, or "
                      + "set a pending value and put the dialog on the parent view (required inside "
                      + "a context menu, which dismisses and takes an attached dialog with it). If "
                      + "it genuinely destroys nothing, add its exact label to `harmless` with a "
                      + "note saying what it does.\n"
                      + unguarded.joined(separator: "\n"))
    }

    /// D99 (sense pass 8): the scan above reads a button by its TEXT label, so a button
    /// labelled with a trash icon or a `Label`, or one marked `role: .destructive`, walked
    /// past it. Calendar's trash deleted a real event on one click, Chat's wiped the whole
    /// conversation, Notes' deleted a note. Every such button now asks first: it raises
    /// `DestructiveConfirm.shared.ask`, defers to a dialog through a pending value, or is
    /// the confirmation itself.
    func testEveryTrashOrDestructiveRoleButtonAsksFirst() throws {
        var unguarded: [String] = []
        let files = try swiftFiles().filter {
            $0.lastPathComponent != "DestructiveActionsGuardTests.swift" && $0.lastPathComponent != "DestructiveButton.swift"
        }
        // Helpers are read wherever they are called, not only in the file declaring them.
        var helpers = Set<String>()
        for file in files { helpers.formUnion(Self.actionHelpers((try? String(contentsOf: file, encoding: .utf8)) ?? "")) }
        XCTAssertTrue(helpers.isSuperset(of: ["iconButton", "pill", "smallChip", "button", "stepButton", "chip", "chipButton",
                                              "FoundryStatusBadge", "ActivitySwarmBadge"]), "\(helpers.sorted())")
        XCTAssertFalse(helpers.contains("RoadmapRow"), "it asks inside itself")
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for line in Self.unguardedTrashButtons(text, helpers: helpers) {
                unguarded.append("\(file.lastPathComponent):\(line): \(lines[line - 1].trimmingCharacters(in: .whitespaces).prefix(90))")
            }
        }
        XCTAssertTrue(unguarded.isEmpty,
                      "a trash or destructive-role button acts with no confirmation. Raise "
                      + "DestructiveConfirm.shared.ask(question:detail:confirmLabel:) naming what is lost.\n"
                      + unguarded.joined(separator: "\n"))
    }

    /// The scan must see each shape it claims to read, and pass each guarded one, or it
    /// passes by matching nothing.
    func testTheTrashScanSeesEachShape() {
        func scan(_ lines: [String]) -> [Int] { Self.unguardedTrashButtons(lines.joined(separator: "\n")) }
        let bare = [
            "Button {", "    store.delete(id: x)", "} label: {", "    Image(systemName: \"trash\")", "}",
            "Button(role: .destructive) {", "    remove()", "} label: {", "    Label(\"Delete\", systemImage: \"trash\")", "}",
            "Button { state.clearChat() } label: {", "    Label(\"Clear\", systemImage: \"trash\")", "}",
        ]
        XCTAssertEqual(scan(bare), [1, 6, 11])
        let asked = [
            "Button {", "    DestructiveConfirm.shared.ask(question: \"Delete x?\", confirmLabel: \"Delete\") {",
            "        store.delete(id: x)", "    }", "} label: {", "    Image(systemName: \"trash\")", "}",
            "Button(role: .destructive) {", "    pendingDelete = item", "} label: {", "    Label(\"Delete\", systemImage: \"trash\")", "}",
            ".confirmationDialog(\"Delete it?\", isPresented: Binding(get: { pendingDelete != nil }, set: { _ in })) {",
            "    Button(\"Delete\", role: .destructive) { store.delete(id: pendingDelete!.id) }",
            "}",
        ]
        XCTAssertEqual(scan(asked), [])
        let inDialog = [
            ".confirmationDialog(\"Delete x?\", isPresented: $asking) {",
            "    Button(role: .destructive) { remove() } label: { Text(\"Delete\") }",
            "}",
        ]
        XCTAssertEqual(scan(inDialog), [])
        let stops = [
            "Button(role: .destructive) {", "    Task { await svc.cancel(jobId: id) }", "} label: {",
            "    Label(\"Cancel job\", systemImage: \"stop.circle\")", "}",
            "Button(role: .destructive) {", "    store.delete(id: item.id)", "} label: {", "    Text(\"Delete item\")", "}",
        ]
        XCTAssertEqual(scan(stops), [6], "a stop is not a deletion; a Text label still counts")
    }

    /// Wave 24 round 1: the shapes the line-window scan let through.
    func testTheTrashScanReadsWholeButtonsAndOnlyRealQuestions() {
        func scan(_ lines: [String]) -> [Int] { Self.unguardedTrashButtons(lines.joined(separator: "\n")) }
        // A long action: the icon sits 12 lines below the opening line.
        let long = ["Button {"] + (1...9).map { "    // step \($0)" } + ["    store.delete(id: x)", "} label: {", "    Image(systemName: \"trash\")", "}"]
        XCTAssertEqual(scan(long), [1])
        // A destructive-role button whose label sits past the opening line plus 8.
        let roleLong = ["Button(role: .destructive) {"] + (1...9).map { "    log(\($0))" } + ["    store.delete(id: x)", "} label: {", "    Text(\"Delete item\")", "}"]
        XCTAssertEqual(scan(roleLong), [1])
        // An ordinary assignment that no dialog presents from.
        XCTAssertEqual(scan(["Button { store.delete(id: x); showingEditor = false } label: { Image(systemName: \"trash\") }"]), [1])
        XCTAssertEqual(scan(["Button { pendingSave = x; store.delete(id: x) } label: { Image(systemName: \"trash\") }"]), [1])
        XCTAssertEqual(scan(["Button { if pendingDelete == nil { store.delete(id: x) } } label: { Image(systemName: \"trash\") }",
                             ".alert(\"Delete?\", isPresented: $pendingDelete) { }"]), [1], "a comparison asks nothing")
        XCTAssertEqual(scan(["Button { confirmDelete = false; store.delete(id: x) } label: { Image(systemName: \"trash\") }",
                             ".alert(\"Delete?\", isPresented: $confirmDelete) { }"]), [1], "closing the dialog asks nothing")
        XCTAssertEqual(scan(["Button { confirmDelete = true } label: { Image(systemName: \"trash\") }",
                             ".alert(\"Delete?\", isPresented: $confirmDelete) { }"]), [])
        // A destructive chip, an xmark with a Delete help, a role button with `action:`.
        XCTAssertEqual(scan(["GruxChip(title: \"DELETE\", style: .destructive) {", "    store.remove(skill.id)", "}"]), [1])
        XCTAssertEqual(scan(["Button { ambient.deleteMemory(memory.id) } label: {", "    Image(systemName: \"xmark.circle.fill\")",
                             "}.buttonStyle(.plain).help(\"Delete\")"]), [1])
        XCTAssertEqual(scan(["Button(role: .destructive, action: { store.delete(id: x) }) { Text(\"Delete\") }"]), [1])
        // Not a deletion: clearing a search field, an xmark that only closes.
        XCTAssertEqual(scan(["Button { query = \"\" } label: { Image(systemName: \"xmark.circle.fill\") }.help(\"Clear search\")"]), [])
        XCTAssertEqual(scan(["Button { dismiss() } label: { Image(systemName: \"xmark\") }.help(\"Close\")"]), [])
        // A context menu's items are their own buttons, not the words of the button they hang off.
        XCTAssertEqual(scan(["Button(action: open) { Text(\"Report\") }", ".buttonStyle(.plain)", ".contextMenu {",
                             "    DestructiveMenuButton(\"Delete\", question: \"Delete it?\", confirmLabel: \"Delete\") { store.delete(id: x) }",
                             "}", ".help(\"Open\")"]), [])
        XCTAssertEqual(scan(["Button(action: open) { Text(\"Report\") }", ".contextMenu {",
                             "    Button(\"Delete\") { store.delete(id: x) }", "}"]), [3], "the bare item inside is still read")
        // Wave 24 round 2: a helper called with a trash icon is read at its call site.
        let pill = ["private func pill(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {",
                    "    Button(action: action) { Image(systemName: icon) }", "}"]
        XCTAssertEqual(scan(pill + ["pill(icon: \"trash\", label: \"\", color: .red) {", "    engine.delete(b); onDismiss()", "}"]), [4])
        XCTAssertEqual(scan(pill + ["pill(icon: \"trash\", label: \"\", color: .red) {", "    confirmingDelete = true", "}",
                                    ".confirmationDialog(\"Delete it?\", isPresented: $confirmingDelete) { }"]), [])
        XCTAssertEqual(scan(pill + ["pill(icon: \"square.and.arrow.up\", label: \"Share\", color: .blue) { share() }"]), [])
        // A dialog skips only its own buttons, not those in a later modifier of its chain.
        XCTAssertEqual(scan(["List { rows }",
                             ".alert(\"Delete all?\", isPresented: $confirmAll) { Button(\"Delete all\", role: .destructive) { store.deleteAll() } }",
                             ".toolbar {",
                             "    Button { store.delete(id: sel) } label: { Image(systemName: \"trash\") }",
                             "}"]), [4])
        XCTAssertEqual(scan([".confirmationDialog(\"Delete?\", isPresented: $asking) { Button(\"Delete\", role: .destructive) { remove() } }",
                             ".contextMenu { Button(\"Delete\") { store.delete(id: x) } }"]), [2])
        // An error alert set after the deletion asked nothing.
        XCTAssertEqual(scan(["Button {", "    do { try store.delete(id: x) } catch { deleteError = error.localizedDescription }",
                             "} label: { Image(systemName: \"trash\") }",
                             ".alert(\"Could not delete\", isPresented: Binding(get: { deleteError != nil }, set: { _ in deleteError = nil })) { Button(\"OK\") { } }"]), [1])
        XCTAssertEqual(scan(["Button { store.delete(id: x); showError = true } label: { Image(systemName: \"trash\") }",
                             ".alert(\"Could not delete\", isPresented: $showError) { }"]), [1])
        // Wave 24 round 3: a helper is known by its declaration, so any call shape is read.
        let helpers = [
            "private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {",
            "    Button(action: action) { Image(systemName: systemName) }.help(help)", "}",
            "private func smallChip(_ text: String, systemImage: String, action: @escaping () -> Void) -> some View {",
            "    Button(action: action) { Label(text, systemImage: systemImage) }", "}",
            "struct PillButton: View {", "    let icon: String", "    let action: () -> Void",
            "    var body: some View { Button(action: action) { Image(systemName: icon) } }", "}",
        ]
        XCTAssertEqual(scan(helpers + ["iconButton(\"trash\", help: \"Delete event\") { try? CalendarService.shared.deleteEvent(id: ev.id) }"]), [12])
        XCTAssertEqual(scan(helpers + ["smallChip(\"Remove \\(entry.name)\", systemImage: \"trash\") { registry.remove(entry) }"]), [12])
        XCTAssertEqual(scan(helpers + ["smallChip(\"Remove project\", systemImage: \"minus.circle\") { registry.remove(entry) }"]), [12])
        XCTAssertEqual(scan(helpers + ["PillButton(icon: \"trash.fill\") { store.delete(id: x) }"]), [12])
        XCTAssertEqual(scan(helpers + ["iconButton(\"chevron.left\", help: \"Previous day\") { day -= 1 }"]), [])
        XCTAssertEqual(scan(helpers + ["iconButton(\"trash\", help: \"Delete event\") {",
                                       "    DestructiveConfirm.shared.ask(question: \"Delete it?\", confirmLabel: \"Delete\") { delete() }", "}"]), [])
        // Wave 24 round 4: a name another name prefixes is read; every Void closure type
        // makes a helper; a helper's body ends at its own brace, and a comment asks nothing.
        XCTAssertEqual(scan(["func chip(_ t: String, action: @escaping () -> Void) -> some View { Button(t, action: action) }",
                             "func chipButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {",
                             "    Button(action: action) { Label(label, systemImage: systemImage) }", "}",
                             "chipButton(label: \"Remove\", systemImage: \"trash\") { registry.remove(entry) }"]), [5])
        XCTAssertEqual(scan(["struct ButtonRow: View { let icon: String; let action: () -> Void; var body: some View { Button(action: action) { Image(systemName: icon) } } }",
                             "ButtonRow(icon: \"trash\") { store.delete(id: x) }"]), [2])
        for type in ["(() -> Void)? = nil", "@MainActor @escaping () -> Void", "@escaping @Sendable () -> Void", "@escaping () async -> Void",
                     "@escaping (Item) -> Void", "Action"] {
            XCTAssertEqual(scan(["typealias Action = () -> Void",
                                 "struct Pill: View, Equatable { let icon: String; var action: \(type); var body: some View { Button { } label: { Image(systemName: icon) } } }",
                                 "Pill(icon: \"trash\") { store.delete(id: $0.id) }"]), [3], type)
            XCTAssertEqual(scan(["typealias Action = () -> Void",
                                 "private func row(_ icon: String, action: \(type)) -> some View { Button { } label: { Image(systemName: icon) } }",
                                 "row(\"trash\") { store.delete(id: $0.id) }"]), [3], type)
        }
        XCTAssertEqual(scan(["private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {",
                             "    // Callers that delete wrap the action in DestructiveConfirm.shared.ask(...).",
                             "    Button(action: action) { Image(systemName: systemName) }", "}",
                             "private var list: some View { List { rows }.confirmationDialog(\"Delete all?\", isPresented: $confirmAll) { } }",
                             "@ViewBuilder private func other() -> some View { EmptyView() }",
                             "iconButton(\"trash\") { store.delete(id: x) }"]), [7])
        // A declaration with a trash default is not a call; an interpolated trash symbol is a trash icon.
        XCTAssertEqual(scan(["func pill(icon: String = \"trash\", action: @escaping () -> Void) -> some View { Button(action: action) { Image(systemName: icon) } }"]), [])
        XCTAssertEqual(scan(["Button { store.delete(id: x) } label: { Image(systemName: \"trash\\(filled ? \".fill\" : \"\")\") }"]), [1])
        // A ternary trash icon is a trash icon.
        XCTAssertEqual(scan(["Button { editing ? store.delete(id: x) : edit() } label: { Image(systemName: editing ? \"trash\" : \"pencil\") }"]), [1])
        // A helper that asks inside itself is not read as one that does not.
        XCTAssertEqual(scan(["func deleteButton(_ title: String, action: @escaping () -> Void) -> some View {",
                             "    Button(title) { DestructiveConfirm.shared.ask(question: \"Delete?\", confirmLabel: \"Delete\", action: action) }", "}",
                             "deleteButton(\"Delete\") { store.delete(id: x) }"]), [])
        // A comment holding a trash icon is not a button.
        XCTAssertEqual(scan(["// Button { store.delete(id: x) } label: { Image(systemName: \"trash\") }"]), [])
    }

    /// Wave 24 round 1 P1: the Settings window (Cmd-comma) hosted no dialog, so the
    /// endpoint and MCP server asks showed nowhere there. A request goes to the window
    /// it was asked from when that window hosts, and only that window shows it.
    func testARequestGoesToTheWindowItWasAskedFrom() {
        final class W {}
        let main = ObjectIdentifier(W.self), settings = ObjectIdentifier(Int.self), panel = ObjectIdentifier(String.self)
        XCTAssertEqual(DestructiveConfirm.target(key: settings, main: main, hosts: [main, settings]), settings)
        XCTAssertEqual(DestructiveConfirm.target(key: main, main: main, hosts: [main, settings]), main)
        // A key window that hosts nothing (a popover, a floating panel): the main window.
        XCTAssertEqual(DestructiveConfirm.target(key: panel, main: settings, hosts: [main, settings]), settings)
        // Neither hosts: the first host. Nothing hosts: any host that comes up.
        XCTAssertEqual(DestructiveConfirm.target(key: panel, main: nil, hosts: [main, settings]), main)
        XCTAssertNil(DestructiveConfirm.target(key: panel, main: main, hosts: []))
        let toSettings = DestructiveConfirm.Request(question: "Remove?", detail: nil, confirmLabel: "Remove", action: {}, window: settings)
        XCTAssertTrue(DestructiveConfirm.shows(toSettings, in: settings))
        XCTAssertFalse(DestructiveConfirm.shows(toSettings, in: main), "one dialog, not one per window")
        XCTAssertFalse(DestructiveConfirm.shows(toSettings, in: nil))
        let anywhere = DestructiveConfirm.Request(question: "Remove?", detail: nil, confirmLabel: "Remove", action: {})
        XCTAssertTrue(DestructiveConfirm.shows(anywhere, in: main))
        XCTAssertFalse(DestructiveConfirm.shows(nil, in: main))
    }

    /// Hosts register per host, so one leaving a window another still hosts keeps the
    /// window; a window that is not on screen is never a target (wave 24 round 2). No
    /// window is shown here: a test must not draw on the Mac's screen.
    @MainActor
    func testHostsAreKeptPerHostAndOnlyVisibleWindowsAreTargets() {
        let confirm = DestructiveConfirm.shared
        let a = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        a.isReleasedWhenClosed = false
        let one = UUID(), two = UUID()
        defer { confirm.unregister(one); confirm.unregister(two); confirm.pending = nil }
        confirm.register(one, in: a)
        confirm.register(two, in: a)
        confirm.unregister(one)
        XCTAssertFalse(a.isVisible)
        XCTAssertEqual(confirm.visibleHostWindows, [], "a window off screen is not a target")
        confirm.ask(question: "Delete?", confirmLabel: "Delete") {}
        XCTAssertNil(confirm.pending?.window, "with nothing on screen hosting, the first host to come up shows it")
        // The second host still holds the window: unregistering it is what drops it.
        XCTAssertTrue(confirm.hostTokens.contains(two))
        confirm.unregister(two)
        XCTAssertFalse(confirm.hostTokens.contains(two))
    }

    /// Every scene and window root the app builds hosts the dialog, so a delete asks in
    /// the window it was clicked in (wave 24: the Settings window had none).
    func testEveryWindowRootHostsTheDialog() throws {
        let app = try String(contentsOf: sourcesDirectory.appendingPathComponent("Grux/GruxApp.swift"), encoding: .utf8)
        let lines = app.components(separatedBy: .newlines)
        var roots: [String] = []
        for (i, line) in lines.enumerated() {
            if line.contains("NSHostingController(rootView:") { roots.append(line) }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("MenuBarExtra {") || (t.hasPrefix("Window(") || t.hasPrefix("WindowGroup(")) && t.contains("{"), i + 1 < lines.count {
                roots.append(lines[i + 1])
            }
        }
        XCTAssertGreaterThanOrEqual(roots.count, 8, roots.joined(separator: "\n"))
        for root in roots where !root.contains("ShellRootView(") {
            XCTAssertTrue(root.contains(".destructiveConfirmHost()"), root)
        }
        for file in ["Grux/LaunchRootView.swift", "Grux/Shell/CommandPanelRoot.swift"] {
            let text = try String(contentsOf: sourcesDirectory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(".destructiveConfirmHost()"), file)
        }
    }

    @MainActor
    func testAQuestionNamesTheThingInQuotesCutAtSixty() {
        XCTAssertEqual(DestructiveConfirm.quoted("Dentist", or: "this event"), "\"Dentist\"")
        XCTAssertEqual(DestructiveConfirm.quoted("  \n ", or: "this event"), "this event")
        XCTAssertEqual(DestructiveConfirm.quoted("", or: "with no title"), "with no title")
        let sixty = String(repeating: "a", count: 60)
        XCTAssertEqual(DestructiveConfirm.quoted(sixty, or: "x"), "\"" + sixty + "\"")
        XCTAssertEqual(DestructiveConfirm.quoted(sixty + "b", or: "x"), "\"" + String(repeating: "a", count: 57) + "...\"")
    }

    /// Lines (1-based) where a button that destroys something acts without asking first.
    /// A button destroys when it shows a trash icon; when it is marked destructive (a
    /// `role: .destructive` button or a `.destructive` chip) and its words name a
    /// destroying verb; or when its words (title, label, `.help`) name one and its action
    /// calls a destroying function (Compare's and Ambient's xmark buttons, wave 24). Each
    /// button is read whole by `SwiftSource.views`, so a long action never hides its icon.
    static let destructiveVerbs = ["Delete", "Reset", "Remove", "Clear", "Wipe", "Erase", "Restore",
                                   "Revoke", "Disconnect", "Forget", "Purge", "Unpair", "Rotate"]

    static func unguardedTrashButtons(_ source: String, helpers: Set<String> = []) -> [Int] {
        let dialogs = SwiftSource.views(named: ["confirmationDialog", "alert"], in: source)
            .filter { $0.code.hasPrefix("confirmationDialog(") || $0.code.hasPrefix("alert(") }
        let bound = dialogBoundNames(dialogs)
        let names = Set(["Button", "GruxChip"]).union(helpers.isEmpty ? actionHelpers(source) : helpers)
        var out: [Int] = []
        for view in SwiftSource.views(named: names.sorted(), in: source) {
            // The confirmation's own buttons are the question being answered; a button in
            // a modifier further down the dialog's chain is not (wave 24).
            if dialogs.contains(where: { $0.ownSpan.contains(view.span.lowerBound) }) { continue }
            let code = view.code
            // An SF Symbol trash icon in any argument, labelled or not, or in a ternary.
            let trash = view.literals.contains { $0.text.range(of: #"^trash(\.[a-z.]+)?(\s|$)"#, options: .regularExpression) != nil }
            let marked = code.range(of: #"(role|style)\s*:\s*\.destructive\b"#, options: .regularExpression) != nil
            let named = view.literals.contains { lit in
                guard !harmless.contains(lit.text),
                      let first = SwiftSource.letterWords(lit.text).first else { return false }
                return destructiveVerbs.contains { $0.lowercased() == first }
            }
            let destroys = destroyingCall(code)
            guard trash || (named && (marked || destroys)) else { continue }
            if code.contains("DestructiveConfirm.shared.ask(") { continue }
            // Deferring means the button only raises the question: one that destroys in
            // its own action and then sets an error alert asked nothing (wave 24).
            if !destroys && assignsADialogValue(code, bound) { continue }
            out.append(view.line)
        }
        return out
    }

    /// Views that take an action and draw a button for it: a `func` returning `some View`
    /// or `AnyView` with a parameter of a closure type returning Void (`() -> Void`,
    /// `(() -> Void)?`, `@MainActor @escaping () -> Void`, `(Item) -> Void`, `() async ->
    /// Void`, or a typealias of one), or a struct conforming to `View` that holds one before
    /// its `body`. Their calls are read like `Button`, whatever the arguments look like (wave
    /// 24 rounds 3 and 4). A helper whose own body, cut at its own closing brace with
    /// comments and strings left out, asks (`DestructiveConfirm.shared.ask(` or
    /// `confirmationDialog(`) is left out, as `DestructiveButton` is.
    static func actionHelpers(_ source: String) -> Set<String> {
        let code = SwiftSource.plainCode(source)
        let ns = code as NSString
        let all = NSRange(location: 0, length: ns.length)
        var voidClosure = #"->\s*(?:Void|\(\s*\))"#
        let aliases = try! NSRegularExpression(pattern: #"typealias\s+([A-Za-z_]\w*)\s*=[^\n]*->\s*(?:Void|\(\s*\))"#)
        let aliasNames = aliases.matches(in: code, range: all).map { ns.substring(with: $0.range(at: 1)) }
        if !aliasNames.isEmpty { voidClosure = "(?:" + voidClosure + #"|:\s*(?:@\w+\s+)*\(?(?:"# + aliasNames.joined(separator: "|") + #")\b)"# }
        /// The text from the first `{` at or after `from` to its own closing brace.
        func body(from: Int) -> String {
            let open = ns.range(of: "{", options: [], range: NSRange(location: from, length: ns.length - from))
            guard open.location != NSNotFound else { return "" }
            var depth = 0, k = open.location
            while k < ns.length {
                let c = ns.character(at: k)
                if c == 0x7B { depth += 1 }
                if c == 0x7D { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            return ns.substring(with: NSRange(location: open.location, length: min(k + 1, ns.length) - open.location))
        }
        func asks(_ text: String) -> Bool {
            text.contains("DestructiveConfirm.shared.ask(") || text.contains("confirmationDialog(")
        }
        var names = Set<String>()
        let funcs = try! NSRegularExpression(pattern: #"func\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)\s*(?:async\s*)?(?:throws\s*)?->\s*(?:some\s+View|AnyView)\b"#)
        for m in funcs.matches(in: code, range: all) {
            let params = ns.substring(with: m.range(at: 2))
            guard params.range(of: voidClosure, options: .regularExpression) != nil,
                  !asks(body(from: m.range.location + m.range.length)) else { continue }
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        let structs = try! NSRegularExpression(pattern: #"struct\s+([A-Za-z_]\w*)\s*(?:<[^>{]*>)?\s*:[^{]*\bView\b[^{]*\{"#)
        for m in structs.matches(in: code, range: all) {
            let whole = body(from: m.range.location + m.range.length - 1)
            let head = whole.range(of: "var body").map { String(whole[..<$0.lowerBound]) } ?? whole
            guard head.range(of: voidClosure, options: .regularExpression) != nil, !asks(whole) else { continue }
            names.insert(ns.substring(with: m.range(at: 1)))
        }
        return names.subtracting(["DestructiveButton", "DestructiveMenuButton"])
    }

    /// A call that destroys: `store.delete(`, `ambient.deleteMemory(`, `remove(at:`.
    static func destroyingCall(_ code: String) -> Bool {
        code.range(of: #"\b(delete|remove|clear|wipe|erase|purge|forget|reset|revoke|disconnect|unpair)\w*\s*\("#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Names a dialog in the file presents from: `isPresented: $x`, `item: $x`,
    /// `presenting: x`, or a Binding whose getter reads `x != nil` or `x`.
    static func dialogBoundNames(_ dialogs: [SwiftSource.View]) -> Set<String> {
        var names = Set<String>()
        let patterns = [#"(?:isPresented|item)\s*:\s*\$(?:self\.)?([A-Za-z_]\w*)"#,
                        #"presenting\s*:\s*(?:self\.)?([A-Za-z_]\w*)"#,
                        #"get\s*:\s*\{\s*(?:self\.)?([A-Za-z_]\w*)\s*(?:!=\s*nil)?\s*\}"#]
        for dialog in dialogs {
            for pattern in patterns {
                let re = try! NSRegularExpression(pattern: pattern)
                let ns = dialog.code as NSString
                for m in re.matches(in: dialog.code, range: NSRange(location: 0, length: ns.length)) {
                    names.insert(ns.substring(with: m.range(at: 1)))
                }
            }
        }
        return names
    }

    /// The button sets a value a dialog presents from, to something other than nil or
    /// false: the deferred shape (the dialog hangs off the parent and asks). Any other
    /// assignment (`showingEditor = false`, `pendingSave = x` with no dialog on it) asks
    /// nothing (wave 24).
    static func assignsADialogValue(_ code: String, _ bound: Set<String>) -> Bool {
        bound.contains { name in
            let pattern = #"(?<![\w.])(?:self\.)?"# + NSRegularExpression.escapedPattern(for: name)
                + #"\s*=(?!=)\s*(?!nil\b|false\b)\S"#
            return code.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// A dialog that says "Are you sure?" and nothing else is a speed bump, not a
    /// question: it tells the reader nothing they did not know and trains them to
    /// confirm without reading, which is what stops the real ones working.
    func testConfirmationsNameWhatIsLost() throws {
        var vague: [String] = []
        for file in try swiftFiles() {
            guard file.lastPathComponent != "DestructiveActionsGuardTests.swift",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                for weak in ["Are you sure", "are you sure"] where line.contains(weak) {
                    vague.append("\(file.lastPathComponent):\(i + 1): \(line.prefix(80))")
                }
            }
        }
        XCTAssertTrue(vague.isEmpty,
                      "name what is lost instead.\n" + vague.joined(separator: "\n"))
    }
}
