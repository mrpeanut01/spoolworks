#!/usr/bin/env swift
//
// make-icon.swift — draws Resources/AppIcon.icns from the Modernist design tokens.
//
// The icon is generated rather than committed as art, so it stays in step with the palette: the
// colours below are the same literals as `Theme.accent` and `Theme.rule`. Run it after changing
// them.
//
//   swift Tools/make-icon.swift            writes Resources/AppIcon.icns
//   swift Tools/make-icon.swift --out DIR  writes elsewhere
//
// The mark is a spool seen side-on: two flanges with the filament between them in the accent. It
// has to survive 16 pt, so it is three rectangles and nothing else.
//
// ## Why it is light-on-dark rather than dark-on-light
//
// It was dark-on-light, and on macOS 26 that made the app look like a red dot. The system derives
// dark and tinted variants for an app icon, and the derivation keeps the *mark* while replacing the
// ground — so a mark whose main colour is near-black ink disappears into the ground it is drawn
// against, and the only thing left is the accent-coloured filament between two invisible flanges.
//
// Shipping a layered Icon Composer asset is the proper fix and needs Xcode, which this project
// deliberately does not require (D-002). So the icon is drawn to survive the derivation instead:
// the flanges are the *light* colour and the ground is ink, which reads on a light Dock and still
// reads once the ground is darkened. The one thing no single-image icon can survive is the fully
// monochrome tinted variant, where the red goes too.

import AppKit
import Foundation

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: "--" + name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDir = URL(fileURLWithPath: option("out") ?? repoRoot.appendingPathComponent("Resources").path)

// Modernist tokens, matched to Sources/SpoolworksUI/DesignSystem.swift.
let ground = NSColor(srgbRed: 0xF3 / 255, green: 0xF2 / 255, blue: 0xF2 / 255, alpha: 1)
let ink    = NSColor(srgbRed: 0x20 / 255, green: 0x1E / 255, blue: 0x1D / 255, alpha: 1)
let accent = NSColor(srgbRed: 0xEC / 255, green: 0x30 / 255, blue: 0x13 / 255, alpha: 1)

func drawIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context

    // `NSBitmapImageRep` hands back a buffer it has not zeroed, so anything not covered by a fill
    // is whatever was in that memory. It bit exactly once — a stray yellow band along the bottom of
    // the 32 px face, in an icon drawn only in three greys and a red — and a defect that appears in
    // one of ten sizes depending on what the allocator had lying around is not one to leave to
    // chance. Cleared explicitly, and flushed before the pixels are read back.
    context?.cgContext.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Ground, full bleed. Ink, so the flanges drawn on it are the light shape and survive a
    // darkened ground — see the note at the top.
    ink.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    // The structural frame — the system's 2 pt rule, scaled. Light, so the tile still has an edge
    // when the Dock behind it is dark.
    let border = max(1, (s * 0.055).rounded())
    ground.setFill()
    NSRect(x: 0, y: 0, width: s, height: border).fill()
    NSRect(x: 0, y: s - border, width: s, height: border).fill()
    NSRect(x: 0, y: 0, width: border, height: s).fill()
    NSRect(x: s - border, y: 0, width: border, height: s).fill()

    // Two flanges and the filament wound between them.
    //
    // Proportions matter more than they look: thin flanges with a short core read as the letter
    // "H" rather than a spool. The flanges are heavy and the wound filament nearly fills the gap
    // between them, leaving only a sliver of ground top and bottom — a full spool, not a letter.
    let flangeWidth  = (s * 0.155).rounded()
    let flangeTop    = (s * 0.215).rounded()
    let flangeHeight = s - flangeTop * 2
    let leftX        = (s * 0.205).rounded()
    let rightX       = s - leftX - flangeWidth

    ground.setFill()
    NSRect(x: leftX,  y: flangeTop, width: flangeWidth, height: flangeHeight).fill()
    NSRect(x: rightX, y: flangeTop, width: flangeWidth, height: flangeHeight).fill()

    let coreInset = (s * 0.055).rounded()
    accent.setFill()
    NSRect(x: leftX + flangeWidth,
           y: flangeTop + coreInset,
           width: rightX - (leftX + flangeWidth),
           height: flangeHeight - coreInset * 2).fill()

    context?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    // Tagged sRGB before it is encoded.
    //
    // The rep is created in `deviceRGB`, and encoding *that* to PNG is where the icon picked up a
    // colour it was never drawn in: a band along the bottom border rows with its blue channel
    // dropped. It was there all along and nobody saw it, because while the bottom border was ink
    // the corrupted pixels came out near-black; inverting the icon turned the same 66 pixels into a
    // bright yellow stripe. Converting to a known space first is what stops the encoder guessing.
    return rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
}

/// The set of colours a face is allowed to contain, as 8-bit sRGB.
let palette: Set<[Int]> = Set([ground, ink, accent].map { colour -> [Int] in
    let srgb = colour.usingColorSpace(.sRGB)!
    return [Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())]
})

/// Fails rather than writing a face containing a colour the design does not have.
///
/// Deliberately run on the **encoded PNG**, decoded back, not on the bitmap that was drawn. The
/// drawing was never the problem — checking it would have passed while the file on disk had a
/// yellow stripe in it. What ships is the PNG, so the PNG is what is checked.
func verifyEncoded(_ data: Data, size: Int) {
    guard let decoded = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write(Data("make-icon.swift: \(size)px face did not decode\n".utf8))
        exit(1)
    }
    for y in 0..<decoded.pixelsHigh {
        for x in 0..<decoded.pixelsWide {
            guard let pixel = decoded.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let rgb = [Int((pixel.redComponent * 255).rounded()),
                       Int((pixel.greenComponent * 255).rounded()),
                       Int((pixel.blueComponent * 255).rounded())]
            // Nearest-within-tolerance, not exact. Decoding a PNG back applies a colour-profile
            // conversion: neutrals move two or three counts and the saturated red moves twenty-four
            // — every time, on every face. Exact matching would fail on that and teach whoever hit
            // it to delete the check.
            //
            // 48 is chosen against both ends. The largest honest drift measured here is 24, and the
            // defect this exists to catch dropped an entire channel — 242 counts. Anywhere in
            // between would do; being an order of magnitude clear of the defect matters more than
            // being tight.
            let nearest = palette.map { entry in
                zip(entry, rgb).map { abs($0 - $1) }.max() ?? 0
            }.min() ?? Int.max
            if nearest > 48 {
                let message = "make-icon.swift: \(size)px face has colour \(rgb) at \(x),\(y), "
                    + "which is \(nearest) counts from anything in the palette\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
        }
    }
}

let workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("spoolworks-icon-\(UUID().uuidString)")
let iconset = workingDirectory.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The eight faces iconutil requires.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2),
                        (128, 1), (128, 2), (256, 1), (256, 2),
                        (512, 1), (512, 2)] {
    let pixels = points * scale
    let rep = drawIcon(size: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(pixels)px\n".utf8))
        exit(1)
    }
    verifyEncoded(data, size: pixels)
    let suffix = scale == 1 ? "" : "@2x"
    try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let icns = outputDir.appendingPathComponent("AppIcon.icns")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: workingDirectory)

let bytes = (try? Data(contentsOf: icns).count) ?? 0
print("wrote \(icns.path) (\(bytes) bytes)")
