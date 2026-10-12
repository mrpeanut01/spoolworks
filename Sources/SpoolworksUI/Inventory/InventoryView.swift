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
    /// Observed here, not reached through `env`: a nested `ObservableObject` does not republish
    /// through its owner, and the triangles have to appear when a printer's list arrives.
    @ObservedObject var attention: SpoolAttentionModel
    /// Column and rail widths, dragged by the user and remembered. Owned here so the header, every
    /// row and the splitter read one source — the fixed `Column` constants this replaced existed
    /// for the same reason, and drifting apart is still the failure it prevents.
    @StateObject private var layout = InventoryLayout()
    @State private var isReviewingRenames = false
    /// "Not now" on the rename offer. Session-only on purpose: the offer is cheap to see again and
    /// a permanent dismissal would need somewhere to undo it.
    @State private var renamesDeferred = false
    /// The colours being named in bulk, while that sheet is open.
    @State private var matchingColours: [InventoryViewModel.UnmatchedColour]?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            list
            // The rule between the panes is the splitter. Dragging it right narrows the rail, so
            // the delta is subtracted: the rail's leading edge moving right takes width off it.
            ResizeHandle(axis: .rail) { delta in
                layout.setRailWidth(layout.railWidth - delta)
            }
            InventoryDetailRail(model: model, env: env, attention: attention,
                                hueForge: env.hueForgeModel)
                .frame(width: layout.railWidth)
        }
        // Cheap when the lists are fresh — see `SpoolAttentionModel.listingLifetime`.
        .onAppear { attention.refreshListings() }
        .sheet(item: $model.retireTarget) { spool in
            RetireDialog(spool: spool,
                         confirm: { model.confirmRetire(spool) },
                         cancel: { model.retireTarget = nil })
        }
        .sheet(isPresented: $isReviewingRenames) {
            ColourRenameSheet(proposals: model.renameProposals) { model.applyRenames($0) }
        }
        .sheet(isPresented: Binding(get: { matchingColours != nil },
                                    set: { if !$0 { matchingColours = nil } })) {
            ColourMatchSheet(groups: matchingColours ?? []) { names in
                model.applyColourNames(names, to: matchingColours ?? [])
            }
        }
    }

    /// The faults in stock, counted, each with the one action that clears every case of it.
    ///
    /// The rail fixes a spool; this fixes a fault. Thirty spools that all say "not synced" are one
    /// problem with one answer, and making it thirty clicks would teach the user to ignore the
    /// triangle.
    @ViewBuilder
    private var attentionSummary: some View {
        let printer = attention.missingFilaments
        let hueForge = attention.count("hueforge")
        let colour = attention.count("colour")
        if printer != nil || hueForge > 0 || colour > 0 {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if let printer {
                    let n = printer.ids.count
                    attentionLine("\(printer.printerName) does not list \(n) filament\(n == 1 ? "" : "s") in stock "
                                  + "(\(attention.count("printer")) spool\(attention.count("printer") == 1 ? "" : "s"))",
                                  action: n == 1 ? "Add it to \(printer.printerName)…"
                                                 : "Add all \(n) to \(printer.printerName)…") {
                        env.filamentPushModel.offerAll(filamentIDs: printer.ids, family: printer.family)
                    }
                }
                if hueForge > 0 {
                    let synced = env.hueForgeModel.syncFolder != nil
                    attentionLine("\(hueForge) spool\(hueForge == 1 ? " is" : "s are") not in step with HueForge",
                                  action: synced ? "Sync all to HueForge" : "Open HueForge…") {
                        if synced {
                            env.hueForgeModel.syncNow()
                        } else {
                            openWindow(id: AppEnvironment.hueForgeWindowID)
                        }
                    }
                }
                if colour > 0 {
                    attentionLine("\(colour) spool\(colour == 1 ? " has a colour" : "s have colours") "
                                  + "not matched to the maker's own",
                                  action: "Match colours…") {
                        matchingColours = model.unmatchedColours()
                    }
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.08))
            .overlay(Rectangle().strokeBorder(Theme.warning, lineWidth: 1))
        }
    }

    private func attentionLine(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            Button(action, action: perform)
                .buttonStyle(.sw(.secondary, size: 12, h: 12, v: 6))
        }
    }

    /// The offer to rename. An offer and not an act: these names have been on screen, and on any
    /// label the user printed from them, for as long as the spools have been in stock.
    private var renameOffer: some View {
        let n = model.renameProposals.count
        // The example is one that has a name to contrast with; a spool the printer discovered
        // before colours were named has none, and "“” is Creality's “Black”" says nothing.
        let example = model.renameProposals.first { !$0.spool.colorName.isEmpty }
        return HStack(spacing: Theme.Spacing.m) {
            Text("\(n) spool\(n == 1 ? " has a colour its maker has" : "s have colours their makers have") "
                 + "a name for"
                 + (example.map { " — “\($0.spool.colorName)” is \($0.spool.brand)'s “\($0.name)”." } ?? "."))
                .font(Theme.caption)
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Review…") { isReviewingRenames = true }
                .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 7))
            Button("Not now") { renamesDeferred = true }
                .buttonStyle(.sw(.ghost, size: 12, h: 10, v: 7))
        }
        .panelSurface(padding: Theme.Spacing.m)
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

            if !model.renameProposals.isEmpty, !renamesDeferred {
                renameOffer.padding(.bottom, Theme.Spacing.m)
            }

            attentionSummary.padding(.bottom, Theme.Spacing.m)

            // Raised from the rail's "Add to printer", and shown here rather than in the rail so
            // it survives selecting another spool while the printer is being written to.
            FilamentPushNotice(model: env.filamentPushModel).padding(.bottom, Theme.Spacing.m)

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
            InventoryHeaderRow(layout: layout, model: model)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { spool in
                        InventoryRow(spool: spool,
                                     issues: attention.issues(for: spool),
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

/// A column heading that sorts the table.
///
/// The arrow only appears on the column actually in use. A row of six headings each carrying a
/// faint chevron says "these are all sorted", which is six times wrong — the affordance is the
/// hover, and the arrow is the state.
private struct SortHeader: View {
    let title: String
    let sort: InventorySort
    @ObservedObject var model: InventoryViewModel

    @State private var hovering = false

    private var isActive: Bool { model.sort == sort }

    var body: some View {
        Button { model.toggleSort(sort) } label: {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .black))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? Theme.accent : (hovering ? Theme.label : Theme.kickerLabel))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    private var name: String { title.isEmpty ? "Colour" : title }

    private var helpText: String {
        guard isActive else { return "Sort by \(name.lowercased())" }
        // A third click is the way back to the intake order, and nothing else on screen says so.
        return model.sortAscending == sort.ascendingIsNaturalFirst
            ? "Sorted by \(name.lowercased()) — click to reverse"
            : "Sorted by \(name.lowercased()) — click again for newest first"
    }

    private var accessibilityLabel: String {
        guard isActive else { return "\(name), not sorted" }
        return "\(name), sorted \(model.sortAscending ? "ascending" : "descending")"
    }
}

private struct InventoryHeaderRow: View {
    @ObservedObject var layout: InventoryLayout
    @ObservedObject var model: InventoryViewModel

    private func sort(for column: InventoryLayout.Column) -> InventorySort {
        switch column {
        case .type: return .type
        case .location: return .location
        case .remaining: return .left
        case .tag: return .tag
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            // A fixed height as well as a width. `Color` is a flexible view: constrained on one
            // axis only it expands on the other, which stretched this header row to fill the pane
            // and pushed the table halfway down the screen.
            // The swatch column has no header text, so its sort control is the space above it.
            SortHeader(title: "", sort: .colour, model: model)
                .frame(width: InventoryLayout.swatchWidth, height: 14, alignment: .leading)
            SortHeader(title: "Filament", sort: .filament, model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(InventoryLayout.Column.allCases, id: \.self) { column in
                // The handle sits on the column's *leading* edge and sizes the column to its left.
                // For the first one that is `Filament`, which is flexible — so dragging there
                // resizes `Type` inversely, and the effect is still "the thing on the left grew".
                ResizeHandle(axis: .column) { delta in
                    layout.setWidth(layout.width(column) - delta, for: column)
                }
                SortHeader(title: title(column), sort: sort(for: column), model: model)
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
        case .location: return "Location"
        // "Remaining" does not fit the column at its own width and truncated to "REMAINI…".
        // Shortened rather than widened: the column holds "100%", and "left" is the word the rest
        // of the app already uses — "How much is left", "Correct what's left".
        case .remaining: return "Left"
        case .tag: return "Tag"
        }
    }
}

private struct InventoryRow: View {
    let spool: Spool
    /// What this spool still needs. See ``SpoolAttention``.
    let issues: [SpoolAttention]
    @ObservedObject var layout: InventoryLayout
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false
    /// Whether the pointer is on the triangle, which is what shows the list of faults.
    @State private var hoveringIssues = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.s) {
                Swatch(hex: spool.colorHex)
                    .frame(width: InventoryLayout.swatchWidth, alignment: .leading)

                HStack(spacing: 6) {
                    Text(spool.label)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    // One triangle however many things are wrong: the row says *that* the spool
                    // needs something, the tooltip and the rail say what. Beside the name rather
                    // than in a column of its own, because most rows have nothing to show and an
                    // empty column is width taken from the name.
                    if !issues.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                            // A little air around it: an 11 pt glyph is a target you slide off.
                            .padding(3)
                            .contentShape(Rectangle())
                            .onHover { hoveringIssues = $0 }
                            // A popover and not a tooltip. A tooltip waits a second and a half,
                            // and inside a row that is itself a button it does not reliably
                            // appear at all; the faults should be there the moment you point.
                            .popover(isPresented: $hoveringIssues, arrowEdge: .bottom) {
                                IssueList(issues: issues)
                            }
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                gap
                Text(spool.materialType.isEmpty ? "—" : spool.materialType)
                    .font(.system(size: 14))
                    .frame(width: layout.width(.type), alignment: .leading)


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
                    // The percentage alone. Grams was tried here and taken back out: the rail
                    // already carries it for the selected spool, and in a column you scan down,
                    // two numbers per row is two numbers to read past.
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
        .accessibilityLabel("\(spool.label), \(spool.materialType), \(spool.remainingLabel) remaining, \(spool.location.description)"
                            + (issues.isEmpty ? "" : ". Needs attention: " + issues.map(\.title).joined(separator: "; ")))
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

/// What a row's triangle stands for, one fault per line.
private struct IssueList: View {
    let issues: [SpoolAttention]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                    Text(issue.title)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: 340, alignment: .leading)
        // Hovering must not be able to take the click, or the row under it could not be selected.
        .allowsHitTesting(false)
    }
}

// MARK: - Detail rail

private struct InventoryDetailRail: View {
    @ObservedObject var model: InventoryViewModel
    @ObservedObject var env: AppEnvironment
    @ObservedObject var attention: SpoolAttentionModel
    @ObservedObject var hueForge: HueForgeViewModel
    @Environment(\.openWindow) private var openWindow

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

        let issues = attention.issues(for: spool)
        if !issues.isEmpty {
            attentionPanel(issues, for: spool).padding(.bottom, Theme.Spacing.l)
        }

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
            ColourNameRow(spool: spool, model: model)
                // Rebuilt when the spool or its name changes, so the field never shows the
                // previous spool's draft.
                .id("\(spool.id)|\(spool.colorName)")
            NetWeightRow(spool: spool, model: model)
            DataRow("Serial", spool.serialLabel, mono: true)
            DataRow("Filament ID", spool.filamentIdLabel, mono: true)
            DataRow("Vendor ID", spool.vendorIdLabel, mono: true)
            DataRow("Tag", spool.tagSource.description)
            DataRow("Intake", spool.intakeDate.formatted(date: .abbreviated, time: .omitted))
        }
        .padding(.bottom, 18)

        RemainingControl(spool: spool, model: model).padding(.bottom, Theme.Spacing.s)

        // No "Read tag to verify" here. It only switched screens, which the sidebar already does,
        // and it read as though it would verify *this* spool when Read / identify simply reads
        // whatever tag is presented.
        VStack(spacing: Theme.Spacing.s) {
            // Only for a spool that has no tag. For one that already carries a payload the Write
            // screen's own flow applies, and offering this would invite writing a second identity
            // onto a spool that already has one.
            if spool.isUntagged {
                // Two directions, because the spool got here untagged for two different reasons.
                // A Creality spool arrives already tagged and sealed in mylar the reader cannot
                // see through, so it is counted onto the shelf and its factory tag is *read* when
                // the bag is opened. A third-party spool has no tag at all and needs one written.
                // Named for what the user is holding, not for the mechanism. "Read its tag" was
                // taken for a way to *identify* the spool, which Read / identify already does.
                Button("Attach RFID spool") {
                    model.attachTag(to: spool)
                    env.sidebarSelection = .identify
                }
                .buttonStyle(.sw(.secondary, block: true))
                .help("Read both of this spool's tags on the reader and attach them to this record.")

                Button("Write a tag for it") {
                    model.attachTag(to: spool)
                    env.loadForTagging(spool)
                    env.sidebarSelection = .write
                }
                .buttonStyle(.sw(.secondary, block: true))
                .help("Fills the Write screen from this spool and attaches the tag once verified.")
            }
            // Buying two of something is ordinary, and re-typing a spool you already own to record
            // the second one is work the app can do.
            Button("Clone to a new spool") {
                env.intakeModel.clone(spool)
                env.sidebarSelection = .intake
            }
            .buttonStyle(.sw(.secondary, block: true))
            .help("Opens Intake with this spool's details, ready to log another like it.")

            // Outlined rather than a bare link. Retiring is reversible — the spool and its whole
            // history are kept — but it is still the one button here that takes a spool out of the
            // list, and it should look like something you press on purpose.
            Button("Retire spool") { model.retireTarget = spool }
                .buttonStyle(.sw(.outline, block: true))
        }

        // The log goes last. It is the only thing on the rail with no bound on its height, so
        // anything below it gets pushed off the bottom as a spool accumulates history — and what
        // was below it was every control on the screen. It is also the part you read rather than
        // act on, which is the other reason it belongs after the buttons.
        Text("Usage log").kicker().padding(.top, 18).padding(.bottom, 10)
        UsageLog(entries: spool.usage)
    }
}

extension InventoryDetailRail {

    /// What the row's triangle stands for, each with the one thing that puts it right.
    ///
    /// At the top of the rail, above the remaining figure: these are the reasons the spool will
    /// not behave, and a reason the CFS will ignore a spool outranks how full it is.
    func attentionPanel(_ issues: [SpoolAttention], for spool: Spool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        Text(issue.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(issue.detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    attentionAction(issue, for: spool)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.08))
        .overlay(Rectangle().strokeBorder(Theme.warning, lineWidth: 1))
    }

    @ViewBuilder
    private func attentionAction(_ issue: SpoolAttention, for spool: Spool) -> some View {
        switch issue {
        case let .notOnPrinter(printer, _, filamentID):
            if let family = attention.family(missing: spool) {
                // Raises the notice above the list, which asks the printer again and then offers
                // the add. Nothing is written to the printer from this button alone.
                Button("Add to \(printer)…") {
                    env.filamentPushModel.offer(filamentID: filamentID, family: family)
                }
                .buttonStyle(.sw(.secondary, size: 12, h: 12, v: 6))
                .padding(.top, 2)
            }
        case .notInHueForge:
            if hueForge.syncFolder != nil {
                Button("Sync to HueForge now") { hueForge.syncNow() }
                    .buttonStyle(.sw(.secondary, size: 12, h: 12, v: 6))
                    .padding(.top, 2)
                    .help("Rewrites Spoolworks' library in the HueForge folder with everything in stock.")
            } else {
                Button("Open HueForge…") { openWindow(id: AppEnvironment.hueForgeWindowID) }
                    .buttonStyle(.sw(.secondary, size: 12, h: 12, v: 6))
                    .padding(.top, 2)
                    .help("Choose HueForge's folder to sync into, or export a library file to import.")
            }
        case .colourUnmatched:
            EmptyView()
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
struct RemainingControl: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    @State private var isOpen = false
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button(isOpen ? "Cancel correction" : "Correct what's left") {
                isOpen.toggle()
                chosen = nil
            }
            .buttonStyle(.sw(.secondary, block: true))
            .accessibilityLabel(isOpen
                                ? "Cancel correcting what is left of \(spool.label)"
                                : "Correct what is left of \(spool.label)")

            if isOpen {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    // One picker, not a unit switch and a field. See
                    // `InventoryViewModel.remainingOptions(for:)` for why both units are on every
                    // rung and what this trades away.
                    FieldBox(label: "How much is left", note: "a tenth of a spool per step") {
                        Picker("", selection: $chosen) {
                            Text("—").tag(Int?.none)
                            ForEach(options, id: \.grams) { option in
                                Text(option.label).tag(Int?.some(option.grams))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("How much is left of \(spool.label)")
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Button("Apply", action: apply)
                            .buttonStyle(.sw(.primary, size: 12, h: 14, v: 8))
                            .disabled(chosen == nil)
                        Text("of \(spool.netWeightGrams) g net")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                .padding(Theme.Spacing.m)
                .background(Theme.surface)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
            }
        }
        // Selecting another spool must not carry a half-made choice across to it.
        .onChange(of: spool.id) { _, _ in
            isOpen = false
            chosen = nil
        }
    }

    private var options: [(grams: Int, percent: Double, label: String)] {
        model.remainingOptions(for: spool)
    }

    /// Every rung is in range by construction, so there is nothing here to refuse — unlike the
    /// typed field this replaced, where 130 % and a gross weight were both reachable.
    private func apply() {
        guard let chosen else { return }
        _ = model.adjust(spool, toGrams: chosen)
        isOpen = false
        self.chosen = nil
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
struct TypeRow: View {
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

/// What a **full** spool of this holds — its size, not how much is on it. Correctable.
///
/// Nominal, and both ways it gets set can be wrong: the tag's length code is what Creality wrote,
/// and an unrecognised code reports as 1 kg on every Creality client. A row mis-picked at intake is
/// the other way — a spool recorded at 100 g whose "what's left" picker then offers a tenth of a
/// spool per rung and looks broken, when the broken thing is this figure.
struct NetWeightRow: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    var body: some View {
        // Not `DataRow`, for the reason `TypeRow` gives: it collapses its contents under
        // `.accessibilityElement(children: .combine)`, which leaves a control unreachable.
        HStack(alignment: .firstTextBaseline) {
            Text("Spool size")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            Spacer(minLength: Theme.Spacing.s)
            Picker("", selection: Binding(get: { spool.netWeightGrams },
                                          set: { model.setNetWeight($0, for: spool) })) {
                // The spool's own figure is offered even when the tag format has no code for it,
                // so opening the picker can never quietly change a value just by being opened.
                if !IntakeViewModel.weights.contains(spool.netWeightGrams) {
                    Text(Spool.weightLabel(spool.netWeightGrams)).tag(spool.netWeightGrams)
                }
                ForEach(IntakeViewModel.weights, id: \.self) { grams in
                    Text(Spool.weightLabel(grams)).tag(grams)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            .accessibilityLabel("Spool size of \(spool.label) — what a full one holds")
        }
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
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
/// The list of locations is edited in its own window (``LocationsView``), reached from the sidebar
/// rather than from here. It began inline under this control, then as a link beside it; both put a
/// way into a *window* inside a panel about one spool, which is the wrong altitude. Windows are
/// reached from the shell, and the shell is the sidebar.
struct LocationControl: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel


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


// MARK: - The editable part of a spool, shared

/// Everything about a spool that can be changed by hand: where it is, what it is, how big it is and
/// how much is left.
///
/// Lives here and is used by Read / identify as well as by the Inventory rail. Identifying a tag
/// and then having to go somewhere else to say "this one is nearly empty" is a round trip through a
/// screen you were just on, and the spool is already in front of you — so the same controls appear
/// there, rather than a second set that could disagree about what a tenth of a spool means or which
/// locations exist.
///
/// Deliberately no header of its own: each host frames it, because "Spool detail" and "this is the
/// spool on the reader" are different sentences about the same controls.
struct SpoolEditControls: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel
    @ObservedObject var materials: MaterialsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationControl(spool: spool, model: model).padding(.bottom, 14)
            VStack(spacing: 0) {
                TypeRow(spool: spool, model: model, materials: materials)
                NetWeightRow(spool: spool, model: model)
            }
            .padding(.bottom, 14)
            RemainingControl(spool: spool, model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Colour name

/// What the colour is called, and — when the app could not tell — the maker's nearest colours to
/// choose from.
///
/// The choices appear only while the name is a generic description. That is the one case with a
/// question in it: "Naval Adventures" is what the colour looks like, and the maker has a name for
/// it that no measurement can recover, because a factory tag's hex is a code and not a reading.
/// One click answers it for this spool and every later one of the same filament and colour.
struct ColourNameRow: View {
    let spool: Spool
    @ObservedObject var model: InventoryViewModel

    @State private var draft = ""

    var body: some View {
        let source = model.colourNameSource(for: spool)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("Colour")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                Spacer(minLength: Theme.Spacing.s)
                SWTag(text: Self.title(source), style: source == .generic ? .accent : .neutral)
                    .help(Self.help(source))
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .swInput()
                    .frame(maxWidth: 150)
                    .onSubmit { model.setColourName(draft, for: spool) }
                    .accessibilityLabel("Colour name of \(spool.label)")
                    .accessibilityHint("Press Return to set it for every spool of this filament and colour.")
            }
            if source == .generic {
                makerColourMenu
                let suggestions = model.colourName(for: spool).suggestions
                if !suggestions.isEmpty {
                    // The line's own colours first — the answer is usually one of them even when
                    // none is *near*, because a tag's hex is a code — then a few from the rest of
                    // the maker's range.
                    let line = suggestions.filter { $0.scope == .line }
                    let rest = suggestions.filter { $0.scope != .line }
                    FilamentMatchChips(matches: Array(line.prefix(6)) + Array(rest.prefix(line.isEmpty ? 6 : 3)),
                                       showsBrand: false) { match in
                        model.setColourName(match.colour.name, for: spool)
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.s)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
        .onAppear { draft = spool.colorName }
    }

    /// Every colour the maker sells this filament in, by name.
    ///
    /// The chips below are the nearest few, and for a factory tag "nearest" can be wrong — its
    /// hex is a code, not a reading. The box says the name; this is the whole list to find it in.
    /// Choosing one names the colour and nothing else: on a tagged spool the hex is part of what
    /// the printer identifies it by, so it is never changed from here.
    @ViewBuilder
    private var makerColourMenu: some View {
        let listed = model.makerColours(for: spool)
        if !listed.colours.isEmpty {
            HStack(spacing: Theme.Spacing.s) {
                Text(listed.scope == .line ? "Maker's colours" : "Maker's range")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.kickerLabel)
                Spacer(minLength: Theme.Spacing.s)
                Picker("", selection: Binding(
                    get: { "" },
                    set: { id in
                        guard let colour = listed.colours.first(where: { $0.id == id }) else { return }
                        model.setColourName(colour.name, for: spool)
                    })) {
                    Text("Choose…").tag("")
                    ForEach(listed.colours) { colour in
                        Text(ColorScanSheet.menuTitle(colour, showsLine: listed.scope != .line))
                            .tag(colour.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                .accessibilityLabel("The maker's name for the colour of \(spool.label)")
            }
        }
    }

    static func title(_ source: ColourNameSource) -> String {
        switch source {
        case .learned: return "set by you"
        case .brand: return "maker's name"
        case .generic: return "approx."
        }
    }

    static func help(_ source: ColourNameSource) -> String {
        switch source {
        case .learned: return "You named this colour. It applies to every spool of this filament and colour."
        case .brand: return "The maker's own name for this colour."
        case .generic: return "A description of the colour, not the maker's name for it. Pick one below or type it."
        }
    }
}

/// A row of a maker's colours to choose between: swatch, name, and the line it belongs to.
///
/// Shared by the Inventory rail and the camera sheet so the two offer a filament the same way.
struct FilamentMatchChips: View {
    let matches: [BrandColourCatalogue.Match]
    /// True when the matches span makers, and the maker is therefore part of the answer.
    var showsBrand: Bool
    var selectedID: String? = nil
    let pick: (BrandColourCatalogue.Match) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(matches) { match in
                    Button { pick(match) } label: {
                        HStack(spacing: 6) {
                            Swatch(hex: match.colour.hex, size: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(match.colour.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(1)
                                Text(detail(match))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.surface)
                        .overlay(Rectangle().strokeBorder(
                            match.id == selectedID ? Theme.accent : Theme.separator,
                            lineWidth: match.id == selectedID ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(match.colour.brand) \(match.colour.label) · #\(match.colour.hex) · "
                          + (match.colour.source == .measured ? "measured swatch" : "published colour")
                          + String(format: " · ΔE %.1f", match.deltaE))
                    .accessibilityLabel("\(match.colour.brand) \(match.colour.name), \(match.colour.line)")
                    .accessibilityAddTraits(match.id == selectedID ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private func detail(_ match: BrandColourCatalogue.Match) -> String {
        showsBrand ? "\(match.colour.brand) · \(match.colour.line)" : match.colour.line
    }
}

/// Names every unmatched colour in stock in one sitting: a row per filament and colour, a menu of
/// that maker's colours on each.
///
/// Nothing is pre-chosen. The nearest colour is listed first, but for a factory tag "nearest" is
/// often wrong — its hex is a code, not a reading — and a sheet that arrived with thirty guesses
/// already ticked would be thirty names applied on one careless click.
struct ColourMatchSheet: View {
    let groups: [InventoryViewModel.UnmatchedColour]
    let apply: ([String: String]) -> Void

    @State private var names: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var chosen: Int {
        names.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Colour names").kicker()
                Text("Match colours to their makers'").font(.system(size: 20, weight: .heavy))
                Text("Each row is one filament and colour, however many spools of it are in stock. "
                     + "Choose what the maker calls it — the nearest are listed first — or type "
                     + "the name off the box. Rows left alone are not changed.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Rule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        row(group)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Hairline() }
                    }
                }
                .padding(.horizontal, 20)
            }
            Rule()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sw(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("Name \(chosen)") {
                    apply(names)
                    dismiss()
                }
                .buttonStyle(.sw(.primary))
                .disabled(chosen == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 680, height: 560)
        .background(Theme.background)
    }

    private func row(_ group: InventoryViewModel.UnmatchedColour) -> some View {
        let name = Binding(get: { names[group.id] ?? "" }, set: { names[group.id] = $0 })
        return HStack(spacing: Theme.Spacing.m) {
            Swatch(hex: group.spool.colorHex)
            VStack(alignment: .leading, spacing: 1) {
                Text([group.spool.brand, group.spool.name].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(Theme.rowTitle)
                    .lineLimit(1)
                Text("“\(group.spool.colorName.isEmpty ? "—" : group.spool.colorName)” · #\(group.spool.colorHex)"
                     + " · \(group.spoolCount) spool\(group.spoolCount == 1 ? "" : "s")")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !group.options.isEmpty {
                Picker("", selection: Binding(
                    get: { group.options.first { $0.name == name.wrappedValue }?.id ?? "" },
                    set: { id in name.wrappedValue = group.options.first { $0.id == id }?.name ?? "" })) {
                    Text("Maker's colours").tag("")
                    ForEach(group.options) { colour in
                        Text(ColorScanSheet.menuTitle(colour, showsLine: group.showsLine)).tag(colour.id)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel("The maker's colours for \(group.spool.label)")
            }
            TextField("Name", text: name)
                .textFieldStyle(.plain)
                .swInput()
                .frame(width: 140)
                .accessibilityLabel("Colour name for \(group.spool.label)")
        }
    }
}

/// Review of the offered renames: what each spool is called now, and what its maker calls it.
struct ColourRenameSheet: View {
    let proposals: [InventoryViewModel.ColourRename]
    let apply: (Set<Spool.ID>) -> Void

    @State private var chosen: Set<Spool.ID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Colour names").kicker()
                Text("Use the makers' names").font(.system(size: 20, weight: .heavy))
                Text("These spools were named by the nearest of 31,861 generic colours. Each has a "
                     + "colour in its maker's own range that it matches clearly. Untick any you "
                     + "would rather keep.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Rule()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(proposals) { proposal in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(proposal.id) },
                            set: { if $0 { chosen.insert(proposal.id) } else { chosen.remove(proposal.id) } })) {
                            HStack(spacing: Theme.Spacing.s) {
                                Swatch(hex: proposal.spool.colorHex)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(proposal.spool.brand) \(proposal.spool.name)")
                                        .font(Theme.rowTitle)
                                    Text("\(proposal.spool.colorName.isEmpty ? "—" : proposal.spool.colorName) → \(proposal.name)")
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.secondaryLabel)
                                }
                                Spacer(minLength: 0)
                                Text("#" + proposal.spool.colorHex)
                                    .font(Theme.monoSmall)
                                    .foregroundStyle(Theme.kickerLabel)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 6)
                    }
                }
                .padding(20)
            }
            Rule()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sw(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(chosen.count)") {
                    apply(chosen)
                    dismiss()
                }
                .buttonStyle(.sw(.primary))
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
        .background(Theme.background)
        .onAppear { chosen = Set(proposals.map(\.id)) }
    }
}
