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
    let completion: (Bool) -> Void

    @FocusState private var cancelFocused: Bool

    /// The sheet itself is the confirmation. A blank tag used to need two further ticks before the
    /// button came alive — an "advanced" opt-in and a per-write acknowledgement — which is three
    /// deliberate acts to do the most ordinary thing this app does. The tag still cannot be
    /// written while the reader is busy, and the trailer rewrite is still spelled out above.
    private var canWrite: Bool { !model.activity.isRunning }

    /// Why the button is off. Only one reason remains.
    private var blockedReason: String { model.activity.label }

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
        .onAppear { cancelFocused = true }
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

    private var subtitle: String { Self.subtitle(for: plan) }

    /// What the sheet says the write does to the tag in hand. A function of the plan alone so a
    /// test can check the wording for a tag state that needs no reader to construct.
    static func subtitle(for plan: WritePlan) -> String {
        // Checked before the condition, because for this tag the condition reads `.programmed`
        // and the "already holds a spool record" copy would be a lie by omission: the keys were
        // never written, so this is a first-time programming that will also overwrite the record.
        if plan.isInterruptedProgramming {
            return "This tag holds a spool record, but its sector-1 keys were never written — its "
                 + "programming was interrupted. Programming it now overwrites that record and "
                 + "writes the keys."
        }
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

    /// What programming a blank tag does, stated once and not dressed as an alarm.
    ///
    /// This used to be a warning-toned panel carrying two checkboxes that had to be ticked before
    /// the Write button came alive. Programming a blank tag is what tagging a new spool *is*, and
    /// the tag has nothing on it to lose, so the gates are gone. The facts stay — a trailer write
    /// is genuinely irreversible, and someone reading this sheet should know it is happening.
    private var trailerWarning: some View {
        Label("Sector 1 is still on the factory key, so programming this tag writes block 7 — the "
              + "sector trailer — with the key derived from its UID. Access bits are read and "
              + "preserved, never authored, and the write is refused outright if they read back "
              + "as zeros. The key change itself cannot be undone by this app.",
              systemImage: "key.horizontal.fill")
            .font(.callout)
            .foregroundStyle(Theme.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
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
            Button(plan.requiresTrailerWrite ? "Program Tag" : "Write Tag") { completion(true) }
                .buttonStyle(.borderedProminent)
                .disabled(!canWrite)
                .help(canWrite ? "Writes the values above to the tag" : blockedReason)
        }
    }
}
