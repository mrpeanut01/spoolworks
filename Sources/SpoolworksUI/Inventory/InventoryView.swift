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
            Color.clear.frame(width: Column.swatch)
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

        VStack(spacing: 0) {
            DataRow("Location", spool.location.description)
            DataRow("Serial", spool.serialLabel, mono: true)
            DataRow("Filament ID", spool.filamentIdLabel, mono: true)
            DataRow("Vendor ID", spool.vendorIdLabel, mono: true)
            DataRow("Tag", spool.tagSource.description)
            DataRow("Intake", spool.intakeDate.formatted(date: .abbreviated, time: .omitted))
        }
        .padding(.bottom, 18)

        Text("Usage log").kicker().padding(.bottom, 10)
        UsageLog(entries: spool.usage).padding(.bottom, 18)

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
