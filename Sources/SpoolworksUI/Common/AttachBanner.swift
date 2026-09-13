import SwiftUI
import SpoolworksCore

/// A sentence about one spool, with the answers to it underneath.
///
/// Every "is this that spool?" question in the app has the same shape — attach a tag to an untagged
/// spool, add a twin, bind a CFS slot — and they are asked on four screens. One component keeps
/// the four from drifting apart in wording, weight and where the buttons sit.
///
/// The buttons go **under** the sentence rather than beside it. The sentences are long, because
/// they have to say why the app cannot tell on its own, and a row of two or three buttons squeezed
/// in beside one wraps it into a column a word wide.
struct SpoolPrompt<Actions: View>: View {
    var symbol = "link"
    var tint = Theme.accent
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(Theme.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Spacing.s) {
                actions
            }
            .buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
            // Aligned with the sentence, not the symbol, so the answers read as belonging to it.
            .padding(.leading, 22)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(Rectangle().strokeBorder(tint, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Says which spool the next tag will be attached to, and offers a way out.
///
/// Shown on both Read / identify and Write tag, because a spool can arrive in stock untagged for
/// two different reasons and each has its own remedy: a Creality spool comes already tagged but
/// sealed in mylar the reader cannot see through, so its factory tag is *read* once the bag is
/// opened; a third-party spool has no tag at all and needs one *written*.
///
/// It earns its space by removing an ambiguity that is otherwise invisible. Without it the two
/// screens look identical whether the next tag binds to a record already in stock or produces a
/// brand-new one, and those outcomes are not close to each other.
///
/// Worded as what is happening and what to do, not as a rule. "The next tag read is attached to…"
/// read as the app announcing a side effect, and it was on screen at exactly the moment the user
/// needed telling to present a tag.
///
/// Cancelling deliberately leaves everything else alone — in particular the composed write form,
/// whose values were derived from a real spool. Someone changing the destination of a write
/// usually still wants the values in front of them, and clearing them would make "cancel" destroy
/// work rather than redirect it.
struct AttachBanner: View {
    enum Direction {
        /// Reading the factory tag already on the spool.
        case read
        /// Writing a tag onto a spool that has none.
        case write
    }

    let spool: Spool
    let direction: Direction
    let cancel: () -> Void

    private var message: String {
        switch direction {
        case .read:
            return "Attaching tags to \(spool.label), which is in stock without one. Present "
                + "either of its tags — both sides carry the same record, so the order does not "
                + "matter — and then the other."
        case .write:
            return "Writing a tag for \(spool.label), which is in stock without one. Once the "
                + "write is verified it is saved to that spool."
        }
    }

    var body: some View {
        SpoolPrompt(message: message) {
            Button("Not this spool", action: cancel)
                .accessibilityLabel("Stop attaching a tag to \(spool.label)")
        }
    }
}

/// The two sides of a spool whose first tag has just been attached by reading.
///
/// Stays up after the second side lands, in green, until the next spool: the hero on Read /
/// identify shows *a* spool, and with factory tags alike across every spool of a filament and
/// colour, "which record did this tag just go to" is the one question it cannot answer itself.
struct PairingBanner: View {
    let spool: Spool
    let pairing: InventoryViewModel.TagPairing
    /// Why the last tag presented was not the other side, if it was not.
    let problem: String?
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if pairing.isComplete {
                SpoolPrompt(symbol: "checkmark.circle.fill",
                            tint: Theme.success,
                            message: "Both tags attached to \(spool.label). Either side now "
                                + "identifies it.") {
                    Button("Done", action: finish)
                }
            } else {
                SpoolPrompt(message: "Tag 1 of 2 attached to \(spool.label). Turn the spool over "
                                + "and present the tag on the other side of the hub to confirm the "
                                + "pair.") {
                    Button("One side is enough", action: finish)
                        .help("Stops waiting. The spool keeps the tag already attached.")
                }
            }
            if let problem {
                InlineFailure(text: problem)
            }
        }
    }
}
