import SwiftUI
import AppKit
import SpoolworksCore

// MARK: - Shared state

/// The objects every scene needs. One instance, owned by the `App`.
///
/// Held here rather than threaded through `@EnvironmentObject` because the menu-bar `Commands`
/// need the same instances and command bodies are built outside the view hierarchy.
@MainActor
final class AppEnvironment: ObservableObject {
    let monitor: ReaderMonitor
    let toasts: ToastCenter
    let settings: AppSettings
    let tagModel: TagViewModel
    // Owned here rather than created per-view so selections, edits and load state survive
    // switching sidebar sections.
    let materialsModel: MaterialsViewModel
    let printerModel: PrinterViewModel
    /// Spool management: the stock list, and the only writer of the inventory file.
    let inventoryModel: InventoryViewModel
    /// The printer's live CFS state, and the poll that folds it into the inventory.
    let cfsModel: CFSViewModel
    /// The Intake screen's own state machine.
    let intakeModel: IntakeViewModel

    /// Which sidebar destination the detail column is showing.
    ///
    /// It used to be `@State` inside `RootView`, which made it unreachable from the menu bar — and
    /// the Tag menu is global. ⇧⌘W pressed on the Materials screen built a write plan whose
    /// confirmation sheet lives in `TagView`, a view that was not on screen: the tag was read, the
    /// arming was spent, `pendingPlan` was set, nothing appeared, and auto-write was then blocked
    /// for as long as that invisible plan stayed pending. A command that needs a screen has to be
    /// able to bring that screen up.
    /// Inventory leads: Spoolworks is a stock app that reads tags, not a tag app with a list.
    @Published var sidebarSelection: SidebarItem = .inventory

    init() {
        let monitor = ReaderMonitor()
        let toasts = ToastCenter()
        let settings = AppSettings()
        self.monitor = monitor
        self.toasts = toasts
        self.settings = settings
        // Settings are held by the tag model, not passed per-call, because the card subscription
        // that drives auto-write now lives in the model and has no view to ask.
        self.tagModel = TagViewModel(monitor: monitor, toasts: toasts, settings: settings)
        // Falling back to a temporary directory keeps the app usable (and the failure visible
        // in the screens' own error states) rather than trapping at launch.
        let storage = (try? MaterialStorage.applicationSupport())
            ?? MaterialStorage(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CFS-RFID/material_database", isDirectory: true))
        self.materialsModel = MaterialsViewModel(storage: storage)
        // The live SSH transport rather than the default stand-in: without it every printer
        // operation throws "not implemented", which is what the app shipped with.
        // Persistent, not in-memory: the default store kept passwords only for the lifetime of the
        // process, so a printer had to be re-authenticated every launch and the CFS auto-poll could
        // never run after a restart.
        //
        // Same fallback reasoning as the material storage below — a broken Application Support must
        // leave the app usable with the failure visible, not trap at launch. Here the degraded mode
        // is a password that lasts the session, which is exactly what the adapter already does when
        // an individual write fails.
        let credentialFile = try? FileCredentialStore.applicationSupport()
        let credentials = LocalPrinterCredentialStore(
            backing: credentialFile ?? InMemoryCredentialStore(),
            onFailure: { [weak toasts] message in
                Task { @MainActor in toasts?.error(message) }
            })
        let printerModel = PrinterViewModel(storage: storage,
                                            transport: LivePrinterTransport(),
                                            credentials: credentials)
        self.printerModel = printerModel
        // The Printers window rewrites the catalogue on disk — a download merged in, a reset, a
        // family added or removed — while the Materials window edits its own in-memory copy and
        // writes that copy back on the next save. Left unwired, the next filament edit persisted
        // the pre-download catalogue and the download was gone.
        let materialsModel = self.materialsModel
        printerModel.onDatabaseChanged = { [weak materialsModel] family in
            materialsModel?.noteExternalChange(to: family)
        }

        // Same fallback reasoning as the material storage above: a broken Application Support
        // must leave the app usable and the failure visible, not trap at launch.
        let inventoryStore = (try? InventoryStore.applicationSupport())
            ?? InventoryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Spoolworks", isDirectory: true))
        let inventoryModel = InventoryViewModel(store: inventoryStore, toasts: toasts)
        self.inventoryModel = inventoryModel
        self.cfsModel = CFSViewModel(transport: LivePrinterTransport(),
                                     printers: printerModel,
                                     inventory: inventoryModel)
        // Every verified write logs its spool, whichever screen or path produced it.
        let intakeModel = IntakeViewModel(monitor: monitor,
                                          inventory: inventoryModel,
                                          materials: self.materialsModel,
                                          toasts: toasts)
        self.intakeModel = intakeModel
        self.tagModel.onWriteSucceeded = {
            [weak inventoryModel, weak intakeModel,
             weak materials = self.materialsModel] summary in
            guard let inventoryModel else { return }
            // Intake owns its own add-to-stock step and the user is meant to see both tags
            // verified before committing, so a write made there logs nothing on its own. It does
            // need to know *what* was written: the spool it later adds has to carry the identity
            // the tags actually hold, not whatever its form says by then.
            if let intakeModel, intakeModel.isActive {
                intakeModel.absorbWrite(uid: summary.uid, record: summary.record)
                return
            }
            // Resolved here rather than inside the inventory, which holds no catalogue. The tag
            // stores a filament *id*; the type is whatever the catalogue calls that id, and an id
            // it does not know genuinely has no type to report.
            let materialType = materials?.rows.first { $0.id == summary.record.materialId }?
                .materialType ?? ""
            // A write the user asked for *on behalf of* an existing untagged spool attaches to it.
            // Only if that fails — no request, or the spool has gone — is it a new record.
            if inventoryModel.attachTag(record: summary.record,
                                        materialType: materialType,
                                        source: .spoolworksWritten) {
                // Put the serial back. `commitWrite` randomises it after every success, because on
                // the Write screen the next tag is normally the next *spool* and reusing a serial
                // would tag two of them identically. Tagging a spool that was already in stock is
                // the exception: a spool carries a tag on each side of the hub and **both carry the
                // same payload**, so the second tag written here has to be the same record.
                //
                // Without this the second tag was a different serial, so it was a different
                // identity, so it became a second spool in the inventory — which is what "the tags
                // did not save" actually was.
                self.tagModel.draft.serialNumber = summary.record.serialNumber
                return
            }
            inventoryModel.logWrittenSpool(record: summary.record,
                                           materialLabel: summary.materialLabel,
                                           materialType: materialType)
        }
    }

    /// Fills the Write screen from an untagged spool that is about to be given a tag.
    ///
    /// Everything the tag stores comes from the spool: the filament id, the colour and the weight.
    /// The **serial is allocated fresh** rather than reused — an untagged spool has none, and the
    /// one it will carry has to be unique to it, because serial plus filament plus colour is how a
    /// tag is matched back to a record (see `SpoolIdentity`). Copying a serial from anywhere would
    /// be the one way to make two spools indistinguishable.
    ///
    /// The binding to the spool itself lives in `InventoryViewModel.awaitingTagFor`; this only
    /// composes the draft.
    @MainActor
    func loadForTagging(_ spool: Spool) {
        let id = spool.identity?.filamentId ?? ""
        // The tag's filamentId is a leading class digit plus the catalogue's 5-digit base id.
        tagModel.draft.materialID = id.count == 6 ? String(id.dropFirst()) : id
        tagModel.draft.materialLabel = [spool.brand, spool.name]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        tagModel.draft.serialNumber = SpoolRecord.randomSerialNumber()
        tagModel.draft.weight = FilamentLength.forGrams(spool.netWeightGrams) ?? .kg1
        if let colour = Color(tagHex: spool.colorHex) { tagModel.draft.color = colour }
    }

    static let tagMemoryWindowID = "tag-memory"
    static let materialsWindowID = "materials"
    static let printersWindowID = "printers"
    static let locationsWindowID = "locations"
}

// MARK: - App

/// The scene graph. `@main` lives in the `Spoolworks` executable target rather than here, because a
/// target containing `@main` cannot be depended upon — and without a dependency the UI state
/// machine could not be unit-tested at all. See Package.swift.
public struct SpoolworksApp: App {
    public init() {}

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment()

    public var body: some Scene {
        WindowGroup("Spoolworks") {
            RootView(env: env)
                .frame(minWidth: Theme.windowMinWidth, minHeight: Theme.windowMinHeight)
                .onAppear { delegate.environment = env }
        }
        // The Windows window is a fixed 383 × 657 with maximize disabled
        // (`MainForm.Designer.cs:376,393-395`). §8.1: a fixed-pixel window reads as broken on
        // macOS. Content-min-size resizability keeps a sensible floor and no ceiling.
        .windowResizability(.contentMinSize)
        .defaultSize(width: Theme.windowIdealWidth, height: Theme.windowIdealHeight)
        // The monitor and the tag model are observed individually as well as through `env`: the
        // menu items' `disabled` state depends on *their* publishers, and observing only the
        // environment would leave it frozen at whatever it was when the menu bar was built.
        .commands { SpoolworksCommands(env: env, monitor: env.monitor, tagModel: env.tagModel) }

        // Materials and Printers are windows rather than sidebar destinations.
        //
        // The design's sidebar has exactly five entries and a read-only "Material database"
        // footer, so neither screen has a place in it. But both are still needed — the catalogue
        // is what turns a filament id into a name on the Intake and Write screens, and the printer
        // list is where the address and password the CFS poll needs are entered. Dropping them
        // from the sidebar without rehousing them made the Printer & CFS screen tell users to
        // "add one on the Printers screen" while offering no way to reach it.
        //
        // Each window is its own scene, so each needs its own `.toast(env.toasts)`: the one in
        // `RootView` only reaches the main window's hierarchy, and both of these views read the
        // centre through `@EnvironmentObject`, which traps when it is missing. Adding a printer
        // from this window used to crash on exactly that.
        Window("Materials", id: AppEnvironment.materialsWindowID) {
            MaterialsView(model: env.materialsModel).toast(env.toasts).nonRestorableWindow()
        }
        .defaultSize(width: 900, height: 640)

        Window("Printers", id: AppEnvironment.printersWindowID) {
            PrintersView(model: env.printerModel).toast(env.toasts).nonRestorableWindow()
        }
        .defaultSize(width: 820, height: 600)

        // Locations is a window for the same reason as the two above: it is a list you sit down and
        // edit, not a switch. It began as a panel inside the Inventory detail rail, which put
        // renaming a shelf behind first selecting a spool you did not care about.
        Window("Locations", id: AppEnvironment.locationsWindowID) {
            LocationsView(model: env.inventoryModel).nonRestorableWindow()
        }
        .defaultSize(width: 540, height: 640)

        // Tag Memory is a reference view you keep open next to the main window, not a sheet.
        // The Windows author gave `TagMemoryForm` its own taskbar entry — the same instinct.
        Window("Tag Memory", id: AppEnvironment.tagMemoryWindowID) {
            TagMemoryView(monitor: env.monitor, settings: env.settings).nonRestorableWindow()
        }
        .defaultSize(width: 680, height: 640)
        .keyboardShortcut("m", modifiers: .command)

        // There is deliberately no `Settings` scene. §8.1 required that *if* there are app
        // preferences they must be the ⌘, scene rather than a modal dialog — and there are now no
        // app preferences left to put there. The pane's two switches moved next to what they
        // affect (see `ReaderPane`), and its reader diagnostics became a sidebar destination.
        // Omitting the scene is also what removes "Settings…" from the app menu, so ⌘, no longer
        // advertises a window that does not exist.
    }
}

// MARK: - Menu bar

/// The menu bar the Windows app does not have at all (`CFS-RFID.csproj:8`).
///
/// Every sidebar action is also a menu item, so the whole app is reachable from the keyboard.
/// ⌘W is deliberately left to "Close Window"; the write command takes ⇧⌘W as §8.1 suggests.
struct SpoolworksCommands: Commands {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var tagModel: TagViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Nothing in this app creates a document.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Manage") {
            Button("Materials…") { openWindow(id: AppEnvironment.materialsWindowID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Printers…") { openWindow(id: AppEnvironment.printersWindowID) }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button("Locations…") { openWindow(id: AppEnvironment.locationsWindowID) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
        }

        CommandMenu("Tag") {
            Button("Read Tag") {
                env.sidebarSelection = .identify
                Task { await tagModel.read() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!tagModel.canRead)

            Button("Write Tag…") {
                // The sheet this raises lives in the Write screen, so bring that screen up
                // first. Without this the plan was built against a screen that did not exist, and
                // the pending plan then blocked auto-write until something else cleared it.
                env.sidebarSelection = .write
                Task { await tagModel.prepareWrite() }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!tagModel.canWrite)

            Divider()

            Button("Read Tag Memory") {
                openWindow(id: AppEnvironment.tagMemoryWindowID)
            }
            .keyboardShortcut("m", modifiers: .command)

            Divider()

            Button("Rescan for Readers") {
                Task { await monitor.retry() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}

// MARK: - Lifecycle

/// Minimal delegate. Its only real job is releasing the PC/SC context on the way out.
///
/// The Windows app calls `Environment.Exit(0)` from `FormClosed` (`MainForm.cs:928-931`), a hard
/// kill that bypasses every cleanup path — explicitly called out in §8.1 as something not to port.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the root scene once the environment exists.
    @MainActor var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: false)
    }

    // NOTE: do not give this class a custom `init()`.
    //
    // An `override init()` here — added to register a defaults value before the scenes were
    // built — stopped the app initialising at all: the header showed "none configured", the
    // reader stayed at "starting…" and the catalogue reported 0 materials, because every async
    // task kicked off from `RootView.onAppear` silently never ran. No crash, nothing on stderr.
    // `@NSApplicationDelegateAdaptor` owns this type's lifetime and does not expect to share it.
    // Window restoration is handled per-window by `nonRestorableWindow()` instead.

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            environment?.monitor.stop()
            // The polls outlive any one screen now, so quitting is what ends them.
            environment?.cfsModel.stopAutoPoll()
        }
    }
}
