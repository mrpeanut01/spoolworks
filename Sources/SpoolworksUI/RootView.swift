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


    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(env: env, cfs: env.cfsModel,
                      printers: env.printerModel, monitor: env.monitor)
            Rule()
            HStack(spacing: 0) {
                Sidebar(env: env, inventory: env.inventoryModel)
                Rectangle().fill(Theme.rule).frame(width: Theme.ruleWidth)
                VStack(spacing: 0) {
                    // Above every screen, not on Printer & CFS alone: a spool is loaded at the
                    // printer, and whoever loaded it is rarely looking at that screen when the
                    // poll notices.
                    LookalikeSlotBanners(inventory: env.inventoryModel)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Theme.background)
        .toast(env.toasts)
        // The screen is deliberately **not** restored between launches. Spoolworks is a stock app,
        // and Inventory is the answer to "what do I have?" — the question the user actually opened
        // it with. Reopening on Write tag, as scene restoration did, presented an irreversible
        // operation to someone who had not asked for one.
        .onAppear {
            env.sidebarSelection = .inventory
            env.monitor.start()
            env.inventoryModel.load()
            // After the spools, never before: the cleanup refuses to drop a place that has
            // anything on it, and it can only know that once the inventory is loaded.
            env.inventoryModel.retireSeededPlaces()
            // Ordered on purpose: the polls need a configured printer, and `refresh()` is what
            // discovers one. Starting them first meant `canPoll` was false on the first pass and
            // nothing happened for a full interval.
            Task {
                await env.printerModel.refresh()
                env.cfsModel.startAutoPoll()
            }
            // The catalogue used to load only when MaterialsView appeared. Now that Materials is
            // a window rather than a sidebar destination, nothing opened it on a normal run — so
            // the sidebar footer read "0 materials, version 0" and Intake could never resolve a
            // filament id to a name. It is app-wide state; it loads with the app.
            Task { await env.materialsModel.load() }
        }
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
            IdentifyView(env: env,
                         model: env.tagModel,
                         monitor: env.monitor,
                         inventory: env.inventoryModel)
        case .write:
            WriteTagView(monitor: env.monitor, model: env.tagModel, env: env,
                         inventory: env.inventoryModel)
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
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                // The mark, not an accent square. A 9 pt square of the accent colour beside the
                // wordmark reads as a red dot — which is exactly what it was called — and says
                // nothing about what the app is. `SpoolMark` is the app icon's own composition.
                SpoolMark(size: 20)
                Text("SPOOLWORKS")
                    .font(.system(size: 19, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.label)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Spoolworks")
            .frame(width: Theme.sidebarWidth, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.rule).frame(width: Theme.ruleWidth)
            }

            HStack(spacing: Theme.Spacing.xl) {
                // The CFS gets no cell of its own any more. It had one, spelling out
                // "connect · polled 12 s ago", which is detail the Printer & CFS screen already
                // shows in full — in the header it was a sentence where a colour would do. The
                // printer's dot now carries offline / printing / ready, and the freshness moved
                // to this cell's tooltip.
                StatusCell(title: "Printer", value: printerLabel, level: printerLevel,
                           help: printerHelp)
                VRule()
                StatusCell(title: "Reader", value: readerLabel, level: readerLevel,
                           help: "Blue while a tag is being read or written.")
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
        let name = target.host.isEmpty
            ? target.displayName
            : "\(target.displayName) · \(target.host)"
        // Only the one word: what is being printed belongs on the Printer & CFS screen.
        return cfs.job?.state.isActive == true ? "\(name) · printing" : name
    }

    /// Offline when there is nothing to talk to, busy while a job is running or a poll is in
    /// flight, ready otherwise.
    private var printerLevel: StatusLevel {
        guard cfs.target != nil, cfs.canPoll else { return .offline }
        if case .failed = cfs.state { return .offline }
        if cfs.job?.state.isActive == true || cfs.state.isPolling { return .busy }
        return cfs.isConnected ? .ready : .offline
    }

    /// The detail the CFS cell used to spell out, kept where it costs no space.
    private var printerHelp: String {
        guard cfs.canPoll else { return cfs.blockedReason ?? "No printer configured." }
        var parts = [cfs.freshness]
        if let info = cfs.info { parts.append(info.hasNoCFS ? "external spool only" : cfs.slotSummary) }
        if let summary = cfs.jobSummary { parts.append(summary) }
        return parts.joined(separator: " · ")
    }

    /// Busy whenever a tag is on the reader — which is exactly when it is being read or written.
    private var readerLevel: StatusLevel {
        switch monitor.state {
        case .starting: return .busy
        case .subsystemUnavailable, .noReader: return .offline
        case .idle: return .ready
        case .cardPresent: return .busy
        }
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
    let level: StatusLevel
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).kicker()
            HStack(spacing: 7) {
                StatusDot(level: level)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
        }
        .help(help)
        .accessibilityElement(children: .combine)
        // The state is spoken, not just coloured.
        .accessibilityLabel("\(title): \(level.spoken), \(value)")
    }
}

// MARK: - Sidebar

/// The windows the sidebar offers. Not `SidebarItem` cases: those switch the detail column and can
/// be *selected*, and these open a window and cannot.
enum ManageWindow: String, CaseIterable, Identifiable {
    case materials, printers, locations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .materials: return "Materials"
        case .printers: return "Printers"
        case .locations: return "Locations"
        }
    }

    var symbol: String {
        switch self {
        case .materials: return "books.vertical"
        case .printers: return "server.rack"
        case .locations: return "mappin.and.ellipse"
        }
    }

    var help: String {
        switch self {
        case .materials: return "The filament catalogue every screen resolves ids against"
        case .printers: return "Addresses and passwords the CFS poll uses"
        case .locations: return "Where you keep spools, and where they go when unloaded"
        }
    }

    var windowID: String {
        switch self {
        case .materials: return AppEnvironment.materialsWindowID
        case .printers: return AppEnvironment.printersWindowID
        case .locations: return AppEnvironment.locationsWindowID
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var env: AppEnvironment
    // Observed directly, for the same reason `HeaderBar` observes its models directly: the
    // inventory is a plain `let` on `AppEnvironment`, so a change to it does not republish
    // through `env`, and the badge sat on a stale count until the user changed section.
    @ObservedObject var inventory: InventoryViewModel
    @Environment(\.openWindow) private var openWindow

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

            // The three windows, reachable from the shell rather than only from the menu bar.
            //
            // The design's sidebar has exactly five entries and these are not screens, which is why
            // they were menu-only. But a menu is where you look for a command you already know
            // exists; the sidebar is where you look for the parts of an app — and a catalogue of
            // materials, a list of printers and a list of locations are parts. They open windows
            // rather than switching the detail column, so they are buttons and never selected.
            Hairline().padding(.horizontal, 14).padding(.vertical, 14)
            Text("Manage")
                .kicker()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            ForEach(ManageWindow.allCases) { window in
                ManageRow(window: window) { openWindow(id: window.windowID) }
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
            let n = inventory.inventory.active.count
            return n == 0 ? "" : "\(n)"
        // Nothing for Printer & CFS. The badge on the row above it is a count of *spools*, so a
        // number here read as spools too — "1×" beside Printer & CFS says one of something, and
        // the something it was counting was CFS units. How many boxes are attached is on the
        // screen itself, where it can be labelled.
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

/// A sidebar row that opens a window. Deliberately never drawn as selected — nothing in the detail
/// column corresponds to it, and a row that stays lit after its window is closed would be lying
/// about where you are.
private struct ManageRow: View {
    let window: ManageWindow
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: window.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15)
                Text(window.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: Theme.Spacing.s)
                // Says it leaves the sidebar behind, which a row that merely switches screens
                // does not.
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10))
                    .opacity(0.45)
            }
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.navHoverFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(window.help)
        .accessibilityLabel("\(window.title). \(window.help)")
        .accessibilityHint("Opens the \(window.title) window.")
    }
}
