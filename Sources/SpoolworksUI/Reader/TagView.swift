import SwiftUI
import AppKit
import SpoolworksCore

/// The primary screen: what is on the tag, and what to write to it.
///
/// ## One layout, two modes
///
/// The screen is a **mode selector**, not a pair of actions, and both modes render the *same*
/// form — ``TagFormCard`` — with the same rows in the same order. Read mode fills those rows from
/// the tag and renders them as text; Write mode fills them from the draft and renders them as
/// controls. Flipping the switch therefore changes what a row *is*, never where it is.
///
/// That is a deliberate correction of the earlier design, which had two structurally different
/// screens plus a family of full-page empty states, so that "read a tag, then write one like it"
/// meant re-learning the layout twice and watching the whole page swap out whenever a tag was
/// lifted. Empty and unusual states are now one quiet line inside the same form.
///
/// ## Nothing waits to be clicked
///
/// Reading is automatic on arrival (``TagViewModel/autoReadIfNeeded(card:)``) and, in Write mode,
/// so is writing (``TagViewModel/autoWriteIfNeeded(card:allowTrailerWrite:)``). There is therefore
/// no action bar: the only control at the bottom is the mode switch. ⌘R and ⇧⌘W remain, on the Tag
/// menu, for forcing either action by hand.
///
/// Replaces `MainForm` (`SPEC/03-ui.md` §5.1). Structural differences, all deliberate:
///
/// * **Resizable.** The Windows window is a fixed 383 × 657 with `MaximizeBox = false`
///   (`MainForm.Designer.cs:376,393-395`).
/// * **Every state is drawn.** The Windows app has one clickable status label and a toast; each
///   distinguishable hardware and tag state here is rendered as words.
struct TagView: View {

    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var model: TagViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            AppHeaderBar(monitor: monitor)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if let notice = HardwareNotice(monitor: monitor) {
                        HardwareNoticeBanner(notice: notice, monitor: monitor)
                    }

                    // The one thing whose position never changes between modes.
                    TagFormCard(monitor: monitor, model: model)

                    if model.mode == .write {
                        AutoWriteCard(monitor: monitor, model: model, settings: settings)
                    }
                    if let outcome = model.writeOutcome {
                        WriteOutcomeCard(outcome: outcome, model: model)
                    }
                    if model.mode == .read {
                        ReadDetailCard(model: model, settings: settings)
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            ModeBar(model: model)
        }
        .background(Theme.background)
        // Deliberately no card `onChange` here any more.
        //
        // `RootView.detail` is a `@ViewBuilder switch`, so this view is *destroyed* the moment the
        // user selects Reader, Materials or Printers — and with it went every arrival, removal and
        // swap the model needed to keep its bookkeeping straight. The subscription now lives in
        // `TagViewModel.observeReader()`, for the lifetime of the app rather than the lifetime of
        // a sidebar selection. The same goes for the mode change, which the model's `mode`
        // observer drives. What is still absent, and must stay absent, is any auto-*write* path
        // out of a mode change: entering Write mode never writes the tag already in hand.
        .task {
            await model.prepareCatalog()
        }
        .task(id: model.draft.colorHex) {
            await model.refreshDraftColorName()
        }
        .sheet(item: $model.pendingPlan) { plan in
            WriteConfirmationSheet(plan: plan, model: model, settings: settings) { confirmed in
                if confirmed {
                    Task { await model.commitWrite(plan, allowTrailerWrite: settings.advancedTagOperations) }
                } else {
                    model.cancelPendingWrite()
                }
            }
        }
    }
}

// MARK: - Header

/// The app's identity, and the reader's state, on one line.
///
/// Replaces the navigation title/subtitle pair, which spent the window's title area on the word
/// "Tag" over a device name that is already on this row.
private struct AppHeaderBar: View {
    @ObservedObject var monitor: ReaderMonitor

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                logo
                Text("K2 RFID")
                    .font(.headline)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("K2 RFID")
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Theme.Spacing.s)

            pill
            if let name = deviceName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                Task { await monitor.retry() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan for readers (⌥⌘R)")
            .accessibilityLabel("Rescan for readers")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.surface)
    }

    /// The bundled app icon, which `Tools/make-app.sh` generates from `reference/app-icon.ico`.
    /// Falls back to a symbol when there is no bundle to read it out of — running the executable
    /// straight from `swift run` is exactly that case, and it should not be a blank square.
    @ViewBuilder
    private var logo: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "wave.3.right.circle.fill")
                .imageScale(.large)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        }
    }

    private var deviceName: String? {
        monitor.state.card?.deviceName ?? monitor.state.deviceNames.first
    }

    private var pill: some View {
        switch monitor.state {
        case .starting:
            return StatusPill(symbol: "hourglass", text: "Starting", tone: .neutral, isBusy: true)
        case .subsystemUnavailable:
            return StatusPill(symbol: "exclamationmark.triangle.fill",
                              text: "PC/SC unavailable", tone: .bad)
        case .noReader:
            return StatusPill(symbol: "cable.connector.slash", text: "No reader", tone: .bad)
        case .idle:
            return StatusPill(symbol: "dot.radiowaves.left.and.right",
                              text: "No tag", tone: .neutral)
        case let .cardPresent(identity):
            return identity.isUsable
                ? StatusPill(symbol: "checkmark.seal.fill", text: "Tag present", tone: .good)
                : StatusPill(symbol: "questionmark.circle.fill",
                             text: "Unsupported tag", tone: .caution)
        }
    }
}

// MARK: - Hardware notices

/// Something about the hardware that stops the screen working, in words.
///
/// The bottom action bar used to carry these as a sentence next to a disabled button. The bar is
/// gone; the sentences are not, because "nothing happens when I put a tag on" needs an answer and
/// a missing reader is the most common one.
private struct HardwareNotice {
    let title: String
    let detail: String?
    let symbol: String
    let tone: Theme.NoticeTone
    let offersRetry: Bool

    @MainActor
    init?(monitor: ReaderMonitor) {
        switch monitor.state {
        case .starting:
            return nil
        case let .subsystemUnavailable(message):
            self.init(title: "The smart card service is unavailable.",
                      detail: message, symbol: "exclamationmark.triangle.fill",
                      tone: .bad, offersRetry: true)
        case .noReader:
            self.init(title: "No reader is connected.",
                      detail: "Connect a PC/SC reader over USB. It is picked up automatically "
                            + "within a second of being plugged in.",
                      symbol: "cable.connector.slash", tone: .bad, offersRetry: true)
        case let .idle(_, note):
            guard let note else { return nil }
            self.init(title: "The reader reported a problem.", detail: note,
                      symbol: "exclamationmark.circle.fill", tone: .caution, offersRetry: true)
        case let .cardPresent(identity):
            guard !identity.isUsable else { return nil }
            self.init(title: "This tag is not one this app can use.",
                      detail: Self.reason(identity), symbol: "questionmark.circle.fill",
                      tone: .caution, offersRetry: false)
        }
    }

    private init(title: String, detail: String?, symbol: String,
                 tone: Theme.NoticeTone, offersRetry: Bool) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tone = tone
        self.offersRetry = offersRetry
    }

    /// Windows says only "Tag not compatible" and disposes the reader handle
    /// (`MainForm.cs:222-230`). Saying *what* was found costs nothing.
    private static func reason(_ identity: CardIdentity) -> String {
        if !identity.type.isSupported {
            return "\(identity.type.description) cannot carry the Creality spool layout. "
                 + "These tags are MIFARE Classic 1K."
        }
        if identity.uid.count != 4 {
            return "This tag has a \(identity.uid.count)-byte UID. The sector-key derivation "
                 + "consumes exactly four UID bytes, so a longer UID would silently produce the "
                 + "wrong key."
        }
        return identity.uidFailure ?? "The tag did not identify itself."
    }
}

extension Theme {
    /// The two tones a notice can carry. Never colour alone — every notice has a symbol and text.
    enum NoticeTone {
        case caution
        case bad

        var color: Color { self == .bad ? Theme.danger : Theme.warning }
    }
}

private struct HardwareNoticeBanner: View {
    let notice: HardwareNotice
    @ObservedObject var monitor: ReaderMonitor

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(notice.title)
                    .font(.callout.weight(.medium))
                if let detail = notice.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if notice.offersRetry {
                Button("Try Again") { Task { await monitor.retry() } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
        .padding(Theme.Spacing.m)
        .background(notice.tone.color.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
            .strokeBorder(notice.tone.color.opacity(0.35), lineWidth: Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title) \(notice.detail ?? "")")
    }
}

// MARK: - Read-only extras

/// The parts of a decoded record the shared form has no row for.
///
/// Read-only by nature — vendor ID, batch, date group and the raw encoded record are not values
/// anyone composes — so they live outside the shared form rather than adding rows that would be
/// permanently blank in Write mode.
private struct ReadDetailCard: View {
    @ObservedObject var model: TagViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        if let read = model.lastRead, !model.activity.supersedesTagContents {
            Card("Tag Details", symbol: "doc.text.magnifyingglass") {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ValueRow(label: "Card type",
                             value: read.isProgrammed
                                 ? "MIFARE Classic 1K, sector 1 keyed"
                                 : "MIFARE Classic 1K, factory key",
                             monospaced: false, copyable: false)
                    if let record = read.record {
                        ValueRow(label: "Vendor ID", value: record.vendorId,
                                 annotation: record.vendorId == SpoolRecord.crealityVendorId
                                     ? "Creality" : nil)
                        ValueRow(label: "Batch", value: record.batch)
                        ValueRow(label: "Date group", value: record.date.encoded)
                        ValueRow(label: "Raw record", value: record.encoded)
                    }
                    if settings.showKeyMaterial {
                        ValueRow(label: "Sector 1 key", value: read.sector1Key.description,
                                 annotation: "key \(read.sector1KeyType.description)")
                        ValueRow(label: "Derived key", value: read.derivedKey.description)
                    }

                    HStack(spacing: Theme.Spacing.m) {
                        Spacer()
                        Button("Clear") { model.clearRetainedRead() }
                            .keyboardShortcut(.delete, modifiers: .command)
                            .help("Forgets this record (⌘⌫). The write form keeps its values.")
                        if read.record != nil {
                            Button("Load into Write Form") {
                                Task { await model.loadDraftFromTag() }
                            }
                            .help("Copies this tag's values into the write form and switches to "
                                  + "Write")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Mode bar

/// The only control that survives at the bottom of the screen.
///
/// The action bar it replaces held a "Read Tag"/"Write Tag…" button and a sentence explaining why
/// that button was disabled. Both actions are automatic now, so the button was an invitation to
/// press something that had already happened, and the sentence explained a control that no longer
/// exists. What remains is the mode switch and, while something is happening, what is happening.
private struct ModeBar: View {
    @ObservedObject var model: TagViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            if model.activity.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(model.activity.label)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Spacer(minLength: 0)

            TagActionSwitch(selection: $model.mode)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
        .background(Theme.surface)
    }
}

// MARK: - Write confirmation

/// The gate a write passes through when it is *not* automatic.
///
/// Still reached three ways: ⇧⌘W, the Tag menu, and auto-write meeting a blank tag while the
/// advanced sector-key opt-in is off. What auto-write changed is that this is no longer the *only*
/// route — see ``TagViewModel/autoWriteIfNeeded(card:allowTrailerWrite:)`` for why that is a
/// deliberate, informed relaxation of D-006 rather than an oversight.
///
/// What it still shows: what is on the tag now, what will be on it afterwards, which rows actually
/// change, that a full backup is taken first, and — when the tag is blank and programming it would
/// rewrite the sector-1 trailer — a separate, explicit opt-in that starts off.
///
/// Cancel is the default button, preserving the deliberate "default = safe" choice the Windows
/// message boxes make (`MainForm.cs:657, 802`).
private struct WriteConfirmationSheet: View {
    let plan: WritePlan
    /// Observed for one reason: the Write button must not look live while the model is holding the
    /// reader. `commitWrite` guards on exactly that, and used to return in silence — so a click
    /// during a ⌘R read did nothing at all and left the sheet sitting there.
    @ObservedObject var model: TagViewModel
    @ObservedObject var settings: AppSettings
    let completion: (Bool) -> Void

    /// Per-write acknowledgement. Always starts off, even for someone programming a batch, so a
    /// trailer write is never a single click.
    @State private var trailerAcknowledged = false
    /// Advanced opt-in held locally for the lifetime of the sheet. Committed to `AppSettings`
    /// only when the write is actually confirmed — see the toggle for why.
    @State private var trailerAdvancedLocal = false
    @FocusState private var cancelFocused: Bool

    /// Two independent gates on a trailer write, per D-006: the persistent advanced opt-in, and
    /// this one write's acknowledgement.
    private var canWrite: Bool {
        guard !model.activity.isRunning else { return false }
        guard plan.requiresTrailerWrite else { return true }
        return trailerAdvancedLocal && trailerAcknowledged
    }

    /// Why the button is off, in the order the user can act on it.
    private var blockedReason: String {
        if model.activity.isRunning { return model.activity.label }
        return "Allow sector-key writes and confirm the change first"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    diffTable
                    if plan.requiresTrailerWrite { trailerWarning }
                    backupNote
                }
                .padding(.vertical, Theme.Spacing.s)
            }
            .frame(maxHeight: 340)

            Divider()
            footer
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 620)
        .background(Theme.background)
        .onAppear {
            cancelFocused = true
            trailerAdvancedLocal = settings.advancedTagOperations
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Write to tag \(plan.uid.hexStringSpaced)?")
                .font(.title3.bold())
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
            if !plan.materialLabel.isEmpty {
                Text(plan.materialLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch plan.currentCondition {
        case .blank:
            return "This tag is blank. Writing programs it for the first time."
        case .programmed:
            return "This tag already holds a spool record. The values below will be replaced."
        case .unrecognisedPayload:
            return "This tag holds data that does not decode as a spool record. It will be replaced."
        }
    }

    private var diffTable: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Changes")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(plan.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                        Text(row.label)
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryLabel)
                            .frame(width: 150, alignment: .leading)
                        Text(row.before)
                            .font(Theme.monoSmall)
                            .foregroundStyle(row.changed ? Theme.secondaryLabel : Theme.tertiaryLabel)
                            .strikethrough(row.changed, color: Theme.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: row.changed ? "arrow.right" : "equal")
                            .imageScale(.small)
                            .foregroundStyle(row.changed ? Theme.accent : Theme.tertiaryLabel)
                            .accessibilityHidden(true)
                        Text(row.after)
                            .font(Theme.monoSmall)
                            .fontWeight(row.changed ? .bold : .regular)
                            .foregroundStyle(row.changed ? Theme.label : Theme.tertiaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .padding(.horizontal, Theme.Spacing.s)
                    .background(row.changed ? Theme.accent.opacity(0.08) : Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.changed
                        ? "\(row.label) changes from \(row.before) to \(row.after)"
                        : "\(row.label) unchanged at \(row.after)")
                }
            }
            .background(Theme.surfaceRecessed,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                .strokeBorder(Theme.separator, lineWidth: Theme.hairline))

            if plan.changedRows.isEmpty && !plan.requiresTrailerWrite {
                Label("Nothing would change. Writing is safe but pointless.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    private var trailerWarning: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("This rewrites the sector 1 keys", systemImage: "key.horizontal.fill")
                .font(.headline)
                .foregroundStyle(Theme.warning)
            Text("Sector 1 is still on the factory key, so programming it writes block 7 — the "
                 + "sector trailer — with the key derived from this tag's UID. The access bits are "
                 + "read and preserved, never authored, and the write is refused outright if they "
                 + "read back as zeros. Even so, a trailer write cannot be undone by this app.")
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            // Gate 1 — advanced opt-in, held LOCALLY while the sheet is open.
            //
            // It deliberately does not write through to AppSettings here. Binding it straight to
            // the persistent setting meant a user who ticked it to satisfy the gate and then
            // pressed Cancel had silently enabled unattended, irreversible trailer writes for
            // every future blank tag. It is committed only if this write is confirmed.
            Toggle("Allow writing sector keys (advanced)", isOn: $trailerAdvancedLocal)
                .toggleStyle(.checkbox)
                .help("Applies to this write. Cancelling leaves your saved setting unchanged.")
            // Gate 2 — this write only. Resets every time the sheet opens.
            Toggle("I understand this permanently changes the tag's sector 1 key",
                   isOn: $trailerAcknowledged)
                .toggleStyle(.checkbox)
                .disabled(!trailerAdvancedLocal)
        }
        .padding(Theme.Spacing.m)
        .background(Theme.warning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
            .strokeBorder(Theme.warning.opacity(0.4), lineWidth: Theme.hairline))
    }

    private var backupNote: some View {
        Label("Every sector that can be authenticated is dumped before the first write. "
              + "You can save that dump from the result panel afterwards.",
              systemImage: "arrow.counterclockwise.circle")
            .font(.callout)
            .foregroundStyle(Theme.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text("Tag ID \(plan.uid.hexStringSpaced)")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.tertiaryLabel)
            Spacer()
            Button("Cancel") { completion(false) }
                .keyboardShortcut(.cancelAction)
                .focused($cancelFocused)
            Button(plan.requiresTrailerWrite ? "Program Tag" : "Write Tag") {
                // Persist the advanced opt-in only now, on an actual confirmation. Cancelling
                // must leave the saved setting exactly as it was.
                if trailerAdvancedLocal { settings.advancedTagOperations = true }
                completion(true)
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canWrite)
                .help(canWrite ? "Writes the values above to the tag" : blockedReason)
        }
    }
}
