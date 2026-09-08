import SwiftUI
import SpoolworksCore

/// Everything known about the reader hardware, as a first-class screen.
///
/// This replaces the `Settings` scene entirely (`SPEC/03-ui.md` §5.2, previously `SettingsForm`).
/// The preferences pane it grew out of had three tabs, and two of them were text: the General tab
/// only *described* behaviour that was not configurable, and the Advanced tab held two switches,
/// one of which now lives next to the thing it governs. What was genuinely useful in it — the
/// reader diagnostics — was buried three levels deep behind ⌘, in a tab called "Reader", which is
/// the wrong place for the answer to "why is nothing happening when I put a tag down".
///
/// So the diagnostics are promoted to a sidebar destination and the pane is gone. Where the two
/// surviving preferences went:
///
/// * **`advancedTagOperations`** — the gate on rewriting a sector trailer. A real safety control,
///   so it did not silently disappear and it still defaults to *off*. It is surfaced twice, both
///   times next to the operation it governs: on the Auto-Write card in Write mode, and in the
///   write confirmation sheet's trailer warning. Nothing writes a sector key while it is off.
/// * **`showKeyMaterial`** — display-only, and both its effects (the key rows on the tag screen
///   and the unmasked trailers in the memory inspector) are diagnostic. It lives here.
///
/// Everything shown comes from ``ReaderMonitor``'s published state. This screen opens no PC/SC
/// context of its own; it must not contend with the poll loop for the reader.
struct ReaderPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: ReaderMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                statusCard
                if let card = monitor.state.card { tagCard(card) }
                diagnosticsCard
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Reader")
    }

    // MARK: Reader

    private var statusCard: some View {
        Card("Reader", symbol: "wave.3.right", accessory: AnyView(pill)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ValueRow(label: "Status", value: statusText, monospaced: false, copyable: false)

                // The *device*, never a slot count. One ACR1552 publishes two PC/SC slots and
                // calling that "2 readers" is a lie about the user's hardware; the slots are
                // listed separately, below, as the secondary detail they are.
                if deviceNames.isEmpty {
                    ValueRow(label: "Device", value: "none", monospaced: false, copyable: false)
                } else {
                    ValueRow(label: deviceNames.count > 1 ? "Devices" : "Device",
                             value: deviceNames.joined(separator: ", "),
                             monospaced: false)
                }

                if !monitor.slots.isEmpty { slotList }

                ValueRow(label: "Firmware",
                         value: monitor.state.card?.firmware ?? "not reported",
                         monospaced: false, copyable: monitor.state.card?.firmware != nil)
                ValueRow(label: "Poll interval", value: ReaderMonitor.pollIntervalDescription,
                         monospaced: false, copyable: false)

                Text("macOS does not support SCARD_SHARE_DIRECT (DECISIONS D-005), so reader "
                     + "firmware and other reader escapes are only answerable while a card is "
                     + "present.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Rescan Now") { Task { await monitor.retry() } }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                        .help("Rebuilds the PC/SC context and polls immediately (⌥⌘R)")
                }
            }
        }
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("PC/SC slots")
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
            ForEach(monitor.slots, id: \.self) { slot in
                let holdsTag = slot == monitor.state.card?.readerName
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: holdsTag ? "smallcircle.filled.circle" : "circle")
                        .imageScale(.small)
                        .foregroundStyle(holdsTag ? Theme.success : Theme.tertiaryLabel)
                        .accessibilityHidden(true)
                    Text(slot)
                        .font(Theme.monoSmall)
                        .textSelection(.enabled)
                    if holdsTag {
                        Text("holds the tag")
                            .font(.caption)
                            .foregroundStyle(Theme.success)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(holdsTag ? "Slot \(slot), holding the tag" : "Slot \(slot)")
            }
            Text("Slots belonging to one physical reader are polled individually and shown as a "
                 + "single device above.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tag

    private func tagCard(_ card: CardIdentity) -> some View {
        Card("Tag on the Reader", symbol: "tag", accessory: AnyView(tagPill(card))) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ValueRow(label: "Tag ID", value: card.uidSpaced)
                ValueRow(label: "Card type", value: card.type.description,
                         monospaced: false, copyable: false)
                ValueRow(label: "ATR",
                         value: card.atr.isEmpty ? "not returned" : card.atr.hexStringSpaced,
                         copyable: !card.atr.isEmpty)
                ValueRow(label: "Slot", value: card.readerName, monospaced: false)
                if let failure = card.uidFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func tagPill(_ card: CardIdentity) -> some View {
        card.isUsable
            ? StatusPill(symbol: "checkmark.seal.fill", text: "Supported", tone: .good)
            : StatusPill(symbol: "questionmark.circle.fill", text: "Unsupported", tone: .caution)
    }

    // MARK: Diagnostics

    private var diagnosticsCard: some View {
        Card("Diagnostics", symbol: "stethoscope") {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Toggle("Show key material", isOn: $settings.showKeyMaterial)
                Text("Reveals the UID-derived sector key on the tag screen and unmasks the key "
                     + "bytes of every sector trailer in the memory inspector (⌘M). Access bits "
                     + "are always visible either way.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Derived

    private var deviceNames: [String] {
        let named = monitor.state.deviceNames
        guard named.isEmpty else { return named }
        return ReaderNaming.devices(from: monitor.slots)
    }

    private var statusText: String {
        switch monitor.state {
        case .starting: return "Starting"
        case let .subsystemUnavailable(message): return "PC/SC unavailable — \(message)"
        case .noReader: return "No reader connected"
        case let .idle(_, note):
            return note.map { "Reader ready, no tag — \($0)" } ?? "Reader ready, no tag"
        case .cardPresent: return "Tag on the reader"
        }
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
                              text: "Ready — no tag", tone: .neutral)
        case .cardPresent:
            return StatusPill(symbol: "checkmark.seal.fill", text: "Tag present", tone: .good)
        }
    }
}
