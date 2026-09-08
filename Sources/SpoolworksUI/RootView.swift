import SwiftUI
import SpoolworksCore

// MARK: - Sidebar model

/// The destinations in the sidebar.
///
/// Replaces the Windows slide-out hamburger panel (`MainForm.SetupSidebarUI`,
/// `MainForm.cs:108-153`). The sidebar there is a `Panel` animated between 0 and 200 px by a 10 ms
/// timer, and it auto-closes on **any mouse movement over the form** (`MainForm.cs:887-890`) —
/// explicit non-goal 1. This is an ordinary `NavigationSplitView` sidebar: user-toggled, its width
/// remembered by AppKit, dismissed by nothing.
///
/// The Windows sidebar's items open **modal dialogs**; §8.1 says the browsing screens should switch
/// the detail column instead, and that is what `.materials` and `.printers` do.
/// The `Settings` destination is deliberately absent, and so is the `Settings` scene that used to
/// back it. What was in it: one tab of prose describing non-configurable behaviour, and two
/// switches. `advancedTagOperations` now sits next to the operations it gates (the Auto-Write card
/// and the write confirmation sheet) and still defaults to off; `showKeyMaterial` moved to the new
/// Reader screen, which is where its effects are read. Nothing was left behind as a dead
/// preference — the mistake this project already corrected once, when `AutoRead`/`AutoWrite`
/// lingered in the pane after being superseded.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case tag
    case reader
    case materials
    case printers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tag: return "Tag"
        case .reader: return "Reader"
        case .materials: return "Materials"
        case .printers: return "Printers"
        }
    }

    /// SF Symbols, replacing `menu/settings/manage/upload/download/format/memory.png` (§8.2).
    var symbol: String {
        switch self {
        case .tag: return "tag"
        case .reader: return "wave.3.right"
        case .materials: return "square.stack.3d.up"
        case .printers: return "printer"
        }
    }

    /// Sidebar grouping, mirroring the Windows headers `APP` / `PRINTER DATABASE` /
    /// `RFID FUNCTIONS` (`MainForm.cs:113,115,119`) without the `.ToUpper()` shouting — macOS
    /// sidebar sections style themselves.
    enum Group: String, CaseIterable, Identifiable {
        case rfid = "RFID"
        case database = "Printer Database"

        var id: String { rawValue }

        var items: [SidebarItem] {
            switch self {
            case .rfid: return [.tag, .reader]
            case .database: return [.materials, .printers]
            }
        }
    }

    var help: String {
        switch self {
        case .tag: return "Read and write spool tags"
        case .reader: return "Reader hardware, the tag on it, and diagnostics"
        case .materials: return "Browse and edit the filament catalogue"
        case .printers: return "Manage printer databases"
        }
    }
}

// MARK: - Root

/// The app shell: sidebar plus detail column, with the toast overlay on top.
struct RootView: View {
    @ObservedObject var env: AppEnvironment

    /// Remembered per scene, so reopening the window lands where you left it.
    @SceneStorage("sidebarSelection") private var storedSelection: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The selection itself lives on ``AppEnvironment``, not in this view's `@State`: the Tag menu
    /// is global and some of its commands (⇧⌘W) only make sense with the Tag screen showing, so
    /// something outside the view hierarchy has to be able to select it.
    private var selection: Binding<SidebarItem> { $env.sidebarSelection }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .frame(minWidth: Theme.windowMinWidth - Theme.sidebarMinWidth,
                       minHeight: Theme.windowMinHeight)
        }
        .navigationSplitViewStyle(.balanced)
        .toast(env.toasts)
        .onAppear {
            if let stored = storedSelection, let item = SidebarItem(rawValue: stored) {
                env.sidebarSelection = item
            }
            env.monitor.start()
        }
        .onChange(of: env.sidebarSelection) { _, new in storedSelection = new.rawValue }
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(SidebarItem.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.items) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                            .help(item.help)
                            .accessibilityLabel(item.title)
                            .accessibilityHint(item.help)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth,
                                        ideal: Theme.sidebarIdealWidth,
                                        max: Theme.sidebarMaxWidth)
        .accessibilityLabel("Sections")
    }

    @ViewBuilder
    private var detail: some View {
        switch env.sidebarSelection {
        case .tag:
            TagView(monitor: env.monitor, model: env.tagModel, settings: env.settings)
        case .reader:
            ReaderPane(settings: env.settings, monitor: env.monitor)
        case .materials:
            MaterialsView(model: env.materialsModel)
        case .printers:
            PrintersView(model: env.printerModel)
        }
    }
}
