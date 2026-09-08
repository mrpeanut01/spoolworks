//  The pieces of the former single Tag screen that survived the Spoolworks redesign.
//
//  `TagView` itself is gone: the design splits it into Read / identify and Write tag, which are
//  separate sidebar destinations. What remains here is shared by the Write screen —
//  the hardware notice banner and the write confirmation sheet, whose read-back verification and
//  trailer-access-bit checks are the app's write-safety guarantees.

import SwiftUI
import AppKit
import SpoolworksCore
struct HardwareNotice {
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

struct HardwareNoticeBanner: View {
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

struct WriteConfirmationSheet: View {
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
