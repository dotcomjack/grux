import SwiftUI
import AppKit

// Floating live-workspace overlay. Two modes:
//   - Expanded card: current task title + project + quick actions, anchored
//     top-right of the active screen. Glass shell matching the ambient HUD.
//   - Collapsed orb: a 44pt Grux orb that pulses in the current focus-verdict
//     color (green on task, yellow drifting, red off task, purple idle).
//     Tapping it reopens the card.
//
// The overlay reads AppState.currentTask, AppState.lastVerdict, and
// AppState.micMuted so every surface (sidebar orb, ambient HUD, menu bar,
// this overlay) tells the same story.
struct FocusOverlayView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var overlay = FocusOverlayState.shared

    var body: some View {
        Group {
            if overlay.isCollapsed {
                collapsedOrb
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: anchor).combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: anchor).combined(with: .opacity)
                    ))
            } else {
                expandedCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9, anchor: anchor).combined(with: .opacity),
                        removal: .scale(scale: 0.85, anchor: anchor).combined(with: .opacity)
                    ))
            }
        }
        // Shadow breathing room; the panel is sized to this whole view.
        .padding(6)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { overlay.contentSize = geo.size }
                .onChange(of: geo.size) { _, size in overlay.contentSize = size }
        })
        // Pinned to the corner nearest the screen edge, so while the panel is
        // larger than the content (the collapse transition) the content sits
        // where its outer corner was rather than centred in an invisible box.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: overlay.isCollapsed)
    }

    /// The outer corner: the transition scales from it and the content pins to it.
    private var anchor: UnitPoint {
        switch (overlay.side, overlay.vertical) {
        case (.left, .top): return .topLeading
        case (.left, .bottom): return .bottomLeading
        case (.right, .top): return .topTrailing
        case (.right, .bottom): return .bottomTrailing
        }
    }

    private var alignment: Alignment {
        switch (overlay.side, overlay.vertical) {
        case (.left, .top): return .topLeading
        case (.left, .bottom): return .bottomLeading
        case (.right, .top): return .topTrailing
        case (.right, .bottom): return .bottomTrailing
        }
    }

    // MARK: - Expanded card

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().background(Color.white.opacity(0.08))
            taskBlock
        }
        .padding(14)
        .frame(width: 320)
        .background(GlassBackground(verdictColor: verdictColor, isMuted: appState.micMuted))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            verdictColor.opacity(0.55),
                            Color.purple.opacity(0.35),
                            Color.indigo.opacity(0.25),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        )
        .shadow(color: verdictColor.opacity(0.28), radius: 24, x: 0, y: 10)
        .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 6)
    }

    private var header: some View {
        // The orb sits on the OUTER edge, the one nearest the screen edge, so
        // it stays put when the card collapses into it; the collapse control
        // sits on the inner edge, where the rest of the desktop is. On the
        // right half that reads collapse, title, orb; on the left half it is
        // mirrored.
        HStack(spacing: 10) {
            if overlay.side == .left { orbBadge }
            else { collapseControl }
            VStack(alignment: .leading, spacing: 1) {
                Text("FOCUS")
                    .font(.system(size: 10, weight: .black, design: .default))
                    .kerning(2.2)
                Text(statusLine)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if overlay.side == .left { collapseControl }
            else { orbBadge }
        }
        .background(FocusOverlayDragHandle())
    }

    private var collapseControl: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                overlay.isCollapsed = true
            }
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Collapse to Grux orb")
    }

    private var orbBadge: some View {
        PulseOrb(color: verdictColor, isMuted: appState.micMuted, size: 26)
    }

    private var taskBlock: some View {
        Group {
            if let t = appState.currentTask {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !t.project.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(t.project)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            appState.completeTask(t.id)
                        } label: {
                            Label("Done", systemImage: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(
                                    Capsule().fill(LinearGradient(
                                        colors: [.mint.opacity(0.85), .green.opacity(0.75)],
                                        startPoint: .leading, endPoint: .trailing))
                                )
                                .foregroundStyle(.white)
                        }.buttonStyle(.plain)
                        Button {
                            WindowOpener.openTasks()
                        } label: {
                            Label("Stack", systemImage: "list.bullet.rectangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                        Spacer()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No current focus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        WindowOpener.openTasks()
                    } label: {
                        Label("Open Task Stack", systemImage: "list.bullet.rectangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.purple.opacity(0.5)))
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Collapsed orb

    private var collapsedOrb: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                overlay.isCollapsed = false
            }
        } label: {
            PulseOrb(color: verdictColor, isMuted: appState.micMuted, size: 44)
                .frame(width: 52, height: 52)
                .background(FocusOverlayDragHandle())
        }
        .buttonStyle(.plain)
        .help(appState.currentTask.map { "Focus: \($0.title), tap to expand" } ?? "Tap to expand focus overlay")
    }

    // MARK: - Derived state

    private var verdictColor: Color {
        if appState.micMuted { return Color.gray.opacity(0.7) }
        switch appState.lastVerdict {
        case .onTask: return .mint
        case .drifting: return .yellow
        case .offTask: return .red
        case .ambiguous, .none: return .purple
        }
    }

    private var statusLine: String {
        if appState.micMuted { return "muted · overlay idle" }
        switch appState.lastVerdict {
        case .onTask: return "on task"
        case .drifting: return "drifting"
        case .offTask: return "off task"
        case .ambiguous: return "checking…"
        case .none: return appState.watching ? "watching" : "idle"
        }
    }
}

// MARK: - Pulse orb

// Gentle Grux-colored pulse in sync with focus verdict. Uses two layered
// animated rings + a glow. All animations are low-amplitude so the overlay
// never shouts - the brief was "gentle".
private struct PulseOrb: View {
    let color: Color
    let isMuted: Bool
    let size: CGFloat

    // The turn and the breathing ring are Core Animation (OrbLayers.swift).
    // This pill is on screen on every Space all day, so a SwiftUI animation
    // here was a per-frame main thread cost that never stopped; the render
    // server does it for nothing.
    var body: some View {
        ZStack {
            // Soft halo
            Circle()
                .fill(RadialGradient(
                    colors: [color.opacity(isMuted ? 0.18 : 0.45), .clear],
                    center: .center,
                    startRadius: size * 0.15,
                    endRadius: size * 1.4))
                .blur(radius: 4)

            // Core
            OrbCoreLayer(spec: Self.coreSpec(color: color))

            // Inner highlight (natural 3D feel)
            Circle()
                .fill(Color.white.opacity(isMuted ? 0.12 : 0.28))
                .frame(width: size * 0.32, height: size * 0.32)
                .offset(x: -size * 0.14, y: -size * 0.18)
                .blur(radius: size * 0.12)

            // Rim
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .clear, .white.opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.7
                )
                .blendMode(.overlay)

            // Breathing ring - the "focus heartbeat"
            if !isMuted {
                OrbRingsLayer(rings: [Self.heartbeat(color: color)])
                    .allowsHitTesting(false)
            }

            if isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.45), radius: 2)
            }
        }
        .frame(width: size, height: size)
    }

    /// The SwiftUI core ran 0 to 113 degrees every 9 seconds. Same speed, one
    /// seamless turn.
    static let turnSeconds: Double = 9 * 360 / (2 * .pi * 18)

    static func coreSpec(color: Color) -> OrbCoreSpec {
        let c = NSColor.orb(color), indigo = NSColor.orb(.indigo)
        return OrbCoreSpec(
            colors: [c, c.withAlphaComponent(c.alphaComponent * 0.75),
                     indigo.withAlphaComponent(indigo.alphaComponent * 0.7),
                     c.withAlphaComponent(c.alphaComponent * 0.9), c],
            maskStops: [(1, 0), (0.85, 0.5), (0, 1)],
            // endRadius was size * 0.55 on a radius of size / 2.
            maskRadius: 1.1,
            turnSeconds: turnSeconds)
    }

    static func heartbeat(color: Color) -> OrbRingSpec {
        let c = NSColor.orb(color)
        return OrbRingSpec(color: c.withAlphaComponent(c.alphaComponent * 0.45), lineWidth: 1.2,
                           scale: 1.0...1.4, opacity: (1, 0), seconds: 1.8, easeInOut: true)
    }
}

// MARK: - Glass background

private struct GlassBackground: View {
    let verdictColor: Color
    let isMuted: Bool

    var body: some View {
        ZStack {
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        verdictColor.opacity(isMuted ? 0.02 : 0.05),
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Drag handle

// Mirrors the ambient HUD's DragHandle so this panel is movable from
// anywhere in its background. Lets the user yank the overlay around without
// needing an explicit titlebar.
struct FocusOverlayDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = FocusDragView()
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - State holder

@MainActor
final class FocusOverlayState: ObservableObject {
    static let shared = FocusOverlayState()

    @Published var isCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: "grux.focusOverlayCollapsed")
        }
    }
    @Published var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: "grux.focusOverlayVisible")
        }
    }
    /// Which half of the screen the card is on. Written by the controller as
    /// the panel moves; read by the view to mirror itself.
    @Published var side: FocusOverlaySide = .right
    @Published var vertical: FocusOverlayVerticalHalf = .top
    /// The view's own size, reported every layout; the panel follows it.
    @Published var contentSize: CGSize = .zero

    private init() {
        let d = UserDefaults.standard
        self.isCollapsed = d.bool(forKey: "grux.focusOverlayCollapsed")
        // Default to visible on first launch.
        if d.object(forKey: "grux.focusOverlayVisible") == nil {
            self.isVisible = true
            d.set(true, forKey: "grux.focusOverlayVisible")
        } else {
            self.isVisible = d.bool(forKey: "grux.focusOverlayVisible")
        }
    }
}
