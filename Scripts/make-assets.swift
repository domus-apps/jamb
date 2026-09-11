#!/usr/bin/env swift
// Generates the app icon (Assets/AppIcon.iconset/*.png + icon-1024.png) and
// the README banner (Assets/banner.png) programmatically, so the artwork is
// reproducible from source. Run: swift Scripts/make-assets.swift
// Then:  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
//
// Same Liquid Glass icon language as its siblings Oriel, Pharos, Transom and
// Coffer: the macOS squircle, frosted-glass forms (real gaussian-blurred
// backdrop via CoreImage), specular rim highlights, and soft layered shadows.
// Jamb's glyph is its own UI in miniature: a frosted input field, the yellow
// jump-label chip overlapping its leading edge, and the caret standing at
// the end of the ghosted text — landed and ready to type.

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve) — not a superellipse, whose sides
/// bulge. Radius fitted against the system's live icon mask (measured from
/// Calculator/Notes/Finder at 1024px: 214.5px on the 824px shape, ~0.16px RMS).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

/// Background layer: squircle, teal gradient, top sheen, outer shadow.
/// The two stops of the ground: the same pair the Icon Composer document's
/// fill is written from below, so the Dock and the rendered PNG agree.
let groundTop: UInt32 = 0x4FE0DA
let groundBottom: UInt32 = 0x0A8A8F

func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(0x0FA0A6))
    cg.fillPath()
    cg.restoreGState()

    // A single restrained teal gradient, in the language of macOS system
    // icons: the background recedes, the glyph is the hero.
    linearGradient(
        cg, in: shape,
        colors: [color(groundTop), color(groundBottom)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.minY)
    )
    // Barely-there top light for depth
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.1), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 320)
    )
}

/// Specular rim: a stroke around `path` that is bright on top, fading below.
func glassRim(_ cg: CGContext, around path: CGPath, width: CGFloat, bounds: CGRect, top: CGFloat, bottom: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: stroked,
        colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
}

/// One frosted-glass pane: blurred backdrop, milky tint, specular rim.
func drawGlassPane(
    _ cg: CGContext, path: CGPath, bounds: CGRect, backdrop: CGImage,
    tintTop: CGFloat, tintBottom: CGFloat,
    rimWidth: CGFloat, rimTop: CGFloat, rimBottom: CGFloat,
    shadowBlur: CGFloat, shadowAlpha: CGFloat
) {
    // Drop shadow (opaque fill, replaced by the glass interior right after)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.4), blur: shadowBlur, color: color(0x063D3E, shadowAlpha))
    cg.addPath(path)
    cg.setFillColor(color(0x9AE4E0))
    cg.fillPath()
    cg.restoreGState()

    // Blurred backdrop + milky tint
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(backdrop, in: designRect)
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF, tintTop), color(0xFFFFFF, tintBottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
    cg.restoreGState()

    glassRim(cg, around: path, width: rimWidth, bounds: bounds, top: rimTop, bottom: rimBottom)
}

// The glyph: Jamb's overlay in miniature. A milky glass input field spans the
// middle; the ghosted text ends where the bright caret stands (the jump has
// landed); the yellow label chip overlaps the field's leading edge exactly
// the way the real overlay draws it.
/* The glyph's full extent — chip's left edge through the field's right
   edge — sits 12px left of true center: the wide bright field outweighs
   the small chip, so geometric centering reads as drifting right. */
let field = CGRect(x: 260, y: 396, width: 588, height: 232)
let chip = CGRect(x: 152, y: 424, width: 232, height: 176)
let textBar = CGRect(x: 432, y: 486, width: 168, height: 52)
let caret = CGRect(x: 642, y: 438, width: 26, height: 148)

func drawField(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    let path = CGPath(roundedRect: field, cornerWidth: 56, cornerHeight: 56, transform: nil)
    drawGlassPane(
        cg, path: path, bounds: field, backdrop: backdrop,
        tintTop: boost ? 0.72 : 0.6, tintBottom: boost ? 0.58 : 0.44,
        rimWidth: 5, rimTop: 0.95, rimBottom: 0.25,
        shadowBlur: 46, shadowAlpha: 0.32
    )
    drawFieldContent(cg)
}

/// The ghosted text and the caret standing after it. Shared between the
/// rendered icon and the flat Icon Composer layers.
func drawFieldContent(_ cg: CGContext) {
    // Ghost text: what was already in the field
    cg.setFillColor(color(0x0B6A6E, 0.4))
    cg.addPath(CGPath(
        roundedRect: textBar, cornerWidth: textBar.height / 2, cornerHeight: textBar.height / 2, transform: nil
    ))
    cg.fillPath()

    // The caret: the landed insertion point, bright with a soft glow
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 30, color: color(0xFFFFFF, 0.55))
    cg.addPath(CGPath(
        roundedRect: caret, cornerWidth: caret.width / 2, cornerHeight: caret.width / 2, transform: nil
    ))
    cg.setFillColor(color(0xFFFFFF, 0.97))
    cg.fillPath()
    cg.restoreGState()
}

func drawChip(_ cg: CGContext, boost: Bool) {
    let path = CGPath(roundedRect: chip, cornerWidth: 44, cornerHeight: 44, transform: nil)

    // The chip is the hero: warm label-yellow glass over the cool teal.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: color(0x063D3E, 0.35))
    cg.addPath(path)
    cg.setFillColor(color(0xFFC63A))
    cg.fillPath()
    cg.restoreGState()

    linearGradient(
        cg, in: path,
        colors: [color(0xFFDE71), color(0xFFB92B)],
        from: CGPoint(x: chip.midX, y: chip.maxY), to: CGPoint(x: chip.midX, y: chip.minY)
    )
    glassRim(cg, around: path, width: 5, bounds: chip, top: 1.0, bottom: 0.35)
    drawChipLetter(cg)
}

/// The label letter — the keys you type are the entire interaction, and "j"
/// is both the label and the app's initial. Shared with the flat layers.
func drawChipLetter(_ cg: CGContext) {
    let letter = NSAttributedString(string: "j", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 128, weight: .bold),
        .foregroundColor: NSColor(cgColor: color(0x6E4A00, 0.88))!,
    ])
    let size = letter.size()
    letter.draw(at: NSPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2))
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    let blurRadius = max(36 * scale, 1)
    // Small sizes: more opaque forms keep the glyph legible in the menu bar /
    // Dock, where the frosted subtlety would just vanish.
    let boost = px <= 64

    let bgRep = makeBitmap(px, px)
    withContext(bgRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
    }
    let backdrop = gaussianBlur(bgRep.cgImage!, radius: blurRadius)

    let shape = squircle(in: bgRect)

    /* Clip the glyph to the squircle, and at small sizes optically enlarge
       it (like Apple's small-size icon variants) so it stays prominent in
       the menu bar / Dock. */
    func drawGlyph(_ cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.14, y: 1.14)
            cg.translateBy(x: -512, y: -512)
        }
        body(cg)
        cg.restoreGState()
    }

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(bgRep.cgImage!, in: designRect)
        drawGlyph(cg) { drawField($0, backdrop: backdrop, boost: boost) }
        drawGlyph(cg) { drawChip($0, boost: boost) }
    }
    return rep
}

// MARK: - Icon Composer layers (macOS 26+ .icon document)

/* The .icon format gets dark/clear/tinted appearances for free: we ship flat
   transparent layers plus a background fill, and the system renders the
   Liquid Glass treatment (and the dark background) at runtime. In a .icon
   document the 1024pt canvas IS the icon shape — the system adds its own
   margins — whereas our design space puts the squircle at 100..924, so the
   glyph is remapped to land at the same visual position. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

func drawFlatField(_ cg: CGContext) {
    // Semi-transparent so the system's glass treatment reads it as the pane.
    cg.addPath(CGPath(roundedRect: field, cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.72))
    cg.fillPath()
    drawFieldContent(cg)
}

func drawFlatChip(_ cg: CGContext) {
    cg.addPath(CGPath(roundedRect: chip, cornerWidth: 44, cornerHeight: 44, transform: nil))
    cg.setFillColor(color(0xFFC63A))
    cg.fillPath()
    drawChipLetter(cg)
}

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    linearGradient(
        cg, in: frame,
        colors: [color(0x0E2C2E), color(0x081517)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative input-field outlines on the right, each with its
    // little label chip on the leading edge
    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    cg.setStrokeColor(color(0xFFFFFF, 0.07))
    cg.setLineWidth(3)
    for (x, y, w, h) in [(1330.0, 300.0, 420.0, 120.0), (1450.0, 120.0, 440.0, 120.0), (1240.0, -30.0, 380.0, 120.0)] {
        cg.addPath(CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: 30, cornerHeight: 30, transform: nil
        ))
        cg.strokePath()
        cg.setFillColor(color(0xFFFFFF, 0.1))
        cg.addPath(CGPath(
            roundedRect: CGRect(x: x - 24, y: y + h / 2 - 26, width: 68, height: 52),
            cornerWidth: 14, cornerHeight: 14, transform: nil
        ))
        cg.fillPath()
    }
    cg.restoreGState()

    // App icon on the left
    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    // Wordmark + tagline
    let title = NSAttributedString(string: "Jamb", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 268))

    let tagline = NSAttributedString(string: "Jump the cursor into any input on screen", attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.55, green: 0.85, blue: 0.83, alpha: 1),
    ])
    tagline.draw(at: NSPoint(x: 528, y: 186))
}

// MARK: - GitHub social preview (1280 x 640 design space, rendered @2x)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    // Full bleed — GitHub renders the preview edge to edge and rounds the
    // corners itself, so transparent corners would show through as white.
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(0x103433), color(0x081517)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative field outlines drifting off the corners
    cg.saveGState()
    cg.setStrokeColor(color(0xFFFFFF, 0.06))
    cg.setLineWidth(2.5)
    for (x, y, w, h) in [
        (-110.0, 470.0, 340.0, 100.0), (40.0, 560.0, 300.0, 100.0),
        (1040.0, -20.0, 340.0, 100.0), (1120.0, 110.0, 300.0, 100.0),
    ] {
        cg.addPath(CGPath(
            roundedRect: CGRect(x: x, y: y, width: w, height: h),
            cornerWidth: 26, cornerHeight: 26, transform: nil
        ))
        cg.strokePath()
    }
    cg.restoreGState()

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    // Centered stack: icon, wordmark, tagline — sized up so the chip stays
    // legible at the small sizes link previews render at.
    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 300, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Jamb", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 180)

    drawCentered(
        NSAttributedString(string: "Jump the cursor into any input on screen", attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.55, green: 0.85, blue: 0.83, alpha: 1),
        ]), y: 118)
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.iconset", withIntermediateDirectories: true)

// Iconset: render each size directly from vectors (crisper than downscaling)
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconSizes {
    savePNG(makeIcon(px: px), "Assets/AppIcon.iconset/\(name).png")
}

let master = makeIcon(px: 1024)
savePNG(master, "Assets/icon-1024.png")

// Icon Composer layers for the macOS 26+ .icon document
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
savePNG(makeIconLayer(drawFlatField), "Assets/AppIcon.icon/Assets/back.png")
savePNG(makeIconLayer(drawFlatChip), "Assets/AppIcon.icon/Assets/front.png")

let bannerIcon = makeIcon(px: 728).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

// GitHub social preview: exactly 1280x640, GitHub's recommended size.
let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")

/* Keep the Icon Composer document's background in step with the icon's own
   gradient. macOS 26 renders the document (not the PNG above), and its
   single-color automatic-gradient came out nearly flat in the Dock, while
   the family's two high-chroma stops lived only in the PNG. Only the fill
   is rewritten; the layer groups stay as authored. */
let iconDocumentPath = "Assets/AppIcon.icon/icon.json"
if let data = FileManager.default.contents(atPath: iconDocumentPath),
   var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    func srgb(_ hex: UInt32) -> String {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", r, g, b)
    }
    document["fill"] = ["linear-gradient": [srgb(groundTop), srgb(groundBottom)]]
    let out = try! JSONSerialization.data(
        withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! (String(data: out, encoding: .utf8)! + "\n").write(toFile: iconDocumentPath, atomically: true, encoding: .utf8)
    print("wrote \(iconDocumentPath)")
}
