import SwiftUI
import AppKit
import ImageIO

// The Home tab hero: a dark aurora backdrop filling the top, a gradient
// scrim fading it into the GruxTheme base, an iridescent glass orb floating
// with a subtle breathing + parallax drift, and the GRUX wordmark over a
// warm, time-aware greeting. Premium, editorial, lots of negative space.
//
// Motion honors reduceMotion: when the user opted out, the orb sits still
// (no breathing, no drift) and the appear transitions collapse to instant.
//
// Assets are bundled at Contents/Resources/ (see build.sh):
//   home-hero.jpg     dark aurora backdrop with negative space at the bottom
//   home-orb-0.png    iridescent glass orb rendered on white (soft-masked)
//   home-orb-cutout.png  preferred if present (orb on transparent bg)
struct HomeHeroView: View {
    let greeting: String
    let dateLine: String
    /// From `heroHeight(forPane:)`: the full 360 where there is room, short
    /// where the pane is, so Start my day is never below the fold.
    var height: CGFloat = HomeHeroView.fullHeight

    static let fullHeight: CGFloat = 360
    static let shortHeight: CGFloat = 150
    /// Below this pane height the full hero pushed Start my day out of sight
    /// at the default 1100x560 window (audit 2026-10-13, item 4).
    static let shortBelow: CGFloat = 700

    static func heroHeight(forPane paneHeight: CGFloat) -> CGFloat {
        paneHeight > 0 && paneHeight < shortBelow ? shortHeight : fullHeight
    }
    @ObservedObject private var assets = HomeAssets.shared

    // Breathing scale + parallax offset, driven by a repeatForever animation
    // that we only start when reduceMotion is off.
    @State private var breathe = false
    /// Pictures, the blur and the shadow wait one beat. They were the rest
    /// of the first Home open after the greeting was already on screen.
    @State private var showArt = false

    private var motionOff: Bool { GruxTheme.reduceMotion }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            scrim
            if showArt {
                orb
            }
            // The wordmark rides the same content column as the card stack
            // below it, while the scrim, orb and backdrop stay full bleed. Once
            // HomeView capped that stack, a hero greeting still pinned to the
            // far left sat roughly 400pt to the LEFT of the cards under it at a
            // 2400pt window, and the hero stopped reading as the same surface.
            // The image wants the whole width; the words want the column.
            wordmark
                .frame(maxWidth: GruxLayout.contentMax, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // The backdrop is a BACKGROUND, not a ZStack member, and that is a
        // layout fix rather than a style choice.
        //
        // As a member it was `.aspectRatio(contentMode: .fill)` inside a 360pt
        // tall frame, so it reported a width of 360 times the image's aspect
        // ratio. For this backdrop that is wider than the 599pt a tab's detail
        // pane is handed at the 840pt window floor, and a ZStack reports the
        // width of its widest child, so the whole Home tab demanded more than
        // the window could give. The `.frame(maxWidth: .infinity)` above cannot
        // shrink an oversized child, and `.clipped()` only masks the drawing,
        // it does not retract the demand. The stack then reported wider than the
        // window, the window centred it, and the fixed nav rail lost its leading
        // edge: the sidebar rendered "OMMAND" and "aused".
        //
        // A background is sized BY its primary view and never contributes to
        // that view's size, so the image still fills and still bleeds, and
        // `.clipped()` still trims it, but Home now asks for exactly what it is
        // given. Measured at the 840pt floor: 217pt of nav rail before, 240pt
        // after.
        .background {
            if showArt {
                backdrop
            } else {
                LinearGradient(
                    colors: [GruxTheme.accentPrimary.opacity(0.45), GruxTheme.base],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .clipped()
        // A task, so leaving Home inside the first beat cancels it.
        .task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            showArt = true
            guard !motionOff else { return }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if let image = assets.heroBackdrop {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A whisper of parallax: the backdrop drifts opposite the orb.
                .offset(y: motionOff ? 0 : (breathe ? -6 : 0))
                .accessibilityHidden(true)
        } else {
            // No asset: fall back to the brand gradient so the hero still reads.
            LinearGradient(
                colors: [GruxTheme.accentPrimary.opacity(0.45), GruxTheme.base],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // Gradient scrim: transparent at the top, fading to the app base at the
    // bottom so the briefing cards below feel continuous with the hero.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: GruxTheme.base.opacity(0.25), location: 0.45),
                .init(color: GruxTheme.base.opacity(0.78), location: 0.78),
                .init(color: GruxTheme.base, location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Orb

    /// 220 in the full hero; in the short one it shrinks with it, so the orb
    /// floats whole instead of being cut off by the hero's bottom edge.
    private var orbSize: CGFloat { min(220, height * 0.6) }

    // Floats upper-trailing, leaving the lower-leading negative space for the
    // wordmark. Soft radial mask hides the white plate on home-orb-0.png when
    // no transparent cutout is bundled.
    private var orb: some View {
        GeometryReader { geo in
            Group {
                if let cutout = assets.orbCutout {
                    Image(nsImage: cutout)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let plate = assets.orbPlate {
                    Image(nsImage: plate)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // Soft circular mask drops the white background to a
                        // clean floating orb. RadialGradient mask: opaque core,
                        // feathered edge.
                        .mask(
                            RadialGradient(
                                stops: [
                                    .init(color: .white, location: 0.0),
                                    .init(color: .white, location: 0.62),
                                    .init(color: .white.opacity(0.0), location: 0.74)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geo.size.height * 0.30
                            )
                        )
                        .blendMode(.screen)
                } else {
                    // No orb asset: a soft brand glow stands in.
                    Circle()
                        .fill(GruxTheme.iridescent)
                        .blur(radius: 30)
                        .opacity(0.55)
                }
            }
            .frame(width: orbSize, height: orbSize)
            .scaleEffect(motionOff ? 1.0 : (breathe ? 1.035 : 0.985))
            .offset(
                x: geo.size.width - orbSize * 0.95,
                y: (motionOff ? 30 : (breathe ? 22 : 38)) * orbSize / 220
            )
            .shadow(color: GruxTheme.violetGlow(strong: true), radius: 44, x: 0, y: 18)
            .accessibilityHidden(true)
        }
    }

    // MARK: Wordmark + greeting

    private var wordmark: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text("GRUX AI")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .kerning(6)
                .foregroundStyle(GruxTheme.textSecondary)

            Text(greeting)
                .font(GruxType.display)
                .foregroundStyle(GruxTheme.textPrimary)
                .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 4)

            Text(dateLine)
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
        }
        .padding(.horizontal, GruxSpacing.xl)
        .padding(.bottom, GruxSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bundled asset loader

// The backdrop is 871 KB and the orb plate is 3.8 MB. Decoding them on the
// click made the first Home open wait. `preload()` starts at launch, off
// the main thread. The hero draws the greeting immediately and picks up
// the pictures when they are ready.
@MainActor
final class HomeAssets: ObservableObject {
    static let shared = HomeAssets()

    @Published private(set) var heroBackdrop: NSImage?
    @Published private(set) var orbCutout: NSImage?
    @Published private(set) var orbPlate: NSImage?

    func preload() {
        let backdrop = Bundle.main.url(forResource: "home-hero", withExtension: "jpg")
        let cutout = Bundle.main.url(forResource: "home-orb-cutout", withExtension: "png")
        let plate = Bundle.main.url(forResource: "home-orb-0", withExtension: "png")
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded = (
                Self.decode(backdrop),
                Self.decode(cutout),
                Self.decode(plate)
            )
            DispatchQueue.main.async {
                self.heroBackdrop = decoded.0
                self.orbCutout = decoded.1
                self.orbPlate = decoded.2
            }
        }
    }

    nonisolated private static func decode(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = NSSize(width: image.width, height: image.height)
        return NSImage(cgImage: image, size: size)
    }
}
