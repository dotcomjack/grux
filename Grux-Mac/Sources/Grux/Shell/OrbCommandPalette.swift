import AppKit
import SwiftUI
import Carbon

// MARK: - Orb command palette
//
// Spotlight-style floating panel summoned by a global hotkey (default
// Cmd+Shift+P, overridable via UserDefaults, see PaletteHotkeyConfig).
// Fuzzy-filters a flat action list and executes through existing seams:
// AppDelegate.openLaunchWindow(tab:) for navigation, MicController for the
// mic, AppState.newThread() for chat, CommandV2Engine.start() for workflow
// definitions. No new state stores; the action list is rebuilt fresh on
// every open so it always reflects live app state.
//
// Window pattern follows FocusOverlayController / StageController: a
// non-activating borderless NSPanel that can become key (so the text field
// types) without stealing main-window identity.

// MARK: Fuzzy matcher (pure, testable)

enum PaletteFuzzy {
    /// Subsequence scorer. Returns nil when `query` is not a subsequence of
    /// `candidate` (case-insensitive). Higher scores for consecutive runs
    /// and word-start hits, mild penalty for long candidates, so
    /// "open chat" style prefixes beat scattered matches.
    static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        guard !c.isEmpty else { return nil }

        var score = 0
        var qi = 0
        var streak = 0
        for (i, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                qi += 1
                streak += 1
                score += 1 + streak * 2
                if i == 0 || c[i - 1] == " " { score += 8 }
            } else {
                streak = 0
            }
        }
        guard qi == q.count else { return nil }
        score -= max(0, c.count - q.count) / 4
        return score
    }

    /// Rank `actions` against `query`. Empty query returns the list as-is.
    static func rank(_ actions: [PaletteAction], query: String) -> [PaletteAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }
        return actions
            .compactMap { action -> (PaletteAction, Int)? in
                let title = score(query: trimmed, candidate: action.title)
                let subtitle = score(query: trimmed, candidate: action.subtitle)
                // Title hits dominate; subtitle-only hits still surface, just
                // ranked below any title hit.
                if let t = title { return (action, t + 1000) }
                if let s = subtitle { return (action, s) }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

// MARK: Action model

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let run: @MainActor () -> Void
}

// MARK: Action provider

@MainActor
enum PaletteActionProvider {
    // Tab destinations come from SidebarIA (DesignSystem/SidebarModel.swift),
    // the single source of truth shared with LaunchRootView's sidebar, so
    // the palette and sidebar never disagree on destinations. Keys are the
    // exact applyTab strings the --open-tab automation uses.

    static func actions() -> [PaletteAction] {
        var out: [PaletteAction] = []

        // New chat first: the single most common palette intent.
        out.append(PaletteAction(
            id: "new-chat",
            title: "New chat",
            subtitle: "Start a fresh thread",
            systemImage: "plus.bubble.fill"
        ) {
            _ = AppState.shared.newThread()
            AppDelegate.shared?.openLaunchWindow(tab: "chat")
        })

        // Mic, contextual on current mute state.
        if AppState.shared.micMuted {
            out.append(PaletteAction(
                id: "mic-start",
                title: "Start listening",
                subtitle: "Unmute the mic",
                systemImage: "mic.fill"
            ) {
                MicController.unmute()
            })
        } else {
            out.append(PaletteAction(
                id: "mic-stop",
                title: "Stop listening",
                subtitle: "Mute the mic",
                systemImage: "mic.slash.fill"
            ) {
                MicController.mute()
            })
        }

        out.append(PaletteAction(
            id: "focus-overlay-toggle",
            title: FocusOverlayController.shared.isShowing ? "Hide focus overlay" : "Show focus overlay",
            subtitle: "Floating focus card",
            systemImage: "eye"
        ) {
            FocusOverlayController.shared.toggle()
        })

        // Recent tabs. Most-recent-first, recorded by LaunchRootView on
        // every selection change. Distinct ids ("recent-...") so the same
        // tab can also appear in the full list below without colliding.
        for key in SidebarStateStore.shared.recents {
            guard let item = SidebarIA.item(forKey: key) else { continue }
            out.append(PaletteAction(
                id: "recent-\(item.key)",
                title: "Open \(item.label)",
                subtitle: "Recent tab",
                systemImage: item.icon
            ) {
                AppDelegate.shared?.openLaunchWindow(tab: item.key)
            })
        }

        // Tabs, every destination in sidebar order.
        for item in SidebarIA.allItems {
            out.append(PaletteAction(
                id: "tab-\(item.key)",
                title: "Open \(item.label)",
                subtitle: "Go to tab",
                systemImage: item.icon
            ) {
                AppDelegate.shared?.openLaunchWindow(tab: item.key)
            })
        }

        // Workflow definitions. Parameterless ones run directly; ones that
        // need params route to the Workflows tab where the existing UI
        // collects them.
        for def in CommandV2Engine.shared.definitions {
            if def.parameters.isEmpty {
                out.append(PaletteAction(
                    id: "workflow-run-\(def.id)",
                    title: "Run workflow: \(def.displayName)",
                    subtitle: def.description,
                    systemImage: "play.circle.fill"
                ) {
                    Task { _ = await CommandV2Engine.shared.start(definitionId: def.id) }
                })
            } else {
                out.append(PaletteAction(
                    id: "workflow-open-\(def.id)",
                    title: "Workflow: \(def.displayName)",
                    subtitle: "Needs parameters, opens Workflows",
                    systemImage: "flowchart"
                ) {
                    AppDelegate.shared?.openLaunchWindow(tab: "workflows")
                })
            }
        }

        return out
    }
}

// MARK: Hotkey config

enum PaletteHotkeyConfig {
    static let keyCodeDefaultsKey = "grux.palette.hotkey.keyCode"
    static let modifiersDefaultsKey = "grux.palette.hotkey.modifiers"

    // Cmd+Shift+P. Carbon: cmdKey = 256, shiftKey = 512; P = keyCode 35.
    static let defaultKeyCode: UInt32 = 35
    static let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    static var keyCode: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: keyCodeDefaultsKey)
        return stored > 0 ? UInt32(stored) : defaultKeyCode
    }

    static var modifiers: UInt32 {
        let stored = UserDefaults.standard.integer(forKey: modifiersDefaultsKey)
        return stored > 0 ? UInt32(stored) : defaultModifiers
    }
}

// MARK: Dedicated Carbon hotkey
//
// GlobalHotkey.shared owns exactly one registration slot (Terminal Focus).
// The palette takes its own Carbon registration under a distinct signature
// and id so the two never clobber each other.

@MainActor
private final class PaletteCarbonHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerInstalled = false
    private let signature: OSType = {
        // "GRXP"
        var result: OSType = 0
        for byte in Array("GRXP".utf8) {
            result = (result << 8) | OSType(byte)
        }
        return result
    }()

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        unregister()
        self.handler = handler
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: signature, id: 2)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status != noErr {
            print("PaletteCarbonHotkey: register failed status=\(status)")
            return
        }
        hotKeyRef = newRef
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID(signature: 0, id: 0)
            let getStatus = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard getStatus == noErr else { return OSStatus(eventNotHandledErr) }
            let instance = Unmanaged<PaletteCarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
            // Only fire for the palette's own signature so GlobalHotkey's
            // GRUX registration and this one stay independent.
            guard hkID.signature == instance.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                instance.handler?()
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            nil
        )
        if status != noErr {
            print("PaletteCarbonHotkey: InstallEventHandler failed status=\(status)")
            return
        }
        eventHandlerInstalled = true
    }
}

// MARK: Panel controller

@MainActor
final class OrbCommandPaletteController {
    static let shared = OrbCommandPaletteController()

    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private let hotkey = PaletteCarbonHotkey()
    private var resignObserver: NSObjectProtocol?

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    /// Register the summon hotkey. Call once at launch, right after the
    /// existing GlobalHotkey registration in GruxApp.
    func registerHotkey() {
        hotkey.register(
            keyCode: PaletteHotkeyConfig.keyCode,
            modifiers: PaletteHotkeyConfig.modifiers
        ) {
            Task { @MainActor in
                OrbCommandPaletteController.shared.toggle()
            }
        }
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    func show() {
        // Rebuild every open so the action list reflects live state
        // (mute toggle wording, current workflow definitions).
        hide()

        let width: CGFloat = 560
        let height: CGFloat = 380
        guard let screen = screenUnderMouse() ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        // Spotlight-style placement: horizontally centered, upper third.
        let origin = NSPoint(
            x: vf.midX - width / 2,
            y: vf.minY + vf.height * 0.62 - height / 2
        )
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))

        let p = PalettePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let root = AnyView(
            OrbCommandPaletteView(
                actions: PaletteActionProvider.actions(),
                dismiss: { [weak self] in
                    Task { @MainActor [weak self] in self?.hide() }
                }
            )
        )
        let hc = NSHostingController(rootView: root)
        hc.view.frame = CGRect(origin: .zero, size: frame.size)
        hc.view.autoresizingMask = [.width, .height]
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = CGColor.clear
        p.contentView = hc.view

        // Dismiss when the panel loses key (clicked elsewhere), matching
        // Spotlight semantics.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }

        self.panel = p
        self.hostingController = hc
        p.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }
}

// Same key/main split as FocusOverlayPanel and StagePanel: key so the text
// field types, never main so the launch window keeps its identity.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: Palette view

struct OrbCommandPaletteView: View {
    let actions: [PaletteAction]
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [PaletteAction] {
        PaletteFuzzy.rank(actions, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Color.white.opacity(0.08))
            resultsList
        }
        .frame(width: 560, height: 380)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .fill(GruxTheme.base.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous)
                .strokeBorder(GruxTheme.iridescentRim, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: GruxTheme.Radius.hud, style: .continuous))
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onExitCommand { dismiss() }
    }

    // Tight input scale: 8/12 padding, 14pt text.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(GruxTheme.textSecondary)
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(GruxTheme.textPrimary)
                .focused($fieldFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
            Text("esc")
                .font(.caption2.monospaced())
                .foregroundStyle(GruxTheme.textTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if filtered.isEmpty {
                        Text("No matching commands")
                            .font(.system(size: 12))
                            .foregroundStyle(GruxTheme.textTertiary)
                            .padding(.vertical, 18)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, action in
                        row(action, selected: index == clampedSelection)
                            .id(action.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                runSelected()
                            }
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedIndex) { _, _ in
                if let target = filtered.indices.contains(clampedSelection)
                    ? filtered[clampedSelection].id : nil {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func row(_ action: PaletteAction, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(selected ? GruxTheme.accentPrimaryLight : GruxTheme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                if !action.subtitle.isEmpty {
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(selected ? GruxTheme.accentPrimary.opacity(0.22) : Color.clear)
        )
    }

    private var clampedSelection: Int {
        guard !filtered.isEmpty else { return 0 }
        return min(max(0, selectedIndex), filtered.count - 1)
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (clampedSelection + delta + filtered.count) % filtered.count
    }

    private func runSelected() {
        guard filtered.indices.contains(clampedSelection) else { return }
        let action = filtered[clampedSelection]
        dismiss()
        action.run()
    }
}
