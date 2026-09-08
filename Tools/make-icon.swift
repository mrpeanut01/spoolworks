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
// The mark is a spool seen side-on: two ink flanges with the filament between them in the accent.
// Deliberately square — Modernist's first rule is that nothing is rounded, and a flat square reads
// as distinct in a Dock full of squircles. It has to survive 16 pt, so it is three rectangles and
// nothing else.

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
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Ground, full bleed.
    ground.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()

    // The structural frame — the system's 2 pt rule, scaled.
    let border = max(1, (s * 0.055).rounded())
    ink.setFill()
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

    ink.setFill()
    NSRect(x: leftX,  y: flangeTop, width: flangeWidth, height: flangeHeight).fill()
    NSRect(x: rightX, y: flangeTop, width: flangeWidth, height: flangeHeight).fill()

    let coreInset = (s * 0.055).rounded()
    accent.setFill()
    NSRect(x: leftX + flangeWidth,
           y: flangeTop + coreInset,
           width: rightX - (leftX + flangeWidth),
           height: flangeHeight - coreInset * 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
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
