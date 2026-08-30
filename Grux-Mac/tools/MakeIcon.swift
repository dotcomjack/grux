#!/usr/bin/env swift

// Renders the Grux app icon as a 1024x1024 PNG. Piped into iconutil by
// tools/build-icon.sh to produce AppIcon.icns.
//
// Design: dark squircle with a bold "G" in Grux's signature iridescent
// gradient (violet → cyan), lifted by a soft violet glow. Ties the icon to
// the refocus-glow border feature.

import AppKit
import CoreText
import CoreGraphics

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("ctx creation failed\n", stderr); exit(1)
}

// Route NSAttributedString drawing into our context.
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns

// Squircle path, 22.37% corner radius matches the Apple macOS icon grid.
let cornerRadius: CGFloat = size * 0.2237
let squircle = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// 1. Squircle background, deep near-black with a subtle violet tint.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        NSColor(red: 0x18/255, green: 0x12/255, blue: 0x28/255, alpha: 1).cgColor,
        NSColor(red: 0x0A/255, green: 0x0A/255, blue: 0x0C/255, alpha: 1).cgColor,
        NSColor(red: 0x04/255, green: 0x02/255, blue: 0x0A/255, alpha: 1).cgColor
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// 2. Radial violet glow behind the center, gives the icon depth & brand.
let glowCenter = CGPoint(x: size * 0.5, y: size * 0.47)
let glowGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        NSColor(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255, alpha: 0.45).cgColor,
        NSColor(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255, alpha: 0.12).cgColor,
        NSColor(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255, alpha: 0.00).cgColor
    ] as CFArray,
    locations: [0.0, 0.55, 1.0]
)!
ctx.drawRadialGradient(
    glowGradient,
    startCenter: glowCenter,
    startRadius: 0,
    endCenter: glowCenter,
    endRadius: size * 0.55,
    options: []
)

// 3. "G" letterform, bold, centered, iridescent gradient fill, with a
//    soft drop-glow for presence. We build the glyph path once, then use it
//    twice (glow pass + gradient fill pass).
let letter = "G" as NSString
let fontSize: CGFloat = size * 0.78
let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
let ctFont = font as CTFont

// Build a CGPath for the "G" glyph via CoreText.
var unichars: [UniChar] = Array(letter as String).flatMap { Array(String($0).utf16) }
var glyphs: [CGGlyph] = Array(repeating: 0, count: unichars.count)
CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, unichars.count)
guard let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil) else {
    fputs("glyph path failed\n", stderr); exit(1)
}

// CoreText origin is baseline-left. Translate so the glyph is centered in
// the icon canvas (visually balanced, optical center sits slightly above
// geometric center so we bias up a hair).
let glyphBounds = glyphPath.boundingBox
let tx = (size - glyphBounds.width) / 2 - glyphBounds.minX
let ty = (size - glyphBounds.height) / 2 - glyphBounds.minY - size * 0.015
var transform = CGAffineTransform(translationX: tx, y: ty)
guard let positionedG = glyphPath.copy(using: &transform) else {
    fputs("glyph transform failed\n", stderr); exit(1)
}

// 3a. Glow pass, fill the glyph with the violet accent behind a strong
//     shadow, so the glow bleeds out around the letter even after the
//     gradient pass on top.
ctx.saveGState()
ctx.setShadow(
    offset: .zero,
    blur: size * 0.075,
    color: NSColor(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255, alpha: 0.95).cgColor
)
ctx.addPath(positionedG)
ctx.setFillColor(NSColor(red: 0x7B/255, green: 0x61/255, blue: 0xFF/255, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// 3b. Gradient fill pass, clip to the glyph and draw the iridescent
//     gradient (light violet → violet → cyan), matching GruxTheme.iridescent.
ctx.saveGState()
ctx.addPath(positionedG)
ctx.clip()
let iridescent = CGGradient(
    colorsSpace: cs,
    colors: [
        NSColor(red: 0xE4/255, green: 0xD8/255, blue: 0xFF/255, alpha: 1).cgColor, // near-white violet
        NSColor(red: 0xC8/255, green: 0xB6/255, blue: 0xFF/255, alpha: 1).cgColor, // light violet
        NSColor(red: 0x8E/255, green: 0x72/255, blue: 0xFF/255, alpha: 1).cgColor, // mid violet
        NSColor(red: 0x6E/255, green: 0xE0/255, blue: 0xFF/255, alpha: 1).cgColor  // cyan co-accent
    ] as CFArray,
    locations: [0.0, 0.28, 0.65, 1.0]
)!
// Gradient sweeps top-left → bottom-right (matches GruxTheme.iridescent).
ctx.drawLinearGradient(
    iridescent,
    start: CGPoint(x: size * 0.15, y: size * 0.88),
    end: CGPoint(x: size * 0.90, y: size * 0.12),
    options: []
)
ctx.restoreGState()

// 4. Top specular highlight, a subtle white fade at the top of the
//    squircle gives the icon a glass / depth quality.
ctx.saveGState()
let specular = CGGradient(
    colorsSpace: cs,
    colors: [
        NSColor(white: 1, alpha: 0.10).cgColor,
        NSColor(white: 1, alpha: 0.00).cgColor
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    specular,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: size * 0.55),
    options: []
)
ctx.restoreGState()

ctx.restoreGState() // end squircle clip

// 5. Hairline rim, tiny white stroke on the squircle edge for definition.
ctx.saveGState()
ctx.addPath(squircle)
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// Export PNG.
guard let cgImage = ctx.makeImage() else {
    fputs("makeImage failed\n", stderr); exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: outPath)
do {
    try png.write(to: url)
    print("wrote \(url.path) (\(png.count) bytes)")
} catch {
    fputs("write failed: \(error)\n", stderr); exit(1)
}
