import SwiftUI

// MARK: - Buttons

/// The Modernist button, in the package's three variants.
///
/// Two rules from the design guide are enforced here rather than left to call sites:
/// **labels are flush left in a block button** ("a button wider than its label starts the text at
/// the left padding edge, never centered"), and **corners are square**. Hover and pressed states
/// come from the accent ramp, as the guide requires, instead of AppKit's default chrome — which is
/// why every button in this app sets `.buttonStyle(.sw(...))` and none use the system style.
struct SWButtonStyle: ButtonStyle {

    enum Variant {
        /// Solid accent fill. One per screen region: the design uses the accent sparingly.
        case primary
        /// Outlined, for the secondary action beside a primary.
        case secondary
        /// Text only, in the accent. For destructive-but-reversible and tertiary actions.
        case ghost
        /// Accent text *and* an accent border. Same weight as `ghost` in the hierarchy, but drawn
        /// as a control rather than as a link — for an action that should look deliberate to press.
        /// Matches ``SWTag``'s own `.outline`, which is where the name comes from.
        case outline
    }

    var variant: Variant = .secondary
    var size: CGFloat = 12
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 9
    /// Full width with a flush-left label — the design's `.btn-block`.
    var block: Bool = false

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: block ? .infinity : nil,
                   alignment: block ? .leading : .center)
            .background(background(pressed: configuration.isPressed))
            .overlay(
                Rectangle().strokeBorder(borderColor, lineWidth: borderColor == .clear ? 0 : 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return Theme.onAccent
        case .secondary: return Theme.label
        case .ghost, .outline: return Theme.accent
        }
    }

    private var borderColor: Color {
        switch variant {
        case .secondary: return Theme.separator
        case .outline: return Theme.accent
        case .primary, .ghost: return .clear
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary:
            // The guide's pressed state is "one step past the base" on the accent ramp.
            if pressed { return Color.pair(light: 0xAE1800, dark: 0xDD2B0F) }
            if hovering { return Color.pair(light: 0xDD2B0F, dark: 0xFF8A73) }
            return Theme.accent
        case .secondary:
            if pressed { return Theme.label.opacity(0.14) }
            if hovering { return Theme.label.opacity(0.07) }
            return .clear
        case .ghost, .outline:
            if pressed { return Theme.accent.opacity(0.18) }
            if hovering { return Theme.accent.opacity(0.10) }
            return .clear
        }
    }
}

extension ButtonStyle where Self == SWButtonStyle {
    static func sw(_ variant: SWButtonStyle.Variant = .secondary,
                   size: CGFloat = 12,
                   h: CGFloat = 14,
                   v: CGFloat = 9,
                   block: Bool = false) -> SWButtonStyle {
        SWButtonStyle(variant: variant, size: size,
                      horizontalPadding: h, verticalPadding: v, block: block)
    }
}

// MARK: - Tags

/// The small tinted label (`.tag`). Mono palette: the package's `accent-2` reads the same as
/// `accent`, so only three roles are offered rather than the CSS's four.
struct SWTag: View {

    enum Style { case accent, neutral, outline }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: style == .outline ? 1 : 0))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var foreground: Color {
        switch style {
        case .accent: return Color.pair(light: 0x7C1405, dark: 0xFFC4B8)
        case .neutral: return Color.pair(light: 0x444141, dark: 0xD7D3D3)
        case .outline: return Theme.accent
        }
    }

    private var fill: Color {
        switch style {
        case .accent: return Color.pair(light: 0xFFF2EF, dark: 0x3A1F18)
        case .neutral: return Color.pair(light: 0xF8F4F4, dark: 0x2F2C2B)
        case .outline: return .clear
        }
    }

    private var border: Color { style == .outline ? Theme.accent : .clear }
}

// MARK: - Swatch

/// A filament-colour square. Always bordered, so white filament on a white card is still a square
/// rather than a hole.
struct Swatch: View {
    let hex: String
    var size: CGFloat = 18
    var height: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.swatch(hex))
            .frame(width: size, height: height ?? size)
            .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
            .accessibilityLabel("Filament colour \(hex.isEmpty ? "unknown" : hex)")
    }
}

/// The full-width colour bar used inside a CFS slot cell.
struct SwatchBar: View {
    let hex: String
    var height: CGFloat = 36

    var body: some View {
        Rectangle()
            .fill(Color.swatch(hex))
            .frame(height: height)
            .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - Progress

/// The remaining-filament bar: a flat track with an accent fill, no radius, no gradient.
///
/// Turns amber then red as the spool runs down. The design draws every bar in the accent; the
/// colour shift here is an addition, because "low" is the one thing an inventory has to make
/// obvious and a red-on-red system cannot say it with the accent alone. The percentage and the
/// gram figure are always rendered beside it, so colour is never the only signal.
struct RemainingBar: View {
    let percent: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track)
                Rectangle()
                    .fill(fill)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Remaining")
        .accessibilityValue("\(Int(percent.rounded())) percent")
    }

    private var fill: Color {
        if percent < 15 { return Theme.danger }
        if percent < 35 { return Theme.warning }
        return Theme.accent
    }
}

// MARK: - Screen header

/// The kicker-over-title block every screen opens with, plus an optional trailing action.
struct ScreenHeader<Trailing: View>: View {
    let kicker: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(kicker).kicker()
                Text(title).font(Theme.screenTitle).foregroundStyle(Theme.label)
            }
            Spacer(minLength: Theme.Spacing.l)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(kicker: String, title: String) {
        self.init(kicker: kicker, title: title) { EmptyView() }
    }
}

// MARK: - Key/value rows

/// One row of the design's borderless data table: a muted key on the left, a bold value right.
struct DataRow<Value: View>: View {
    let key: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            Spacer(minLength: Theme.Spacing.s)
            value
        }
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }
}

extension DataRow where Value == Text {
    /// The common case: a plain value, optionally in the monospace face used for every identifier.
    init(_ key: String, _ text: String, mono: Bool = false) {
        self.init(key: key) {
            Text(text)
                .font(mono ? Theme.monoCaption : .system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
        }
    }
}

// MARK: - Segmented filter

/// The design's `.seg` control: square, joined cells, the selected one filled with the accent.
///
/// Built on buttons rather than `Picker(.segmented)` because AppKit's segmented control brings its
/// own rounded, tinted chrome that cannot be squared off — and a rounded control is the one thing
/// the Modernist guide forbids outright.
struct SegmentedFilter<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Theme.onAccent : Theme.label)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Theme.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)

                if option.id != options.last?.id {
                    Rectangle().fill(Theme.separator).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
    }
}

// MARK: - Empty state

/// What a screen shows when it has nothing yet. Square, bordered, and it always says what to do
/// next rather than only that something is missing.
struct EmptyPanel: View {
    let kicker: String
    let title: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kicker).kicker()
            Text(title).font(Theme.cardTitle).foregroundStyle(Theme.label)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Theme.Spacing.xl)
    }
}

// MARK: - Window restoration

/// Marks the hosting window as not restorable.
///
/// Materials, Printers and Tag Memory are windows you open to do a job and close again. macOS
/// state restoration reopened whichever was last on screen, so quitting with Printers open meant
/// the app started up showing its own settings, with the main window buried behind them.
///
/// Done per-window rather than by disabling restoration app-wide: the main window's size and
/// position are worth remembering, and `NSQuitAlwaysKeepsWindows` would have thrown that away
/// too. The obvious alternative — registering that default from the app delegate's initialiser —
/// is actively harmful; see the note in `AppDelegate`.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet when this is called.
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.isRestorable = false
    }
}

extension View {
    /// Stops this window being reopened by macOS at the next launch.
    func nonRestorableWindow() -> some View {
        background(NonRestorableWindow().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

// MARK: - Status

/// What a piece of hardware is doing, at a glance.
///
/// Three states, because three is what can be told apart instantly. Anything finer belongs in the
/// text beside the dot, which is always present — colour is never the only carrier of state in
/// this app, so the dot supplements a label rather than replacing one.
enum StatusLevel {
    /// Not reachable, not configured, or failed.
    case offline
    /// Doing something right now: printing, reading, writing, polling.
    case busy
    /// Connected and idle.
    case ready

    var color: Color {
        switch self {
        case .offline: return Theme.danger
        case .busy: return Theme.busy
        case .ready: return Theme.success
        }
    }

    /// Spoken by VoiceOver, so the state is available without seeing the colour.
    var spoken: String {
        switch self {
        case .offline: return "offline"
        case .busy: return "busy"
        case .ready: return "ready"
        }
    }
}

/// A square status indicator. Square, not round — nothing in this system is rounded.
///
/// ## It does not pulse, and that is deliberate
///
/// The first version animated the busy state with `repeatForever`, driven by an `@State` flag
/// toggled from `onAppear`/`onChange`. That livelocked the app. The reader begins life in
/// `.starting`, which maps to `.busy`, so the pulse began at launch; the continuous re-render
/// starved the main actor; the monitor therefore never left `.starting`; so the dot never stopped
/// pulsing. Self-sustaining, and it only bit when a dot was actually busy — which is why an
/// all-green launch looked fine. The visible symptoms were a header stuck on "none configured"
/// and "starting…", a catalogue reporting 0 materials, and no CFS poll: everything asynchronous
/// frozen while the synchronous work had plainly run.
///
/// Colour carries the state. There is a label beside every dot, so nothing is lost.
struct StatusDot: View {
    let level: StatusLevel
    var size: CGFloat = 9

    var body: some View {
        Rectangle()
            .fill(level.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
