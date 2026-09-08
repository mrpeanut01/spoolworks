import SwiftUI
import SpoolworksCore

/// Manage the list of locations a spool can be kept in — `Manage ▸ Locations…` (⇧⌘3).
///
/// ## Why this is a window, having started as a panel under the picker
///
/// The list began inline, under the Location control it configures, on the reasoning ``AppSettings``
/// gives for having no preferences window at all: a setting belongs next to what it affects. That
/// reasoning is right for a *switch*. It is wrong for a *list*, and the difference is that editing a
/// list is a task of its own — renaming three shelves is not something you do while looking at one
/// spool, and doing it inside a 400 pt detail rail meant a text field, a count and a Remove button
/// competing for one line. It also sat behind selecting a spool, so the way to rename a shelf was to
/// click a spool you did not care about first.
///
/// So it is a window, alongside Materials (⇧⌘1) and Printers (⇧⌘2), which are windows for the same
/// reason: they are catalogues, not settings. There is deliberately only **one** editor — the rail
/// now opens this rather than offering a second copy of the same controls.
///
/// ## What the list means
///
/// A name here is one kind of ``SpoolLocation`` — the `.shelf` case, which is anywhere the *user*
/// puts a spool. The other cases are measurements: `.cfs(box:slot:)` and `.externalHolder` are
/// written by the 30-second printer poll and can never be typed in, which is why they are absent
/// here and why the rail shows them without offering them. See `docs/DECISIONS.md` D-011.
///
/// The domain type is `SpoolPlaces` rather than `SpoolLocations` because `SpoolLocation` is already
/// the enum. The vocabulary the user sees is "location" throughout; "place" survives only in code.
struct LocationsView: View {
    @ObservedObject var model: InventoryViewModel

    @State private var newName = ""
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Where you keep spools", title: "Locations")
                    .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Your locations").kicker().padding(.bottom, 12)

                    ForEach(model.places.names, id: \.self) { name in
                        LocationRow(name: name,
                                    count: model.spoolCount(atPlace: name),
                                    rename: { rename(name, to: $0) },
                                    remove: { report(model.removePlace(name)) })
                            // Keyed by the name, so a rename rebuilds the row from the new value
                            // rather than leaving the field showing the old draft.
                            .id(name)
                    }

                    Hairline().padding(.vertical, 12)

                    HStack(spacing: Theme.Spacing.s) {
                        TextField("New location", text: $newName)
                            .textFieldStyle(.plain)
                            .swInput()
                            .onSubmit(add)
                            .accessibilityLabel("Name of a new location")
                        Button("Add", action: add)
                            .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 7))
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Add this location to the list")
                    }

                    if let problem {
                        InlineFailure(text: problem).padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: 20)
                .padding(.bottom, 18)

                unloadDestination.padding(.bottom, 18)

                explanation
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Theme.background)
        .frame(minWidth: 460, minHeight: 380)
    }

    /// Where a spool lands when it comes off the printer.
    ///
    /// The poll used to send it to `Unplaced` and nothing could change that, which is right only
    /// until the user has told the app where their spools live. After that "back on the shelf" is
    /// almost always the truth, and saying so once beats correcting it after every print.
    private var unloadDestination: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("When a spool leaves the printer").kicker()
            HStack(spacing: Theme.Spacing.m) {
                Picker("", selection: Binding(get: { model.places.unloadDestination },
                                              set: { model.setUnloadDestination($0) })) {
                    ForEach(model.places.names, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel("Where a spool goes when it leaves the printer")
                Text("Applied by the 30-second poll, the moment the printer stops reporting it. "
                     + "Each spool gets a line in its history saying which slot it came off.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How these are used").kicker()
            // Composed `Text` values rather than markdown. `Text` only parses markdown out of a
            // string *literal*, so `"**bold**" + "rest"` — an expression — puts the asterisks on
            // screen. `UploadSheet` emphasises a printer's name the same way.
            (bold(SpoolPlaces.unplaced)
                + Text(" is always in the list and cannot be renamed or removed. It is where a "
                       + "spool goes when the printer stops reporting it, so a list that could "
                       + "lose it would strand spools in a state no row can express."))
                .fixedSize(horizontal: false, vertical: true)
            (bold("CFS") + Text(" and ") + bold("Ext…")
                + Text(" are ordinary names with no special power. When a spool is actually "
                       + "loaded the printer says so every 30 seconds, and the spool's own row "
                       + "names that as its source — these two are just convenient labels for "
                       + "putting a spool somewhere by hand."))
                .fixedSize(horizontal: false, vertical: true)
            Text("Removing a location moves everything kept there to \(SpoolPlaces.unplaced), and "
                 + "each spool gets a line in its own history saying so.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.secondaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    private func bold(_ text: String) -> Text {
        Text(text).font(Theme.caption.weight(.bold)).foregroundColor(Theme.label)
    }

    private func add() {
        report(model.addPlace(newName))
        if problem == nil { newName = "" }
    }

    private func rename(_ old: String, to new: String) {
        guard new.trimmingCharacters(in: .whitespaces) != old else { return }
        report(model.renamePlace(old, to: new))
    }

    /// Rejections are shown, not swallowed — the list refuses an edit for four different reasons
    /// and a button that silently does nothing is the worst of them.
    private func report(_ result: PlaceEditResult) {
        problem = result.problem
    }
}

/// One location: rename in place, see what is kept there, remove it.
///
/// Renaming is the field itself committed with Return, rather than a Rename button that swaps the
/// row into an edit state: the row is already a field and the commit is already a keystroke, so the
/// swap only added a mode the user has to notice they are in. The count is there so removing one is
/// never a surprise — a removal that quietly shuffles eleven spools should say eleven *before* it
/// happens, not after.
private struct LocationRow: View {
    let name: String
    let count: Int
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var draft = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if SpoolPlaces.isUnplaced(name) {
                // Reserved: it is where `reconcile` puts a spool the printer has stopped
                // reporting, so the list cannot be allowed to lose it.
                ReadOnlyValue(name)
                SWTag(text: "always", style: .neutral)
            } else {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .swInput()
                    .onSubmit { rename(draft) }
                    .accessibilityLabel("Name of the location \(name)")
                    .accessibilityHint("Press Return to rename it.")
                SWTag(text: count == 0 ? "empty" : "\(count)", style: .neutral)
                    .accessibilityLabel(count == 0
                        ? "Nothing is kept here"
                        : "\(count) spool\(count == 1 ? "" : "s") here")
                Button("Remove", action: remove)
                    .buttonStyle(.sw(.ghost, size: 11, h: 8, v: 4))
                    .accessibilityLabel("Remove the location \(name)")
                    .accessibilityHint(count == 0
                        ? "Nothing is kept here."
                        : "\(count) spool\(count == 1 ? "" : "s") will move to \(SpoolPlaces.unplaced).")
            }
        }
        .padding(.vertical, 4)
        .onAppear { draft = name }
    }
}
