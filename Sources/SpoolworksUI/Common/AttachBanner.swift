import SwiftUI
import SpoolworksCore

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
/// Cancelling deliberately leaves everything else alone — in particular the composed write form,
/// whose values were derived from a real spool. Someone changing the destination of a write
/// usually still wants the values in front of them, and clearing them would make "cancel" destroy
/// work rather than redirect it.
struct AttachBanner: View {
    let spool: Spool
    /// `"read"` or `"written"` — what is about to happen to the tag.
    let what: String
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "link")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("The next tag \(what) is attached to \(spool.label), which is in stock without one.")
                .font(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            Button("Not this one", action: cancel)
                .buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
                .accessibilityLabel("Stop attaching this tag to \(spool.label)")
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
