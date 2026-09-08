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

    var body: some View {
        HStack(spacing: 0) {
            list
            Rectangle().fill(Theme.rule).frame(width: Theme.ruleWidth)
            InventoryDetailRail(model: model, env: env)
                .frame(width: Theme.detailRailWidth)
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

            SegmentedFilter(options: InventoryFilter.allCases,
                            title: \.title,
                            selection: $model.filter)
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
            InventoryHeaderRow()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { spool in
                        InventoryRow(spool: spool,
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

/// Column widths live here, once, so the header and every row cannot drift apart.
private enum Column {
    static let swatch: CGFloat = 34
    static let type: CGFloat = 70
    static let serial: CGFloat = 78
    static let location: CGFloat = 118
    static let remaining: CGFloat = 86
    static let tag: CGFloat = 118
}

private struct InventoryHeaderRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            // A fixed height as well as a width. `Color` is a flexible view: constrained on one
            // axis only it expands on the other, which stretched this header row to fill the pane
            // and pushed the table halfway down the screen.
            Color.clear.frame(width: Column.swatch, height: 1)
            Text("Filament").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: Column.type, alignment: .leading)
            Text("Serial").frame(width: Column.serial, alignment: .leading)
            Text("Location").frame(width: Column.location, alignment: .leading)
            Text("Remaining").frame(width: Column.remaining, alignment: .trailing)
            Text("Tag").frame(width: Column.tag, alignment: .leading)
        }
        .kicker()
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
        }
    }
}

private struct InventoryRow: View {
    let spool: Spool
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.s) {
                Swatch(hex: spool.colorHex).frame(width: Column.swatch, alignment: .leading)

                Text(spool.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(spool.materialType.isEmpty ? "—" : spool.materialType)
                    .font(.system(size: 14))
                    .frame(width: Column.type, alignment: .leading)

                Text(spool.serialLabel)
                    .font(Theme.monoCaption)
                    .frame(width: Column.serial, alignment: .leading)

                Text(spool.location.description)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .frame(width: Column.location, alignment: .leading)

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
                .frame(width: Column.remaining, alignment: .trailing)

                Text(spool.tagSource.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: Column.tag, alignment: .leading)
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

        VStack(spacing: Theme.Spacing.s) {
            Button("Read tag to verify") { env.sidebarSelection = .identify }
                .buttonStyle(.sw(.secondary, block: true))
            Button("Retire spool") { model.retireTarget = spool }
                .buttonStyle(.sw(.ghost, block: true))
        }
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

// MARK: - Location

/// Where the spool is: a picker over the user's own places, plus the list editor.
///
/// The picker offers **assertions only** — `Unplaced` and the user's place names. It never offers
/// a CFS slot or the external holder, because those are measurements the 30-second poll owns and
/// rewrites; see ``InventoryViewModel/setLocation(_:for:)`` and `docs/DECISIONS.md` D-011. When
/// the printer is currently holding the spool its position is shown as the selected row, labelled
/// with where it came from, and the note underneath says plainly that the poll will take it back.
///
/// The list editor lives here, under the control it configures, rather than in a preferences
/// window — the app has none, on purpose, and ``AppSettings`` gives the reasoning: a switch is
/// rendered next to what it affects. Places are only ever wanted while looking at a spool's
/// location, which is exactly here.
private struct LocationControl: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    @State private var managing = false

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
                Button(managing ? "Done" : "Manage places") { managing.toggle() }
                    .buttonStyle(.sw(.ghost, size: 11, h: 0, v: 2))
                    .accessibilityLabel(managing ? "Finish editing places" : "Manage the list of places")
                Spacer(minLength: 0)
            }

            if managing { PlaceEditor(model: model) }
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

/// Add, rename and remove the places the picker offers.
///
/// Renaming is a plain text field committed with Return rather than a Rename button that swaps the
/// row into an edit state: the row is already a field, the commit is already a keystroke, and the
/// swap only added a mode the user has to notice they are in. The count beside each place is there
/// so removing one is never a surprise — the spools move to `Unplaced` and each gets a line in its
/// own history saying why, but a removal that quietly shuffles eleven spools should say eleven
/// before it happens, not after.
private struct PlaceEditor: View {
    @ObservedObject var model: InventoryViewModel

    @State private var newName = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Places").kicker()

            ForEach(model.places.names, id: \.self) { name in
                PlaceRow(name: name,
                         count: model.spoolCount(atPlace: name),
                         rename: { rename(name, to: $0) },
                         remove: { report(model.removePlace(name)) })
                    // Keyed by the name so a rename rebuilds the row from the new value rather
                    // than leaving the field showing the old draft.
                    .id(name)
            }

            Hairline()

            HStack(spacing: Theme.Spacing.s) {
                TextField("New place", text: $newName)
                    .textFieldStyle(.plain)
                    .swInput()
                    .onSubmit(add)
                    .accessibilityLabel("Name of a new place")
                Button("Add", action: add)
                    .buttonStyle(.sw(.secondary, size: 11, h: 10, v: 5))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add this place to the list")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
    }

    private func add() {
        report(model.addPlace(newName))
        if problem == nil { newName = "" }
    }

    private func rename(_ old: String, to new: String) {
        guard new.trimmingCharacters(in: .whitespaces) != old else { return }
        report(model.renamePlace(old, to: new))
    }

    /// Rejections are shown, not swallowed — the list refuses an edit for four different reasons
    /// and a button that silently does nothing is the worst of them.
    private func report(_ result: PlaceEditResult) {
        problem = result.problem
    }
}

private struct PlaceRow: View {
    let name: String
    let count: Int
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if SpoolPlaces.isUnplaced(name) {
                // Reserved: it is where `reconcile` puts a spool the printer has stopped
                // reporting, so the list cannot be allowed to lose it.
                ReadOnlyValue(name)
                SWTag(text: "always", style: .neutral)
            } else {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .swInput()
                    .onSubmit { rename(draft) }
                    .accessibilityLabel("Name of the place \(name)")
                    .accessibilityHint("Press Return to rename it.")
                if count > 0 {
                    SWTag(text: "\(count)", style: .neutral)
                        .accessibilityLabel("\(count) spool\(count == 1 ? "" : "s") here")
                }
                Button("Remove", action: remove)
                    .buttonStyle(.sw(.ghost, size: 11, h: 8, v: 4))
                    .accessibilityLabel("Remove the place \(name)")
                    .accessibilityHint(count == 0
                        ? "Nothing is kept here."
                        : "\(count) spool\(count == 1 ? "" : "s") will move to \(SpoolPlaces.unplaced).")
            }
        }
        .onAppear { draft = name }
    }
}
