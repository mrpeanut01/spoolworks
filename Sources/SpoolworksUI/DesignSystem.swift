import SwiftUI
import AppKit

// MARK: - Theme

/// The app's design tokens, retuned to the **Modernist** system from the Spoolworks design
/// package (`Spoolworks.dc.html` plus `_ds/modernist-*/styles.css`).
///
/// Modernist is flat and architectural: a single red accent on a warm light ground, **zero corner
/// radius anywhere**, strong 2 pt rules doing all the organising, and labels flush left — including
/// inside buttons wider than their text. Nothing floats and nothing is decorated.
///
/// ## What was taken from the package, and what was judged
///
/// The package is light-only and specifies fixed hex values. Two deliberate departures, both
/// within the latitude the tool owner gave ("best judgement on the colours, appealing and clear"):
///
/// 1. **Dark mode exists.** A macOS app with no dark appearance reads as broken, and the package
///    has no dark palette to copy. Every brand colour below is a light/dark pair; the light halves
///    are the package's literals, the dark halves are derived on the same warm neutral axis and
///    lightened until they clear WCAG AA on the dark ground.
/// 2. **Text colours stay semantic.** ``label``, ``secondaryLabel`` and ``tertiaryLabel`` come from
///    AppKit rather than the package, so Increase Contrast and the accessibility appearances keep
///    working. The *grounds* are explicit brand colours because the warm ground is the system's
///    identity; the ink on them is the system's business.
///
/// Colour is never the only carrier of state: every status also has an SF Symbol and a text label.
enum Theme {

    // MARK: Brand palette

    /// `#EC3013` — the Modernist accent, and the only chromatic colour in the system. Carries the
    /// primary action, the progress fill, the active-nav rule and small emphasis. Lightened on
    /// dark, where the light value sits at 2.6:1 against the dark ground.
    static let accent = Color.pair(light: 0xEC3013, dark: 0xF7492A)

    /// Errors. The accent is itself red, so danger is pushed deeper to stay distinguishable from
    /// "this is merely the primary button".
    static let danger = Color.pair(light: 0xAE1800, dark: 0xFF8A73)

    /// `--color-accent-2-600`, the warm secondary the package derives.
    static let warning = Color.pair(light: 0xC94B39, dark: 0xE8A87C)

    /// No Modernist equivalent — the system is mono. Chosen on the same perceptual axis so a
    /// success pill sits at the same visual weight as an accent one.
    static let success = Color.pair(light: 0x1E7A3C, dark: 0x5FD08A)

    /// The toast backdrop. The design's toast is a solid ink capsule with a red square and white
    /// text, so this is the ink colour rather than a neutral grey.
    static let neutralToast = Color.pair(light: 0x201E1D, dark: 0xE8E5E3)

    // MARK: Grounds

    /// `--color-bg` #F3F2F2. The window fill.
    static let background = Color.pair(light: 0xF3F2F2, dark: 0x171615)

    /// Card fill. The design puts content cards on pure white over the warm ground.
    static let surface = Color.pair(light: 0xFFFFFF, dark: 0x232120)

    /// `--color-neutral-100` — the tinted panel behind the sidebar, the detail rail and the
    /// "decoded from tag" boxes.
    static let surfaceRecessed = Color.pair(light: 0xF8F4F4, dark: 0x1D1B1A)

    /// A second tinted step, for a panel sitting *on* a card.
    static let surfaceSunken = Color.pair(light: 0xEAE9E9, dark: 0x2A2827)

    // MARK: Rules

    /// The hairline: `--color-divider` at 1 pt, for rows inside a card.
    static let separator = Color.pair(light: 0xB4B0AF, dark: 0x413E3C)

    /// The **structural** rule — 2 pt, solid ink. This is the system's signature: card borders,
    /// section dividers and the frame around the whole app are all this at ``ruleWidth``.
    /// Inverted rather than lightened on dark, where solid paper-white rules would glare.
    static let rule = Color.pair(light: 0x201E1D, dark: 0x7E7876)

    // MARK: Text

    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)

    /// The kicker / small-caps heading colour — `--color-neutral-600`.
    static let kickerLabel = Color.pair(light: 0x7D7979, dark: 0x9B9797)

    /// Text sitting on an accent fill — light in **both** appearances.
    ///
    /// It was briefly inverted on dark, which put dark text on the red button and broke the one
    /// thing the design is most recognisable for: white on red. A slightly punchier dark accent
    /// (above) buys back the contrast that inversion was there to provide.
    static let onAccent = Color.pair(light: 0xF8F7F6, dark: 0xFBF7F5)

    /// The active sidebar row: ink in light, paper in dark. The design inverts the row outright
    /// rather than tinting it, and that inversion is what makes the sidebar readable at a glance.
    static let navActiveFill = Color.pair(light: 0x201E1D, dark: 0xE8E5E3)
    static let navActiveLabel = Color.pair(light: 0xFFFFFF, dark: 0x201E1D)
    static let navHoverFill = Color.pair(light: 0xEAE7E7, dark: 0x2A2827)

    /// Progress-bar track — `--color-neutral-300`.
    static let track = Color.pair(light: 0xD7D3D3, dark: 0x3A3736)

    // MARK: Geometry

    /// **Zero, deliberately.** `--radius-md` is 0 across the whole Modernist system; the guide's
    /// first "Don't" is *"do not round a corner anywhere"*. Kept as a named token rather than
    /// deleted, so the intent survives the next person who wonders where the radius went.
    static let cornerRadius: CGFloat = 0
    static let cornerRadiusSmall: CGFloat = 0
    static let cornerRadiusLarge: CGFloat = 0

    /// 1 pt — the in-card row divider.
    static let hairline: CGFloat = 1
    /// 2 pt — the structural rule: every card border, panel edge and section divider.
    static let ruleWidth: CGFloat = 2

    // MARK: Spacing scale

    /// The spacing scale, as an instance so it reads as `Theme.spacing.m`.
    static let spacing = SpacingScale()

    /// Spacing constants in type form: `Theme.Spacing.l`. These are the package's `--space-*`
    /// values exactly (4 / 8 / 12 / 16 / 24 / 32).
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    struct SpacingScale {
        let xs = Spacing.xs
        let s = Spacing.s
        let m = Spacing.m
        let l = Spacing.l
        let xl = Spacing.xl
        let xxl = Spacing.xxl
    }

    // MARK: Typography

    /// The design sets everything in **Archivo**, a Google font the package pulls over the network.
    /// Nothing is bundled here and an app should not fetch a webfont at launch, so the system face
    /// stands in at matching weights: Archivo's 800 headings map to `.heavy`, its 600 UI text to
    /// `.semibold`. The tight tracking carries most of the character.
    static let screenTitle = Font.system(size: 26, weight: .heavy)
    /// The identify hero's `h2`.
    static let heroTitle = Font.system(size: 28, weight: .heavy)
    static let cardTitle = Font.system(size: 17, weight: .bold)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)

    /// The uppercase micro-heading above almost every title (`.sw-hd`): 10 pt, heavy, wide
    /// tracking. Apply with ``SwiftUI/View/kicker()``.
    static let kickerFont = Font.system(size: 10, weight: .bold)

    /// Monospace, for UIDs, keys, hex dumps, serials and every figure in a table column.
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoCaption = Font.system(size: 12, design: .monospaced)
    static let monoTitle = Font.system(.title3, design: .monospaced).weight(.medium)

    /// The big remaining-percentage figure on the detail rail and the identify hero.
    static func monoFigure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .monospaced)
    }

    // MARK: Durations

    static let toastShort: TimeInterval = 2.0
    static let toastLong: TimeInterval = 3.5

    // MARK: Window metrics

    /// The design is a fixed 1400 pt canvas: a 230 pt sidebar plus content, and Inventory adds a
    /// 400 pt detail rail on top of that. The minimum keeps the widest screen from collapsing;
    /// there is no maximum.
    static let windowMinWidth: CGFloat = 1080
    static let windowIdealWidth: CGFloat = 1400
    static let windowMinHeight: CGFloat = 680
    static let windowIdealHeight: CGFloat = 900

    /// The design's sidebar is exactly 230 pt and does not resize.
    static let sidebarWidth: CGFloat = 230
    static let sidebarMinWidth: CGFloat = 230
    static let sidebarIdealWidth: CGFloat = 230
    static let sidebarMaxWidth: CGFloat = 230
    /// The Inventory screen's right-hand detail rail.
    static let detailRailWidth: CGFloat = 400
}

// MARK: - Appearance-aware colour construction

extension Color {

    /// A colour that resolves to `light` in a light appearance and `dark` in a dark one.
    ///
    /// Built on `NSColor(name:dynamicProvider:)`, which is re-evaluated whenever the effective
    /// appearance changes — including the per-window and Increase Contrast cases a
    /// `@Environment(\.colorScheme)` switch inside a `View` would miss.
    static func pair(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? dark : light)
        })
    }

    /// A swatch colour that never silently renders as black. An unparseable hex falls back to the
    /// sunken surface, which reads as "no colour" rather than "black filament".
    static func swatch(_ hex: String) -> Color {
        Color(tagHex: hex) ?? Theme.surfaceSunken
    }
}

extension NSColor {
    /// `0xRRGGBB` in the sRGB space. The design's literals are sRGB, so pinning the space keeps
    /// them the colour they were in the browser.
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
    /// (`SPEC/05-color.md` 8.4). Reading components in the display's colour space would produce a
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

/// A plain sRGB triple, deliberately independent of `SpoolworksCore.RGB8` so `DesignSystem.swift`
/// has no import cycle with the domain layer. Convert at the boundary.
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

    /// The standard card: white fill, a 2 pt ink border, square corners. Everything the design
    /// draws as a box is this.
    func cardSurface(padding: CGFloat = Theme.Spacing.l,
                     fill: Color = Theme.surface) -> some View {
        self
            .padding(padding)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
    }

    /// A tinted panel — the detail rail, the "decoded from tag" box.
    func panelSurface(padding: CGFloat = Theme.Spacing.l) -> some View {
        cardSurface(padding: padding, fill: Theme.surfaceRecessed)
    }

    /// The design's `.sw-hd` micro-heading: 10 pt heavy, uppercase, wide tracking, muted.
    func kicker() -> some View {
        self
            .font(Theme.kickerFont)
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Theme.kickerLabel)
    }
}

// MARK: - Structural rules

/// The 2 pt horizontal rule separating major regions (`.hr`).
struct Rule: View {
    var width: CGFloat = Theme.ruleWidth
    var color: Color = Theme.rule
    var body: some View { Rectangle().fill(color).frame(height: width) }
}

/// A 1 pt in-card row divider.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: Theme.hairline) }
}

/// A vertical 1 pt divider, for the header status strip.
struct VRule: View {
    var height: CGFloat = 28
    var body: some View { Rectangle().fill(Theme.separator).frame(width: 1, height: height) }
}
