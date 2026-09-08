import SwiftUI
import SpoolworksCore

// MARK: - One swatch

/// A single offered colour, and where the offer came from.
///
/// The hex is always the canonical 6-digit uppercase `RRGGBB` form — the same form written into
/// the tag (`RGB8.hexString`) — so a swatch, a recent entry and a decoded record all compare as
/// plain strings.
struct PaletteSwatch: Identifiable, Equatable {

    /// Where a swatch came from. Ordered as the control presents them.
    enum Source: String, Equatable {
        /// `base.colors` on the selected filament, when it holds something other than the
        /// placeholder. See ``PaletteSwatch/catalogue(for:)``.
        case catalogue
        /// The draft's current colour, when no other swatch already offers it.
        case current
        /// A colour this user has actually read off a tag or written to one.
        case recent
        /// A colour Creality actually sells RFID-tagged filament in.
        case creality

        /// The caption above the row. Deliberately a *word*, not a colour cue.
        var caption: String {
            switch self {
            case .catalogue: return "From the catalogue"
            case .current: return "Current"
            case .recent: return "Recently used"
            case .creality: return "Creality filament colours"
            }
        }

        /// Spoken before the colour's name, so a VoiceOver user hears which group a swatch is in
        /// without having to navigate back out to the caption.
        var accessibilityPrefix: String {
            switch self {
            case .catalogue: return "Catalogue colour, "
            case .current: return "Current colour, "
            case .recent: return "Recently used, "
            case .creality: return "Creality "
            }
        }
    }

    /// `RRGGBB`, uppercase, no `#`.
    let hex: String
    let source: Source
    /// The product name, for swatches that have one of their own.
    ///
    /// Only the Creality group sets this. Everything else is named by ``ColorMatcher`` at display
    /// time, because there is nothing else to call an arbitrary colour off a tag. A branded colour
    /// is the opposite case: Creality's Blue is *Blue*, and labelling it with the nearest of
    /// 31,861 generic names would be actively misleading.
    var name: String? = nil

    /// Unique per row: the same hex legitimately appears in two groups (a recently used colour
    /// that is also in the curated palette), and each is its own button.
    var id: String { "\(source.rawValue)-\(hex)" }

    /// Built through ``Color/init(tagHex:)``, which pins the colour to sRGB — the same space
    /// ``Color/rgb8`` reads back out. A swatch therefore round-trips to the exact bytes it shows,
    /// on a P3 display as much as on an sRGB one.
    var color: Color { Color(tagHex: hex) ?? .gray }

    /// Whether a dark glyph reads better on this swatch than a light one.
    var isLight: Bool {
        guard let value = UInt32(hex, radix: 16) else { return false }
        return RGB8Components(r: UInt8((value >> 16) & 0xFF),
                              g: UInt8((value >> 8) & 0xFF),
                              b: UInt8(value & 0xFF)).isLight
    }

    /// Canonicalises anything hex-shaped: `#rrggbb`, `rrggbb`, and the 7-character tag colour
    /// field `0RRGGBB` (whose leading nibble the tag format never uses — see `RGB8.tagColorField`).
    static func normalisedHex(_ raw: String) -> String? {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 7, digits.hasPrefix("0") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits.uppercased()
    }

    // MARK: Sources

    /// The six colours Creality actually sells RFID-tagged Hyper PLA in.
    ///
    /// **Provenance.** The *names* are Creality's own, from their official RFID Hyper PLA product
    /// page — which is why they are carried on the swatch rather than resolved through
    /// ``ColorMatcher``. The *hex values* are colorimeter measurements of printed swatches,
    /// published by filamentcolors.xyz. Measured print, not marketing art: that is why Black reads
    /// as `#3C3C3D` and White as `#DEE4E1` rather than `#000000` and `#FFFFFF`. Those are correct
    /// values, not rounding errors, and they are what the spool actually looks like.
    ///
    /// Nothing upstream is being ported here. The Windows app has no filament colour list at all:
    /// its picker is a plain Win32 `ColorDialog` over arbitrary RGB (`MainForm.cs:698-712`), and
    /// its `colors.db` is the 31,861-name generic table from meodai/color-names, used only to put
    /// a placeholder hint in the Spoolman dialog (`SmDialog.cs:58-69`).
    static let creality: [PaletteSwatch] = [
        PaletteSwatch(hex: "3C3C3D", source: .creality, name: "Black"),
        PaletteSwatch(hex: "DEE4E1", source: .creality, name: "White"),
        PaletteSwatch(hex: "838484", source: .creality, name: "Gray"),
        PaletteSwatch(hex: "0087BE", source: .creality, name: "Blue"),
        PaletteSwatch(hex: "C63D44", source: .creality, name: "Red"),
        // UNVERIFIED. No measured swatch for Creality's yellow could be found; #F2C300 is a
        // plausible stand-in, not a measurement. Do not cite it as data — replace it if a
        // colorimeter reading ever turns up.
        PaletteSwatch(hex: "F2C300", source: .creality, name: "Yellow")
    ]

    /// The filament's own colour, when the database carries a real one.
    ///
    /// Every record in the shipped 98-filament database has exactly one `base.colors` entry and it
    /// is always `#ffffff` or `#000000` — a placeholder, which is why the Windows app never reads
    /// the field at all. Those two values are therefore skipped: they say nothing about the
    /// filament, and both are already offered by the curated palette. Anything else is taken at
    /// face value and shown first.
    static func catalogue(for filament: Filament?) -> PaletteSwatch? {
        guard let filament else { return nil }
        for raw in filament.base.colors {
            guard let hex = normalisedHex(raw) else { continue }
            guard hex != "FFFFFF", hex != "000000" else { continue }
            return PaletteSwatch(hex: hex, source: .catalogue)
        }
        return nil
    }
}

// MARK: - Names

/// Nearest-name lookups for palette swatches, resolved once and shared process-wide.
///
/// The lookup is a 31,861-row linear scan — 0.037 ms in a release build but ~14 ms in a debug one
/// (`ColorMatcher` docs). Twenty swatches is a quarter of a second of debug-build main thread, so
/// every scan happens on a detached task and the answers are cached by hex. Names are the only
/// thing that makes a grid of swatches usable with VoiceOver, so they are fetched eagerly rather
/// than on demand.
@MainActor
final class ColorNameCache: ObservableObject {

    static let shared = ColorNameCache()

    @Published private(set) var names: [String: String] = [:]
    private var inFlight: Set<String> = []

    func name(forHex hex: String) -> String? { names[hex] }

    /// Resolves anything not already known or already being looked up.
    func resolve(_ hexes: [String]) async {
        let wanted = hexes.filter { names[$0] == nil && !inFlight.contains($0) }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        let resolved = await Task.detached(priority: .utility) { () -> [String: String] in
            guard let matcher = try? ColorMatcher.shared() else { return [:] }
            var found: [String: String] = [:]
            for hex in wanted {
                if let name = try? matcher.nearestName(forHex: hex) { found[hex] = name }
            }
            return found
        }.value
        inFlight.subtract(wanted)
        for (hex, name) in resolved { names[hex] = name }
    }
}

// MARK: - The field

/// The colour row of the shared tag form: a swatch, its hex and its name.
///
/// Editable, it is a button that opens ``FilamentPalettePopover``. Read-only, it is the same
/// swatch and the same text with nothing to press — the two modes are deliberately the same shape
/// so the form does not change geometry when the mode switch is flipped.
struct FilamentColorField: View {

    /// Optional so "not chosen yet" is representable. A placeholder colour here would read as one
    /// that came off a tag.
    @Binding var color: Color?
    var isEditable: Bool
    /// The selected filament's own colour, when the database carries a real one.
    var catalogue: PaletteSwatch?
    /// Most recent first, already de-duplicated and capped by ``TagViewModel``.
    var recents: [PaletteSwatch]
    var creality: [PaletteSwatch] = PaletteSwatch.creality
    /// The brand currently chosen on the form, so the manufacturer list opens on it.
    var brand: String = ""

    @ObservedObject private var nameCache = ColorNameCache.shared
    @State private var isShowingPalette = false

    private var hex: String { color?.rgb8.hexString ?? "" }
    private var name: String? { hex.isEmpty ? nil : nameCache.name(forHex: hex) }

    var body: some View {
        Group {
            if isEditable {
                Button {
                    isShowingPalette = true
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        summary
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(Theme.secondaryLabel)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Choose a filament colour, or open the colour wheel under Custom…")
                .accessibilityLabel("Colour, \(spokenValue)")
                .accessibilityHint("Opens the colour palette")
                .accessibilityAddTraits(.isButton)
                .popover(isPresented: $isShowingPalette, arrowEdge: .bottom) {
                    FilamentPalettePopover(color: $color,
                                           brand: brand,
                                           catalogue: catalogue,
                                           recents: recents,
                                           creality: creality)
                }
            } else {
                summary
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Colour, \(spokenValue)")
            }
        }
        .task(id: hex) { if !hex.isEmpty { await nameCache.resolve([hex]) } }
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let color {
                ColorSwatch(color: color, hex: hex)
                    .accessibilityHidden(true)
                if let name {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
            } else {
                // An empty well, not a colour. The distinction is the whole point: a filled swatch
                // on a screen that has read nothing looks like a value that came off a tag.
                Rectangle()
                    .fill(Theme.surfaceSunken)
                    .frame(width: 22, height: 22)
                    .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
                    .accessibilityHidden(true)
                Text("Not set")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    /// Never the swatch alone: the hex is always spoken, and the name when one is known.
    private var spokenValue: String {
        guard color != nil else { return "not set" }
        guard let name else { return "hex \(hex)" }
        return "\(name), hex \(hex)"
    }
}

// MARK: - The palette

/// Colour selection as *swatches first*, with the full system picker one level deeper.
///
/// The Windows app offers only a `ColorDialog` (`MainForm.cs:698-712`), and the straight port of
/// that — a bare `ColorPicker` — makes picking "the red I always use" a trip through a colour
/// wheel. This puts the colours that are actually plausible for a spool one click away, in
/// priority order: the filament's catalogue colour, the current colour if it is not otherwise on
/// offer, what this user has recently read or written, then Creality's own six RFID filament
/// colours. The colour wheel is still there, unchanged, behind the final `Custom…` row — one level
/// down rather than beside the swatches, so the common case is not competing with the rare one.
struct FilamentPalettePopover: View {

    /// Optional so nothing is shown as selected before a choice is made — a highlighted swatch on
    /// first open would claim the user had already picked it.
    @Binding var color: Color?
    /// The brand chosen on the form, so the manufacturer list opens on it.
    var brand: String = ""
    var catalogue: PaletteSwatch?
    var recents: [PaletteSwatch]
    var creality: [PaletteSwatch] = PaletteSwatch.creality

    @ObservedObject private var nameCache = ColorNameCache.shared
    @Environment(\.dismiss) private var dismiss

    /// The draft colour as the bytes that would be written — via `rgb8`, so the comparison against
    /// a swatch is made on the same sRGB quantisation the tag receives.
    /// Empty until a colour is chosen, so no swatch matches and none is marked selected.
    private var currentHex: String { color?.rgb8.hexString ?? "" }

    private var groups: [(source: PaletteSwatch.Source, swatches: [PaletteSwatch])] {
        var result: [(PaletteSwatch.Source, [PaletteSwatch])] = []
        if let catalogue { result.append((.catalogue, [catalogue])) }
        if !offered.contains(currentHex) {
            result.append((.current, [PaletteSwatch(hex: currentHex, source: .current)]))
        }
        if !recents.isEmpty { result.append((.recent, recents)) }
        if !creality.isEmpty { result.append((.creality, creality)) }
        return result
    }

    /// Every hex the palette already shows, so the current colour is only added when it is not
    /// among them.
    private var offered: Set<String> {
        var hexes = Set(creality.map(\.hex))
        hexes.formUnion(recents.map(\.hex))
        if let catalogue { hexes.insert(catalogue.hex) }
        return hexes
    }

    /// Only the swatches that do not carry a name of their own need the table consulted.
    private var lookupHexes: [String] {
        groups.flatMap { $0.swatches }.filter { $0.name == nil }.map(\.hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ForEach(groups, id: \.source) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(group.source.caption)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryLabel)
                    // A plain row, not a grid. Every group is small and bounded — one catalogue
                    // colour, one current, at most eight recents, six Creality — so nothing ever
                    // needs to wrap.
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(group.swatches) { swatch in
                            SwatchButton(swatch: swatch,
                                         name: swatch.name ?? nameCache.name(forHex: swatch.hex),
                                         isSelected: swatch.hex == currentHex) {
                                color = swatch.color
                                dismiss()
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(group.source.caption)
            }

            Divider()

            ManufacturerSwatchPicker(brand: brand, currentHex: currentHex) { hex in
                color = Color(tagHex: hex)
                dismiss()
            }

            Divider()

            // The escape hatch: the system colour panel — wheel, sliders, eyedropper — exactly the
            // control that used to sit on the main form. It stays open behind the popover, so the
            // popover is not dismissed when it is used.
            ColorPicker("Custom…",
                        selection: Binding(get: { color ?? Color(nsColor: .white) },
                                           set: { color = $0 }),
                        supportsOpacity: false)
                .help("Opens the macOS colour wheel for any colour at all")
                .accessibilityHint("Opens the system colour wheel")
        }
        .padding(Theme.Spacing.l)
        .frame(minWidth: 300)
        .task(id: lookupHexes.joined()) {
            await nameCache.resolve(lookupHexes)
        }
    }
}

// MARK: - One button

/// A swatch that is a real button, with a real name.
///
/// Colour is never the only carrier of information here: selection is a ring **and** a checkmark,
/// and the accessibility label and tooltip both lead with the colour's name. A grid of unlabelled
/// coloured rectangles is unusable with VoiceOver, and the names are free — the same table the tag
/// screen already names colours from.
private struct SwatchButton: View {
    let swatch: PaletteSwatch
    let name: String?
    let isSelected: Bool
    let action: () -> Void

    private var size: CGFloat { 26 }

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                .fill(swatch.color)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                        .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                        .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        // Drawn against the swatch itself, so the glyph flips rather than
                        // disappearing on white or black filament.
                        .foregroundStyle(swatch.isLight ? Color.black : Color.white)
                        .opacity(isSelected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// "Cerulean · #1976D2", falling back to the hex alone until the name lookup lands.
    private var tooltip: String {
        guard let name else { return "#\(swatch.hex)" }
        return "\(name) · #\(swatch.hex)"
    }

    private var accessibilityLabel: String {
        let named = name ?? "Unnamed colour"
        return "\(swatch.source.accessibilityPrefix)\(named), hex \(swatch.hex)"
    }
}


// MARK: - Manufacturer colours

/// The colours a given maker actually sells, from measured swatches.
///
/// Two levels, because 2,258 swatches will not fit in a popover and a flat list of one maker's 80
/// is still a wall. The basic colour narrows it first — which is also how people ask for filament
/// ("a grey PETG"), rather than by the maker's name for it.
private struct ManufacturerSwatchPicker: View {

    let brand: String
    let currentHex: String
    let pick: (String) -> Void

    /// Loaded once for the process. 2,258 records is a fraction of a millisecond to index, but
    /// re-reading a 210 KB file every time a popover opens would be silly.
    private static let library = FilamentSwatchLibrary.bundled()

    @State private var manufacturer: String = ""
    @State private var basic: BasicColor = .black

    private var swatches: [FilamentSwatch] {
        Self.library.swatches(for: manufacturer, basic: basic)
    }

    var body: some View {
        if Self.library.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Manufacturer colours")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryLabel)

                HStack(spacing: Theme.Spacing.s) {
                    Picker("", selection: $manufacturer) {
                        ForEach(Self.library.manufacturers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)

                    Picker("", selection: $basic) {
                        ForEach(BasicColor.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                }

                if swatches.isEmpty {
                    Text("No \(basic.title.lowercased()) swatch measured for \(manufacturer).")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                        .padding(.vertical, Theme.Spacing.xs)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(swatches) { swatch in
                                Button { pick(swatch.hex) } label: {
                                    HStack(spacing: Theme.Spacing.s) {
                                        Swatch(hex: swatch.hex, size: 16)
                                        Text(swatch.label)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if swatch.hex == currentHex {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(Theme.accent)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(swatch.hex)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }

                // Provenance, because these are measurements and the number matters: they are
                // readings of printed swatches, so they are a shade off the raw spool and further
                // off whatever a factory tag encodes.
                Text("Measured swatches from filamentcolors.xyz")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
            .onAppear {
                if manufacturer.isEmpty {
                    manufacturer = Self.library.manufacturer(matching: brand)
                        ?? Self.library.manufacturer(matching: "Creality")
                        ?? Self.library.manufacturers.first ?? ""
                }
            }
            .onChange(of: brand) { _, new in
                if let match = Self.library.manufacturer(matching: new) { manufacturer = match }
            }
        }
    }
}
