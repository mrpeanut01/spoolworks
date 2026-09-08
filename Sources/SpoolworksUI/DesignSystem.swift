import SwiftUI
import AppKit

// MARK: - Theme

/// The app's design tokens.
///
/// Two rules govern everything here, both taken from `SPEC/03-ui.md` §8.3:
///
/// 1. **Semantic first.** Anything that is structural (window fill, sidebar, control chrome,
///    separators, text) comes from AppKit's semantic colours, so light and dark mode, increased
///    contrast and the user's accent colour all work with no extra code. The Windows app hardcodes
///    `#F4F4F4` window fill and `#FFFFFF` sidebar on every form; ported literally that is an
///    unreadable app in Dark Mode.
/// 2. **Brand colours are explicitly paired.** The four literals worth keeping — `#1976D2`
///    accent, `#990000` error, `#CD5C5C` warning, and a success green — are declared as
///    light/dark pairs. The dark variants are lightened so they clear the WCAG AA contrast bar on
///    a dark surface; the light variants are the exact Windows values.
///
/// Colour is never the only carrier of state anywhere in this app: every status uses an SF Symbol
/// and a text label as well (see ``StatusPill``).
enum Theme {

    // MARK: Brand palette

    /// `#1976D2` — the Windows primary accent (`MainForm.cs:43-45`), lightened to `#4A9EEA` on
    /// dark backgrounds where the original fails contrast against `NSColor.windowBackgroundColor`.
    static let accent = Color.pair(light: 0x1976D2, dark: 0x4A9EEA)

    /// `#990000` — the Windows error-toast fill (`Toast.cs:152`). Lightened on dark.
    static let danger = Color.pair(light: 0x990000, dark: 0xFF6B6B)

    /// `#CD5C5C` (IndianRed) — the Windows "soft warning" cue (`UploadForm.cs:72,77`).
    static let warning = Color.pair(light: 0xB4553F, dark: 0xE8A87C)

    /// No Windows equivalent; `MediumSeaGreen` (`MainForm.cs:308`) is the nearest ancestor.
    static let success = Color.pair(light: 0x1E7A3C, dark: 0x5FD08A)

    /// `#333333` — the Windows normal-toast fill (`Toast.cs:37`). Only used as the toast
    /// backdrop in light mode; dark mode uses a lighter neutral so the capsule stays visible.
    static let neutralToast = Color.pair(light: 0x333333, dark: 0xE8E8ED)

    // MARK: Semantic surfaces

    /// Window fill. Replaces the hardcoded `#F4F4F4`.
    static let background = Color(nsColor: .windowBackgroundColor)

    /// Raised content fill (cards, list rows, the hex inspector). Replaces `#FFFFFF`.
    static let surface = Color(nsColor: .controlBackgroundColor)

    /// A recessed well, for read-only dumps and diffs.
    static let surfaceRecessed = Color(nsColor: .underPageBackgroundColor)

    /// Hairline separators. Replaces `SettingsForm`'s underscore-string separator.
    static let separator = Color(nsColor: .separatorColor)

    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)

    // MARK: Geometry

    /// Default corner radius for cards, capsule-free containers and the toast backdrop.
    static let cornerRadius: CGFloat = 10
    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusLarge: CGFloat = 14

    /// Hairline width for card borders.
    static let hairline: CGFloat = 1

    // MARK: Spacing scale

    /// The spacing scale, as an instance so it reads as `Theme.spacing.m`.
    ///
    /// The same values are available as `Theme.Spacing.m` for callers that prefer the type form;
    /// both spellings resolve to one set of constants.
    static let spacing = SpacingScale()

    /// Spacing constants in type form: `Theme.Spacing.l`.
    enum Spacing {
        /// 4 pt — inside a pill, between an icon and its adjacent glyph.
        static let xs: CGFloat = 4
        /// 8 pt — between tightly related controls.
        static let s: CGFloat = 8
        /// 12 pt — the default gap inside a card.
        static let m: CGFloat = 12
        /// 16 pt — between form rows and card sections.
        static let l: CGFloat = 16
        /// 24 pt — page padding.
        static let xl: CGFloat = 24
        /// 32 pt — between major page regions.
        static let xxl: CGFloat = 32
    }

    /// Value form of ``Spacing``, so `Theme.spacing.m` works too.
    struct SpacingScale {
        let xs = Spacing.xs
        let s = Spacing.s
        let m = Spacing.m
        let l = Spacing.l
        let xl = Spacing.xl
        let xxl = Spacing.xxl
    }

    // MARK: Typography

    /// The one deliberate monospace face: UIDs, keys and hex dumps.
    /// Everything else uses the system text styles so Dynamic Type keeps working.
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.caption, design: .monospaced)
    static let monoTitle = Font.system(.title3, design: .monospaced).weight(.medium)

    // MARK: Durations

    /// `Toast.LENGTH_SHORT` (`Toast.cs:35`).
    static let toastShort: TimeInterval = 2.0
    /// `Toast.LENGTH_LONG` (`Toast.cs:36`).
    static let toastLong: TimeInterval = 3.5

    // MARK: Window metrics

    /// The Windows app is a fixed 383 × 657. A fixed-pixel window reads as broken on macOS, so
    /// the port keeps only the *proportions*: a comfortable minimum, a portrait-ish ideal, and no
    /// maximum at all.
    static let windowMinWidth: CGFloat = 620
    static let windowIdealWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 520
    static let windowIdealHeight: CGFloat = 760
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 210
    static let sidebarMaxWidth: CGFloat = 300
}

// MARK: - Appearance-aware colour construction

extension Color {

    /// A colour that resolves to `light` in a light appearance and `dark` in a dark one.
    ///
    /// Built on `NSColor(name:dynamicProvider:)`, which is re-evaluated whenever the effective
    /// appearance changes — including the "Increase contrast" and per-window appearance cases that
    /// a `@Environment(\.colorScheme)` switch inside a `View` would miss.
    static func pair(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// `0xRRGGBB` in the sRGB space. The Windows literals are device sRGB values, so pinning the
    /// space here keeps them the same colour they were on Windows.
    convenience init(rgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

// MARK: - Colour bridging for tag payloads

extension Color {
    /// The colour as an 8-bit sRGB triple.
    ///
    /// Pinned to sRGB before the components are read, which is required for parity: the tag stores
    /// raw sRGB code values and `ColorMatcher` compares them as plain integers
    /// (`SPEC/05-color.md` §8.4). Reading components in the display's colour space would produce a
    /// different hex on a P3 display than on an sRGB one.
    var rgb8: RGB8Components {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        return RGB8Components(r: channel(ns.redComponent),
                              g: channel(ns.greenComponent),
                              b: channel(ns.blueComponent))
    }

    /// Builds a colour from `RRGGBB`, tolerating a leading `#` or the 7-character tag field.
    init?(tagHex: String) {
        let digits = tagHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let rgb: Substring
        switch digits.count {
        case 6: rgb = digits[...]
        case 7: rgb = digits.dropFirst()
        default: return nil
        }
        guard let value = UInt32(rgb, radix: 16) else { return nil }
        self = Color(nsColor: NSColor(rgbHex: value))
    }
}

/// A plain sRGB triple, deliberately independent of `SpoolworksCore.RGB8` so `DesignSystem.swift` has no
/// import cycle with the domain layer. Convert at the boundary.
struct RGB8Components: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    /// Uppercase, no `#` — the exact form written into the tag (`MainForm.cs:710`).
    var hexString: String { String(format: "%02X%02X%02X", r, g, b) }

    /// Relative luminance, used to pick legible foreground text over a swatch.
    var isLight: Bool {
        (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255.0 > 0.6
    }
}

// MARK: - Shared view treatments

extension View {
    /// The standard card treatment: raised surface, hairline border, rounded corners.
    func cardSurface(padding: CGFloat = Theme.Spacing.l) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
            )
    }
}
