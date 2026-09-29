import AppKit
import Combine
import QuartzCore
import SwiftUI

/// The orb's perpetual motion, on Core Animation instead of SwiftUI.
///
/// WHY THIS EXISTS. A SwiftUI `repeatForever` animation is driven from the app's
/// main thread: every display frame SwiftUI re-renders the window's display list,
/// and AppKit re-lays the window out to commit it. Measured on the running app on
/// 2026-09-21 with a 5 second `sample`: the main thread was busy about a quarter of
/// the time in `NSDisplayCycleFlush` into `NSHostingView.layout()` into
/// `DisplayList.ViewUpdater.render`, while nothing on screen was changing except
/// an orb turning. A `CABasicAnimation` is handed to the render server ONCE and
/// interpolated there, so an orb that turns forever costs this process nothing
/// per frame.
///
/// WHAT MOVES. Only what visibly moved before: the core's angular gradient turns,
/// and the pulse rings expand and fade. The old halo and core "breathing"
/// (`scaleEffect(1 + a * sin(phase * k))`) never moved at all, because SwiftUI
/// interpolates the modifier's final value and `sin(2 * pi * k)` is the value it
/// started from. The turn is continuous here at the same angular speed; the old
/// one ran 0 to 113 degrees and snapped back.
///
/// The user's reduce-motion preference freezes it. `MotionSuspension` does NOT,
/// on purpose: the render server does not composite an occluded window, and the
/// Focus pill, which is on screen on every Space, is exactly the orb that should
/// keep breathing while the rest of the app is still.
struct OrbCoreSpec: Equatable {
    /// Angular gradient stops, clockwise from twelve o'clock.
    var colors: [NSColor]
    /// Radial mask, centre outwards: (opacity, location 0...1 of `maskRadius`).
    var maskStops: [(alpha: CGFloat, location: CGFloat)]
    /// The mask's outer radius as a fraction of the orb's radius. Above 1 means
    /// the orb's edge sits inside the gradient, which is how the SwiftUI version
    /// looked with a fixed `endRadius` larger than the orb.
    var maskRadius: CGFloat
    /// Seconds for one full clockwise turn.
    var turnSeconds: Double

    static func == (a: Self, b: Self) -> Bool {
        a.colors == b.colors && a.maskRadius == b.maskRadius && a.turnSeconds == b.turnSeconds
            && a.maskStops.map(\.alpha) == b.maskStops.map(\.alpha)
            && a.maskStops.map(\.location) == b.maskStops.map(\.location)
    }
}

struct OrbRingSpec: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var scale: ClosedRange<CGFloat>
    var opacity: (from: Float, to: Float)
    var seconds: Double
    var easeInOut: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.color == b.color && a.lineWidth == b.lineWidth && a.scale == b.scale
            && a.opacity.from == b.opacity.from && a.opacity.to == b.opacity.to
            && a.seconds == b.seconds && a.easeInOut == b.easeInOut
    }
}

extension NSColor {
    /// A SwiftUI colour resolved to sRGB, so its alpha can be scaled the way
    /// SwiftUI's `.opacity` scales it. A system colour can arrive as a catalog
    /// colour, and those have to be converted before their components are read.
    static func orb(_ color: Color) -> NSColor {
        let c = NSColor(color)
        return c.usingColorSpace(.sRGB) ?? c
    }
}

enum OrbMotion {
    static let turnKey = "orb.turn"
    static let ringKey = "orb.ring"

    /// A turn that repeats forever without a seam. Negative because Core
    /// Animation's positive z rotation is counterclockwise in an unflipped view,
    /// and SwiftUI's `rotationEffect` with positive degrees is clockwise.
    /// Nil when the user asked for less motion, so a loop cannot be built
    /// without consulting the gate.
    @MainActor static func turn(seconds: Double) -> CABasicAnimation? {
        guard !userWantsStill else { return nil }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = seconds
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        return a
    }

    @MainActor static func ring(_ spec: OrbRingSpec) -> CAAnimationGroup? {
        guard !userWantsStill else { return nil }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = spec.scale.lowerBound
        scale.toValue = spec.scale.upperBound
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = spec.opacity.from
        fade.toValue = spec.opacity.to
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = spec.seconds
        g.repeatCount = .infinity
        g.isRemovedOnCompletion = false
        g.timingFunction = CAMediaTimingFunction(name: spec.easeInOut ? .easeInEaseOut : .easeOut)
        return g
    }

    /// The user's own reduce-motion preference, and nothing else. See the type
    /// comment for why suspension is not consulted.
    @MainActor static var userWantsStill: Bool { stillness() }

    /// Seams, so a test can flip the preference without writing the real
    /// theme file. The app never replaces them.
    @MainActor static var stillness: () -> Bool = { ThemeConfig.currentPalette.reduceMotion }
    /// Fires when the preference may have changed. The theme bumps `revision`
    /// on every committed change, after the palette is published.
    @MainActor static var preferenceChanged: AnyPublisher<Void, Never> =
        ThemeConfig.shared.$revision.map { _ in () }.eraseToAnyPublisher()
}

/// A live reduce-motion toggle must reach an orb that is already turning.
/// Hosted panels built once (the Focus pill is one) never rebuild their views
/// on a theme change, and `apply` only runs when the orb's colours change, so
/// without this the toggle was ignored until the next state change. Found by
/// the independent review of P-R-8. The hop to the next main loop turn lets
/// the published value land before it is read.
@MainActor
private final class OrbPreferenceWatch {
    private var token: AnyCancellable?
    init(_ onChange: @escaping @MainActor () -> Void) {
        token = OrbMotion.preferenceChanged.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
        }
    }
}

/// The turning core. Draws nothing but the masked angular gradient; the halo,
/// highlight and rim stay in SwiftUI because they never move.
struct OrbCoreLayer: NSViewRepresentable {
    let spec: OrbCoreSpec

    func makeNSView(context: Context) -> OrbCoreNSView { OrbCoreNSView() }
    func updateNSView(_ view: OrbCoreNSView, context: Context) { view.apply(spec) }
}

final class OrbCoreNSView: NSView {
    private let clip = CALayer()
    private let gradient = CAGradientLayer()
    private let mask = CAGradientLayer()
    private var spec: OrbCoreSpec?
    private var watch: OrbPreferenceWatch?

    /// Whether the turn is running, for tests.
    var isTurning: Bool { gradient.animation(forKey: OrbMotion.turnKey) != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        watch = OrbPreferenceWatch { [weak self] in self?.syncMotion() }
        wantsLayer = true
        clip.masksToBounds = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        // The first stop sits at three o'clock, where SwiftUI's AngularGradient
        // starts it. The gradient turns, so where it starts only matters on
        // the first frame.
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        mask.type = .radial
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.mask = mask
        clip.addSublayer(gradient)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    func apply(_ next: OrbCoreSpec) {
        guard next != spec else { return }
        let restart = spec?.turnSeconds != next.turnSeconds
        spec = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = next.colors.map(\.cgColor)
        mask.colors = next.maskStops.map { NSColor.white.withAlphaComponent($0.alpha).cgColor }
        mask.locations = next.maskStops.map { NSNumber(value: Double($0.location)) }
        let reach = 0.5 + 0.5 * next.maskRadius
        mask.endPoint = CGPoint(x: reach, y: reach)
        CATransaction.commit()
        if restart { gradient.removeAnimation(forKey: OrbMotion.turnKey) }
        syncMotion()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.cornerRadius = min(bounds.width, bounds.height) / 2
        // Center-anchored so the turn is about the orb's middle.
        gradient.bounds = CGRect(origin: .zero, size: bounds.size)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mask.frame = gradient.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncMotion()
    }

    private func syncMotion() {
        guard let spec, window != nil else { return }
        guard let turn = OrbMotion.turn(seconds: spec.turnSeconds) else {
            gradient.removeAnimation(forKey: OrbMotion.turnKey)
            return
        }
        if gradient.animation(forKey: OrbMotion.turnKey) == nil {
            gradient.add(turn, forKey: OrbMotion.turnKey)
        }
    }
}

/// Expanding, fading rings. One view holds any number of them.
struct OrbRingsLayer: NSViewRepresentable {
    let rings: [OrbRingSpec]

    func makeNSView(context: Context) -> OrbRingsNSView { OrbRingsNSView() }
    func updateNSView(_ view: OrbRingsNSView, context: Context) { view.apply(rings) }
}

final class OrbRingsNSView: NSView {
    private var shapes: [CAShapeLayer] = []
    private var specs: [OrbRingSpec] = []
    private var watch: OrbPreferenceWatch?

    /// How many rings are pulsing, for tests.
    var pulsingCount: Int { shapes.filter { $0.animation(forKey: OrbMotion.ringKey) != nil }.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        watch = OrbPreferenceWatch { [weak self] in self?.syncMotion() }
        wantsLayer = true
        // The rings grow past the orb's frame, as they did in SwiftUI.
        clipsToBounds = false
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ next: [OrbRingSpec]) {
        guard next != specs else { return }
        specs = next
        shapes.forEach { $0.removeFromSuperlayer() }
        shapes = next.map { spec in
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = spec.color.cgColor
            s.lineWidth = spec.lineWidth
            layer?.addSublayer(s)
            return s
        }
        needsLayout = true
        syncMotion()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in shapes {
            s.bounds = CGRect(origin: .zero, size: bounds.size)
            s.position = CGPoint(x: bounds.midX, y: bounds.midY)
            s.path = CGPath(ellipseIn: s.bounds.insetBy(dx: s.lineWidth / 2, dy: s.lineWidth / 2),
                            transform: nil)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncMotion()
    }

    private func syncMotion() {
        guard window != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (s, spec) in zip(shapes, specs) {
            // At rest the rings hold their starting pose, which is what the
            // SwiftUI version froze at when reduce motion was on.
            s.transform = CATransform3DMakeScale(spec.scale.lowerBound, spec.scale.lowerBound, 1)
            s.opacity = spec.opacity.from
            guard let ring = OrbMotion.ring(spec) else {
                s.removeAnimation(forKey: OrbMotion.ringKey)
                continue
            }
            if s.animation(forKey: OrbMotion.ringKey) == nil {
                s.add(ring, forKey: OrbMotion.ringKey)
            }
        }
        CATransaction.commit()
    }
}
