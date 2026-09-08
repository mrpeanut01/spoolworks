import SwiftUI
import SpoolworksCore

/// The stock list, with a detail rail pinned to the right.
///
/// The table is hand-built from stacks rather than SwiftUI's `Table`. `Table` supplies AppKit's own
/// header chrome, alternating row fills and rounded selection — none of which can be squared off
/// or restyled, and all of which the Modernist system forbids. The cost is that sorting and column
/// resizing have to be written by hand if they are ever wanted; the benefit is a table that looks
/// like the design instead of approximately like it.
struct InventoryView: View {
    @ObservedObject var model: InventoryViewModel
    @ObservedObject var env: AppEnvironment
    /// Column and rail widths, dragged by the user and remembered. Owned here so the header, every
    /// row and the splitter read one source — the fixed `Column` constants this replaced existed
    /// for the same reason, and drifting apart is still the failure it prevents.
    @StateObject private var layout = InventoryLayout()

    var body: some View {
        HStack(spacing: 0) {
            list
            // The rule between the panes is the splitter. Dragging it right narrows the rail, so
            // the delta is subtracted: the rail's leading edge moving right takes width off it.
            ResizeHandle(axis: .rail) { delta in
                layout.setRailWidth(layout.railWidth - delta)
            }
            InventoryDetailRail(model: model, env: env)
                .frame(width: layout.railWidth)
        }
        .sheet(item: $model.retireTarget) { spool in
            RetireDialog(spool: spool,
                         confirm: { model.confirmRetire(spool) },
                         cancel: { model.retireTarget = nil })
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(kicker: model.summary, title: "Inventory") {
                Button("Log incoming") { env.sidebarSelection = .intake }
                    .buttonStyle(.sw(.primary))
            }
            .padding(.bottom, Theme.Spacing.l)

            ScrollView(.horizontal) {
                SegmentedFilter(options: model.filterOptions,
                                title: \.title,
                                selection: $model.filter)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Theme.Spacing.m)

            if let error = model.storageError {
                InlineFailure(text: error).padding(.bottom, Theme.Spacing.m)
            }

            if model.isEmpty {
                EmptyPanel(kicker: "Nothing in stock",
                           title: "No spools logged yet",
                           message: "Use Intake to scan a Creality tag, or to describe a third-party spool and tag it. Spools already loaded in the printer's CFS are added automatically the first time Spoolworks polls it.")
                Spacer()
            } else if model.rows.isEmpty {
                EmptyPanel(kicker: model.filter.title,
                           title: "No spools match this filter",
                           message: "Every spool you own is still here — switch back to All to see them.")
                Spacer()
            } else {
                table
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        VStack(spacing: 0) {
            InventoryHeaderRow(layout: layout)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { spool in
                        InventoryRow(spool: spool,
                                     layout: layout,
                                     isSelected: model.selected?.id == spool.id) {
                            model.selectedID = spool.id
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Table rows

/// The grab area between two columns, and the splitter between the table and the rail.
///
/// Drawn as the 1 pt or 2 pt rule the design already asks for, with a much wider **invisible** hit
/// area on top: a 2 pt target is a target you miss, and widening the visible rule to make it
/// grabbable would put a heavy line through the middle of the table.
///
/// The cursor is set on hover rather than left as an arrow — without it a handle is undiscoverable,
/// because there is nothing to see. `NSCursor.push`/`pop` is paired strictly with the hover
/// transition; the alternative, `set()`, leaves a resize cursor behind on whatever the pointer
/// moves to next.
private struct ResizeHandle: View {

    enum Axis {
        /// Between two columns: a hairline.
        case column
        /// Between the table and the detail rail: the 2 pt rule the design draws there.
        case rail

        var thickness: CGFloat { self == .rail ? Theme.ruleWidth : Theme.hairline }
        var colour: Color { self == .rail ? Theme.rule : Theme.separator }
        /// Total grab width, centred on the rule.
        var grabWidth: CGFloat { 11 }
    }

    let axis: Axis
    /// Horizontal movement since the last callback, in points. Positive is rightward.
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(axis.colour)
            .frame(width: axis.thickness)
            .frame(maxHeight: .infinity)
            // The hit area, not the line. `contentShape` is what makes the transparent overhang
            // grabbable — without it the gesture only lands on the drawn pixels.
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: axis.grabWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        guard hovering != isHovering else { return }
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                // Reported as a delta rather than an absolute, so the caller does
                                // not have to know where the handle started. `translation` is
                                // cumulative for the gesture, hence the running subtraction.
                                onDrag(value.translation.width - lastTranslation)
                                lastTranslation = value.translation.width
                            }
                            .onEnded { _ in lastTranslation = 0 }
                    )
            }
            .accessibilityHidden(true)
    }
}

private struct InventoryHeaderRow: View {
    @ObservedObject var layout: InventoryLayout

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            // A fixed height as well as a width. `Color` is a flexible view: constrained on one
            // axis only it expands on the other, which stretched this header row to fill the pane
            // and pushed the table halfway down the screen.
            Color.clear.frame(width: InventoryLayout.swatchWidth, height: 1)
            Text("Filament").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(InventoryLayout.Column.allCases, id: \.self) { column in
                // The handle sits on the column's *leading* edge and sizes the column to its left.
                // For the first one that is `Filament`, which is flexible — so dragging there
                // resizes `Type` inversely, and the effect is still "the thing on the left grew".
                ResizeHandle(axis: .column) { delta in
                    layout.setWidth(layout.width(column) - delta, for: column)
                }
                Text(title(column))
                    .frame(width: layout.width(column),
                           alignment: column == .remaining ? .trailing : .leading)
            }
        }
        .kicker()
        .padding(.vertical, Theme.Spacing.s)
        .frame(height: 26)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
        }
        // The way back. Widths are clamped so they cannot be dragged into an unusable state, but
        // "usable" is not the same as "what I wanted", and re-dragging six columns by hand to undo
        // one bad afternoon is not a reasonable ask.
        .contextMenu {
            Button("Reset column and rail widths") { layout.reset() }
        }
    }

    private func title(_ column: InventoryLayout.Column) -> String {
        switch column {
        case .type: return "Type"
        case .serial: return "Serial"
        case .location: return "Location"
        case .remaining: return "Remaining"
        case .tag: return "Tag"
        }
    }
}

private struct InventoryRow: View {
    let spool: Spool
    @ObservedObject var layout: InventoryLayout
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.s) {
                Swatch(hex: spool.colorHex)
                    .frame(width: InventoryLayout.swatchWidth, alignment: .leading)

                Text(spool.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                gap
                Text(spool.materialType.isEmpty ? "—" : spool.materialType)
                    .font(.system(size: 14))
                    .frame(width: layout.width(.type), alignment: .leading)

                gap
                Text(spool.serialLabel)
                    .font(Theme.monoCaption)
                    .frame(width: layout.width(.serial), alignment: .leading)

                gap
                Text(spool.location.description)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .frame(width: layout.width(.location), alignment: .leading)

                gap
                HStack(spacing: 5) {
                    // Low stock is called out in words as well as colour — the row is the only
                    // place a spool's condition is visible while scanning the list.
                    if spool.isLow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(spool.remainingPercent < 15 ? Theme.danger : Theme.warning)
                    }
                    Text(spool.remainingLabel)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .frame(width: layout.width(.remaining), alignment: .trailing)

                gap
                Text(spool.tagSource.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: layout.width(.tag), alignment: .leading)
            }
            .foregroundStyle(Theme.label)
            .padding(.vertical, Theme.Spacing.s)
            .background(fill)
            .overlay(alignment: .leading) {
                Rectangle().fill(isSelected ? Theme.accent : .clear).frame(width: 3)
            }
            .overlay(alignment: .bottom) { Hairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spool.label), \(spool.materialType), \(spool.remainingLabel) remaining, \(spool.location.description)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Stands in for the header's drag handle, so a row's columns line up with the header's.
    /// A hairline wide, matching what the handle draws — the handle's grab area overhangs it and
    /// costs no layout width.
    private var gap: some View {
        Color.clear.frame(width: Theme.hairline, height: 1)
    }

    private var fill: Color {
        if isSelected { return Theme.accent.opacity(0.10) }
        return hovering ? Theme.label.opacity(0.04) : .clear
    }
}

// MARK: - Detail rail

private struct InventoryDetailRail: View {
    @ObservedObject var model: InventoryViewModel
    @ObservedObject var env: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Spool detail").kicker().padding(.bottom, 10)

                if let spool = model.selected {
                    content(spool)
                } else {
                    Text("Select a spool to see its history.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
        .background(Theme.surfaceRecessed)
    }

    @ViewBuilder
    private func content(_ spool: Spool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Swatch(hex: spool.colorHex, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(spool.label)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(spool.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Spacing.l)

        HStack(alignment: .lastTextBaseline) {
            Text(spool.remainingLabel).font(Theme.monoFigure(30)).foregroundStyle(Theme.label)
            Spacer()
            Text(spool.remainingGramsLabel)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .padding(.bottom, 6)

        RemainingBar(percent: spool.remainingPercent, height: 10).padding(.bottom, 6)

        Text(spool.remainingSource.isEmpty ? "no reading yet" : spool.remainingSource)
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.kickerLabel)
            .padding(.bottom, 18)

        Rule().padding(.bottom, 14)

        LocationControl(spool: spool, model: model).padding(.bottom, 14)

        VStack(spacing: 0) {
            TypeRow(spool: spool, model: model, materials: env.materialsModel)
            DataRow("Serial", spool.serialLabel, mono: true)
            DataRow("Filament ID", spool.filamentIdLabel, mono: true)
            DataRow("Vendor ID", spool.vendorIdLabel, mono: true)
            DataRow("Tag", spool.tagSource.description)
            DataRow("Intake", spool.intakeDate.formatted(date: .abbreviated, time: .omitted))
        }
        .padding(.bottom, 18)

        Text("Usage log").kicker().padding(.bottom, 10)
        UsageLog(entries: spool.usage).padding(.bottom, 18)

        RemainingControl(spool: spool, model: model).padding(.bottom, Theme.Spacing.s)

        // No "Read tag to verify" here. It only switched screens, which the sidebar already does,
        // and it read as though it would verify *this* spool when Read / identify simply reads
        // whatever tag is presented.
        Button("Retire spool") { model.retireTarget = spool }
            .buttonStyle(.sw(.ghost, block: true))
    }
}

/// The bordered history list. Shows the most recent entries; a spool polled every 30 s for a year
/// would otherwise render thousands of rows into a 400 pt rail.
private struct UsageLog: View {
    let entries: [UsageEntry]
    private let limit = 12

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Nothing recorded yet.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
            } else {
                ForEach(entries.prefix(limit)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.date.formatted(date: .numeric, time: .shortened))
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.secondaryLabel)
                            .layoutPriority(1)
                        Text(entry.detail)
                            .font(Theme.caption)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(entry.amountLabel)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(entry.deltaGrams < 0 ? Theme.label : Theme.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Hairline() }
                    .accessibilityElement(children: .combine)
                }
                if entries.count > limit {
                    Text("\(entries.count - limit) earlier entries")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
            }
        }
        .background(Theme.surface)
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
    }
}

// MARK: - Retire

/// The design's one-tap retire confirmation: what it removes, what it keeps, no form.
private struct RetireDialog: View {
    let spool: Spool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Retire spool").kicker().padding(.bottom, 8)
            Text(spool.label)
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Theme.label)
                .padding(.bottom, 10)
            Text("Removes serial \(spool.serialLabel) from the stock list. The last reading was \(spool.remainingLabel) — that, and everything else in its usage log, is kept.")
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                Button("Retire", action: confirm)
                    .buttonStyle(.sw(.primary, h: 18, v: 11))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel)
                    .buttonStyle(.sw(.ghost, h: 18, v: 11))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(Theme.background)
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
    }
}

// MARK: - Shared failure strip

/// A storage or transport failure shown in place. Never a toast alone: a toast that has already
/// faded cannot explain why the list is empty.
struct InlineFailure: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08))
        .overlay(Rectangle().strokeBorder(Theme.danger, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}


// MARK: - Correcting what is left

/// Correct the remaining figure by hand — from a set of scales, or as a percentage.
///
/// Not in the design, but the design's own copy asks for it: with no CFS attached it says
/// "weigh-in corrections carry more weight here", and a spool sitting on a shelf has no other way
/// to stay accurate — its last reading is however full it was when it left the printer.
///
/// **One control, two units, one code path.** The percentage edit is a second way of saying the
/// same thing as the weigh-in, not a second mechanism: both call
/// ``InventoryViewModel/adjust(_:toPercent:method:)``, which is what guarantees the usage line the
/// model requires for every change to `remainingPercent`. Adding a separate "set %" affordance
/// somewhere else on the screen was the obvious alternative and was rejected — two places to
/// correct one number is how the two paths end up with different clamping rules, and how a user
/// ends up not knowing which one wrote the line they are reading.
///
/// The weight field asks for **filament** grams rather than gross weight. A spool's core is
/// 150–250 g depending on the maker, and there is nowhere honest to get that number from: it is
/// not on the tag, not in the material database, and not the same across brands. Asking for gross
/// and guessing the core would overstate every corrected spool by roughly a fifth, so the label
/// says which is wanted.
private struct RemainingControl: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    @State private var isOpen = false
    @State private var method: AdjustmentMethod = .weighed
    @State private var entry = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button(isOpen ? "Cancel correction" : "Correct what's left") {
                isOpen.toggle()
                entry = ""
                problem = nil
            }
            .buttonStyle(.sw(.secondary, block: true))
            .accessibilityLabel(isOpen
                                ? "Cancel correcting what is left of \(spool.label)"
                                : "Correct what is left of \(spool.label)")

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    SegmentedFilter(options: AdjustmentMethod.allCases,
                                    title: \.title,
                                    selection: $method)

                    FieldBox(label: fieldLabel, note: fieldNote) {
                        TextField("", text: $entry)
                            .textFieldStyle(.plain)
                            .swInput()
                            .onSubmit(apply)
                            .accessibilityLabel(fieldLabel + ", " + fieldNote)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Button("Apply", action: apply)
                            .buttonStyle(.sw(.primary, size: 12, h: 14, v: 8))
                            .disabled(entry.isEmpty)
                        Text(scaleNote)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    }

                    if let problem {
                        Text(problem)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Not applied. \(problem)")
                    }
                }
                .padding(Theme.Spacing.m)
                .background(Theme.surface)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
                // Switching units mid-edit must not carry the number across: 640 g and 640 % are
                // not the same claim, and the second would simply be refused with no explanation
                // of where the figure came from.
                .onChange(of: method) { _, _ in
                    entry = ""
                    problem = nil
                }
            }
        }
    }

    private var fieldLabel: String {
        method == .weighed ? "Filament remaining" : "Remaining"
    }

    private var fieldNote: String {
        method == .weighed ? "grams, not including the spool" : "percent, 0 to 100"
    }

    private var scaleNote: String {
        method == .weighed
            ? "of \(spool.netWeightGrams) g net"
            : "currently \(spool.remainingLabel) · \(spool.remainingGramsLabel)"
    }

    private func apply() {
        let text = entry.trimmingCharacters(in: .whitespaces)
        switch method {
        case .weighed:
            guard let grams = Int(text) else {
                problem = "Enter a whole number of grams."
                return
            }
            guard model.adjust(spool, toGrams: grams) else {
                problem = "That is more than this spool holds (\(spool.netWeightGrams) g). "
                    + "Weigh the filament only, without the spool it is wound on."
                return
            }
        case .byHand:
            // Accepts a decimal: the CFS reports whole percent but a user reading a half-empty
            // spool off a chart has no reason to be forced to an integer.
            guard let percent = Double(text) else {
                problem = "Enter a percentage."
                return
            }
            guard model.adjust(spool, toPercent: percent, method: .byHand) else {
                problem = "A spool is somewhere between 0 % and 100 % full. "
                    + "For a figure in grams, switch to By weight."
                return
            }
        }
        isOpen = false
        entry = ""
        problem = nil
    }
}

// MARK: - Type

/// The spool's material type, chosen from what the catalogue actually knows.
///
/// It has to be editable because it is the one descriptive field with no authority behind it. The
/// tag stores a filament *id*, not a type; the type is whatever the catalogue calls that id, so a
/// tag written for an id the catalogue does not know arrives with the field blank. Before this it
/// was written once at intake and never again, so a spool that landed as `—` stayed `—` for ever —
/// which is how one got into this repository's own inventory.
///
/// **A picker, not a text field.** The first version was a field, and it was wrong twice over. The
/// options are a closed set in practice — the catalogue is the vocabulary, and typing `PETG ` or
/// `petg` by hand makes a type that sorts and filters as its own thing. And a free field had to
/// commit on losing focus, which meant deciding what happens when the rail switches spools
/// mid-edit; a picker commits on the choice and the question does not arise.
///
/// The `—` row exists only while the type is unset. Once a real type is chosen the row disappears,
/// so the field is *effectively* mandatory from the first edit onward without ever refusing to
/// represent a state a spool is genuinely in. A type the catalogue does not list — an older spool,
/// or a database since unloaded — is offered too, so opening the picker can never silently rewrite
/// a value just by being opened.
private struct TypeRow: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel
    @ObservedObject var materials: MaterialsViewModel

    /// Sentinel for "no type recorded". Empty string is the stored form; a `Picker` tag has to be
    /// something the row can display, and `—` is what every other unset value in this app shows.
    private static let unset = ""

    var body: some View {
        // Not `DataRow`, which collapses its contents with `.accessibilityElement(children:
        // .combine)`. That is right for a key and a static value and wrong for a control: it makes
        // the picker unreachable — an accessibility probe of this rail found no focusable element
        // here at all while the row was built that way.
        HStack(alignment: .firstTextBaseline) {
            Text("Type")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            Spacer(minLength: Theme.Spacing.s)
            Picker("", selection: selection) {
                if spool.materialType.isEmpty {
                    Text("—").tag(Self.unset)
                }
                ForEach(options, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            .accessibilityLabel("Material type of \(spool.label)")
        }
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }

    private var selection: Binding<String> {
        Binding(get: { spool.materialType },
                set: { model.setMaterialType($0, for: spool) })
    }

    /// Every type the catalogue knows, plus this spool's own if the catalogue has never heard of it.
    private var options: [String] {
        var found = Set(materials.rows.map(\.materialType).filter { !$0.isEmpty })
        if !spool.materialType.isEmpty { found.insert(spool.materialType) }
        return found.sorted()
    }
}

// MARK: - Location

/// Where the spool is: a picker over the user's own places, plus the list editor.
///
/// The picker offers **assertions only** — `Unplaced` and the user's place names. It never offers
/// a CFS slot or the external holder, because those are measurements the 30-second poll owns and
/// rewrites; see ``InventoryViewModel/setLocation(_:for:)`` and `docs/DECISIONS.md` D-011. When
/// the printer is currently holding the spool its position is shown as the selected row, labelled
/// with where it came from, and the note underneath says plainly that the poll will take it back.
///
/// The list of locations is edited in its own window (``LocationsView``), not here. It began inline
/// under this control, on the reasoning that a setting belongs next to what it affects; that holds
/// for a switch and not for a list, and the window's own comment carries the argument. What matters
/// here is that there is exactly **one** editor — an inline copy left alongside it would be two
/// places to do one thing, with two chances to disagree.
private struct LocationControl: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldBox(label: "Location", note: note) {
                Picker("", selection: selection) {
                    ForEach(model.locationOptions(for: spool)) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Location of \(spool.label)")
                .accessibilityHint(spool.location.isOnPrinter
                    ? "The printer reports this spool as loaded. Choosing a place records that you have taken it out; the next poll corrects it if it is still in the printer."
                    : "Choose where this spool is kept.")
            }

            HStack(spacing: Theme.Spacing.s) {
                Button("Manage locations…") {
                    openWindow(id: AppEnvironment.locationsWindowID)
                }
                .buttonStyle(.sw(.ghost, size: 11, h: 0, v: 2))
                .accessibilityLabel("Manage the list of locations")
                .accessibilityHint("Opens the Locations window.")
                Spacer(minLength: 0)
            }
        }
    }

    private var selection: Binding<LocationOption> {
        Binding(get: { model.locationOption(for: spool) },
                set: { model.setLocation($0, for: spool) })
    }

    private var note: String {
        spool.location.isOnPrinter
            ? "the printer owns this; it is re-read every 30 s"
            : "where you keep it"
    }
}

