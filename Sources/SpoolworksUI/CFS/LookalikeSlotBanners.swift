import SwiftUI
import SpoolworksCore

/// Asks whether a spool the printer has just read is the untagged one already in stock.
///
/// The situation: a Creality spool was counted onto a shelf still sealed in its bag, so it went
/// into stock with no tag, and has now been opened and loaded. The CFS reads its tag, but a factory
/// tag names a filament and a colour, not a spool — so the poll cannot tell this spool from any
/// other of its kind, and would otherwise have "discovered" it as a second record beside the one
/// the user made. ``SpoolworksCore/SpoolInventory/LookalikeSlot`` holds the slot back instead.
///
/// Nothing needs scanning, which is the point of asking here rather than sending the user to the
/// reader: the printer has already read the tag, and both sides of a factory spool carry the same
/// record.
///
/// Until it is answered the slot has no spool, so a print drawing from it is held by the job
/// tracker rather than charged to a guess; the answer releases it on the next poll.
struct LookalikeSlotBanners: View {
    /// Observed directly — `AppEnvironment` holds it as a plain `let`, and a nested
    /// `ObservableObject` does not republish through its owner.
    @ObservedObject var inventory: InventoryViewModel

    var body: some View {
        if !inventory.pendingLookalikes.isEmpty {
            VStack(spacing: Theme.Spacing.s) {
                ForEach(inventory.pendingLookalikes) { held in
                    prompt(held)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func prompt(_ held: SpoolInventory.LookalikeSlot) -> some View {
        let candidates = held.candidates.compactMap { inventory.inventory.spool(id: $0) }
        if let first = candidates.first {
            SpoolPrompt(message: message(held, first)) {
                Button("Yes, it's that spool") { inventory.confirmLookalike(held, as: first.id) }
                if candidates.count > 1 {
                    Menu("It's a different one") {
                        ForEach(candidates.dropFirst()) { spool in
                            Button("\(spool.label) · \(spool.location.description)") {
                                inventory.confirmLookalike(held, as: spool.id)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button("No, it's a new spool") { inventory.declineLookalike(held) }
            }
        }
    }

    private func message(_ held: SpoolInventory.LookalikeSlot, _ spool: Spool) -> String {
        let slot = held.slot
        let name = [slot.brand, slot.name].filter { !$0.isEmpty }.joined(separator: " ")
        let colour = inventory.colorName(forHex: slot.rgbHex)
        let what = (name.isEmpty ? "filament \(held.identity.filamentId)" : name)
            + " · " + (colour.isEmpty ? "#\(slot.rgbHex)" : colour)
        let source = slot.hasTag
            ? "The printer has read its tag, so there is nothing to scan."
            : "The slot was set by hand on the printer."
        return "The spool just loaded into \(held.location.description) is \(what) — like "
            + "\(spool.label), which is in stock without a tag (\(spool.location.description)). "
            + "Is it that spool? \(source)"
    }
}
