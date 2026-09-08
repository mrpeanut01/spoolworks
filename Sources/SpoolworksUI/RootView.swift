import SwiftUI
import SpoolworksCore

// MARK: - Sidebar model

/// The five destinations, in the two groups the design gives them.
///
/// This replaces the previous Tag / Reader / Materials / Printers sidebar. The reframing is the
/// design's: Spoolworks is a **stock** app that happens to read tags, so Inventory leads and the
/// tag operations sit in their own group underneath. The old Reader diagnostics screen is folded
/// into Read / identify, where its output is actually needed, and Materials and Printers move to
/// the menu bar and the Printer & CFS screen respectively.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case inventory
    case printerCFS
    case intake
    case identify
    case write

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inventory: return "Inventory"
        case .printerCFS: return "Printer & CFS"
        case .intake: return "Intake"
        case .identify: return "Read / identify"
        case .write: return "Write tag"
        }
    }

    var symbol: String {
        switch self {
        case .inventory: return "square.stack.3d.up"
        case .printerCFS: return "printer"
        case .intake: return "tray.and.arrow.down"
        case .identify: return "wave.3.right"
        case .write: return "tag"
        }
    }

    var help: String {
        switch self {
        case .inventory: return "Every spool you own"
        case .printerCFS: return "What the printer and its CFS units are holding"
        case .intake: return "Log incoming spools, tag by tag"
        case .identify: return "Put a tag on the reader and see which spool it is"
        case .write: return "Program a tag for a third-party spool"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case stock = "Stock"
        case tags = "Tags"

        var id: String { rawValue }

        var items: [SidebarItem] {
            switch self {
            case .stock: return [.inventory, .printerCFS, .intake]
            case .tags: return [.identify, .write]
            }
        }
    }
}

// MARK: - Root

/// The app shell: a header strip over a fixed sidebar and the detail column.
///
/// Built from plain stacks rather than `NavigationSplitView`. The design's shell is a rigid frame —
/// a 230 pt sidebar that does not resize, 2 pt rules between every region, and a full-width header
/// spanning both columns — and `NavigationSplitView` supplies none of that: it owns its own
/// divider, its sidebar is user-resizable, and it has no place to put a header above both columns.
struct RootView: View {
    @ObservedObject var env: AppEnvironment

    @SceneStorage("sidebarSelection") private var storedSelection: String?

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(env: env, cfs: env.cfsModel,
                      printers: env.printerModel, monitor: env.monitor)
            Rule()
            HStack(spacing: 0) {
                Sidebar(env: env)
                Rectangle().fill(Theme.rule).frame(width: Theme.ruleWidth)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.background)
        .toast(env.toasts)
        .onAppear {
            if let stored = storedSelection, let item = SidebarItem(rawValue: stored) {
                env.sidebarSelection = item
            }
            env.monitor.start()
            env.inventoryModel.load()
            Task { await env.printerModel.refresh() }
            // The catalogue used to load only when MaterialsView appeared. Now that Materials is
            // a window rather than a sidebar destination, nothing opened it on a normal run — so
            // the sidebar footer read "0 materials, version 0" and Intake could never resolve a
            // filament id to a name. It is app-wide state; it loads with the app.
            Task { await env.materialsModel.load() }
        }
        .onChange(of: env.sidebarSelection) { _, new in storedSelection = new.rawValue }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.sidebarSelection {
        case .inventory:
            InventoryView(model: env.inventoryModel, env: env)
        case .printerCFS:
            PrinterCFSView(model: env.cfsModel, inventory: env.inventoryModel)
        case .intake:
            IntakeView(model: env.intakeModel, inventory: env.inventoryModel,
                       env: env, tagModel: env.tagModel)
        case .identify:
            IdentifyView(env: env)
        case .write:
            WriteTagView(monitor: env.monitor, model: env.tagModel, settings: env.settings)
        }
    }
}

// MARK: - Header

/// The status strip: which printer, what its CFS is doing, and whether a reader is attached.
///
/// Everything here is live. The design shows a pulsing dot beside the CFS state; it pulses only
/// while a poll is actually in flight, so it means "working" rather than being decoration.
private struct HeaderBar: View {
    @ObservedObject var env: AppEnvironment
    // Observed individually, not reached through `env`. `AppEnvironment` holds these as plain
    // `let`s, and a nested ObservableObject does not republish through its owner — so the header
    // showed "none configured" indefinitely while the screen behind it polled the printer
    // successfully.
    @ObservedObject var cfs: CFSViewModel
    @ObservedObject var printers: PrinterViewModel
    @ObservedObject var monitor: ReaderMonitor

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("SPOOLWORKS")
                    .font(.system(size: 19, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.label)
                Rectangle().fill(Theme.accent).frame(width: 9, height: 9)
            }
            .frame(width: Theme.sidebarWidth, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.rule).frame(width: Theme.ruleWidth)
            }

            HStack(spacing: Theme.Spacing.xl) {
                StatusCell(title: "Printer", value: printerLabel)
                VRule()
                StatusCell(title: "CFS state", value: cfsLabel, pulsing: cfs.state.isPolling)
                VRule()
                StatusCell(title: "Reader", value: readerLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private var printerLabel: String {
        guard let target = cfs.target else { return "none configured" }
        return target.host.isEmpty
            ? target.displayName
            : "\(target.displayName) · \(target.host)"
    }

    private var cfsLabel: String {
        guard cfs.canPoll else { return "not connected" }
        if let info = cfs.info {
            let head = info.hasNoCFS ? "external only" : info.material.state
            return "\(head) · \(cfs.freshness)"
        }
        return cfs.freshness
    }

    private var readerLabel: String {
        let state = monitor.state
        switch state {
        case .starting: return "starting…"
        case let .subsystemUnavailable(detail): return detail
        case .noReader: return "no reader"
        case let .idle(devices, _): return "\(devices.first ?? "reader") · ready"
        case let .cardPresent(identity): return "\(identity.deviceName) · tag present"
        }
    }
}

private struct StatusCell: View {
    let title: String
    let value: String
    var pulsing = false

    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).kicker()
            HStack(spacing: 6) {
                if pulsing {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .opacity(dim ? 0.25 : 1)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true),
                                   value: dim)
                        .onAppear { dim = true }
                        .onDisappear { dim = false }
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SidebarItem.Group.allCases.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Hairline().padding(.horizontal, 14).padding(.vertical, 14)
                }
                Text(group.rawValue)
                    .kicker()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .padding(.top, index == 0 ? 18 : 0)

                ForEach(group.items) { item in
                    NavRow(item: item,
                           isSelected: env.sidebarSelection == item,
                           badge: badge(for: item)) {
                        env.sidebarSelection = item
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.l)

            MaterialDatabaseFooter(model: env.materialsModel)
        }
        .frame(width: Theme.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surfaceRecessed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    /// The count beside a destination. Blank rather than zero when there is nothing to report —
    /// a "0" badge reads as a broken count.
    private func badge(for item: SidebarItem) -> String {
        switch item {
        case .inventory:
            let n = env.inventoryModel.inventory.active.count
            return n == 0 ? "" : "\(n)"
        case .printerCFS:
            return env.cfsModel.navBadge
        default:
            return ""
        }
    }
}

/// One sidebar row. Selected rows invert outright — ink in light, paper in dark — with a 3 pt
/// accent rule down the leading edge, exactly as the design draws them.
private struct NavRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let badge: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: Theme.Spacing.s)
                if !badge.isEmpty {
                    Text(badge)
                        .font(Theme.monoSmall)
                        .opacity(0.6)
                }
            }
            .foregroundStyle(isSelected ? Theme.navActiveLabel : Theme.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Theme.accent : .clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.help)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Theme.navActiveFill }
        return hovering ? Theme.navHoverFill : .clear
    }
}

/// The pinned footer: which material catalogue the write and intake screens are resolving against.
private struct MaterialDatabaseFooter: View {
    @ObservedObject var model: MaterialsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Material database").kicker()
            Text(summary)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.secondaryLabel)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        "\(model.printerType.databaseFileName) · \(model.rows.count) materials\nversion \(model.version)"
    }
}
