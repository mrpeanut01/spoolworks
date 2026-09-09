import SwiftUI
import SpoolworksCore

// MARK: - One row

/// One row of the shared tag form.
///
/// Both modes build their rows through this, which is the mechanism behind "Read and Write look
/// nearly identical": the label column is one width everywhere, the row floor is one height
/// everywhere, and the only thing that differs between a read row and a write row is what is on
/// the right of it. Flipping the mode switch cannot move a row, because there is only one row
/// definition and both modes use it in the same order.
enum TagFormMetrics {
    /// Matches ``ValueRow``'s label column, so rows built either way line up.
    static let labelWidth: CGFloat = 132
}

struct TagFormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(width: TagFormMetrics.labelWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        // A read row is text and a write row is a control; without a floor the form would visibly
        // shrink when the mode switch is flipped, which is exactly what "same shape" rules out.
        .frame(minHeight: 24)
    }
}

/// The placeholder every unknown value uses, in both modes.
private let emptyValue = "—"

// MARK: - The shared form

/// The one form both modes render: same rows, same order, same labels, same geometry.
///
/// Read mode fills it from the tag and renders plain text. Write mode fills it from the draft and
/// renders controls. Disabled controls were rejected for the read case on purpose — a greyed-out
/// picker reads as *broken*, not as *informational*, and a screen reader announces it as an
/// unavailable control rather than as a value.
///
/// The Windows cascade (`printer → brand → material → weight → colour`, `MainForm.cs:723-736,
/// 938-956, 698-712`) is preserved exactly in the editable case; picking a printer family reloads
/// the catalogue and repopulates brands, picking a brand repopulates materials and selects the
/// first, and picking a material resolves the `base.id` that is written to the tag.
struct TagFormCard: View {
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var model: TagViewModel
    @ObservedObject private var catalog: MaterialCatalog

    init(monitor: ReaderMonitor, model: TagViewModel) {
        self.monitor = monitor
        self.model = model
        self.catalog = model.catalog
    }

    private var isEditable: Bool { model.mode == .write }

    /// The record Read mode displays. Nil while a read is in flight, on a blank tag, and before
    /// anything has been read.
    private var record: SpoolRecord? {
        model.activity.supersedesTagContents ? nil : model.condition?.record
    }

    var body: some View {
        Card("Spool Tag", symbol: "tag", accessory: AnyView(statePill)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                TagFormRow(label: "Tag ID") { tagID }
                Divider()
                TagFormRow(label: "Printer") { printer }
                TagFormRow(label: "Brand") { brand }
                TagFormRow(label: "Material") { material }
                TagFormRow(label: "Material ID") { materialID }
                TagFormRow(label: "Weight") { weight }
                TagFormRow(label: "Colour") { colour }
                // The serial is deliberately not editable and not a form field. It is generated
                // per draft and regenerated after every write, because a serial the user can set
                // is a serial two spools can share — and 000001, the value the Windows app writes,
                // is already shared by the entire Creality catalogue. It is shown read-only beside
                // the payload, where it belongs with the other derived values.
                if !isEditable {
                    TagFormRow(label: "Serial number") { serial }
                }

                footer
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var tagID: some View {
        // Identical in both modes: the tag on the reader is a fact, never a composed value.
        let uid = monitor.state.card?.uidSpaced ?? model.lastRead?.uid.hexStringSpaced
        let isLive = monitor.state.card != nil
        HStack(spacing: Theme.Spacing.s) {
            Text(uid ?? emptyValue)
                .font(Theme.mono)
                .textSelection(.enabled)
            if uid != nil, !isLive {
                // The quiet indicator that replaces the old "Last Tag Read" block: the record is
                // still shown, it just says which tag it belongs to and that the tag is gone.
                Text("not on the reader")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryLabel)
            }
            if let uid {
                CopyButton(value: uid, what: "Tag ID")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag ID, \(uid ?? "none")"
                            + (uid != nil && !isLive ? ", not on the reader" : ""))
    }

    @ViewBuilder
    private var printer: some View {
        if isEditable {
            Picker("Printer", selection: printerBinding) {
                Text("None").tag(PrinterType?.none)
                ForEach(PrinterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(PrinterType?.some(type))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .help("Chooses the material catalogue, and is written to sector 2 in plaintext.")
        } else {
            // Sector 2 holds a free-text string. Show the family name when it names one, and the
            // raw string otherwise — the tag is the authority, not the picker's list.
            let raw = model.lastRead?.printerType.flatMap { $0.isEmpty ? nil : $0 }
            readOnly(raw.map { PrinterType(identifying: $0)?.displayName ?? $0 })
        }
    }

    @ViewBuilder
    private var brand: some View {
        if isEditable, model.usesCatalog {
            Picker("Brand", selection: vendorBinding) {
                ForEach(catalog.vendors, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(catalog.vendors.isEmpty)
        } else if isEditable {
            readOnly(nil, hint: "Typing the material ID directly")
        } else {
            readOnly(filament(for: record?.materialId)?.vendor)
        }
    }

    @ViewBuilder
    private var material: some View {
        if isEditable, model.usesCatalog {
            Picker("Material", selection: materialBinding) {
                ForEach(model.materialsForSelectedVendor) { filament in
                    Text(label(for: filament)).tag(filament.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(model.materialsForSelectedVendor.isEmpty)
        } else if isEditable {
            readOnly(nil, hint: "Typing the material ID directly")
        } else {
            readOnly(filament(for: record?.materialId).map(label(for:)))
        }
    }

    @ViewBuilder
    private var materialID: some View {
        if isEditable, model.usesCatalog {
            HStack(spacing: Theme.Spacing.s) {
                Text(model.draft.materialID.isEmpty ? emptyValue : model.draft.materialID)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                Button("Enter Manually") { model.manualMaterialEntry = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Types the five-character base.id by hand instead of picking it")
            }
        } else if isEditable {
            HStack(spacing: Theme.Spacing.s) {
                TextField("Material ID", text: $model.draft.materialID, prompt: Text("00001"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono)
                    .frame(width: 110)
                    .labelsHidden()
                    .accessibilityLabel("Material ID")
                    .help("The five-character base.id from the material database")
                if catalog.isReady {
                    Button("Use the Catalogue") {
                        model.manualMaterialEntry = false
                        model.selectMaterial(id: model.draft.materialID)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        } else {
            readOnly(record?.materialId, monospaced: true)
        }
    }

    @ViewBuilder
    private var weight: some View {
        if isEditable {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Weight", selection: $model.draft.weight) {
                    ForEach(FilamentLength.allCases, id: \.self) { length in
                        // The ones Creality never published are marked in the list itself, so the
                        // choice is informed rather than explained after the fact.
                        Text(length.isCrealityStandard ? length.label : "\(length.label) ·  non-standard")
                            .tag(length)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)

                if !model.draft.weight.isCrealityStandard {
                    Label("Creality's printer and apps will read this tag as 1 KG — the length code is legal but not one they publish. Spoolworks reads it correctly.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
        } else {
            readOnly(record.map { $0.knownLength?.label ?? "\($0.weightGrams) g" })
        }
    }

    @ViewBuilder
    private var colour: some View {
        if isEditable {
            FilamentColorField(color: $model.draft.color,
                               isEditable: true,
                               catalogue: catalogueSwatch,
                               recents: recentSwatches,
                               brand: model.selectedVendor)
        } else if let hex = record?.rgbHex, let colour = Color(tagHex: hex) {
            FilamentColorField(color: .constant(colour),
                               isEditable: false,
                               catalogue: nil,
                               recents: [])
        } else {
            readOnly(nil)
        }
    }

    @ViewBuilder
    private var serial: some View {
        if isEditable {
            TextField("Serial number", text: $model.draft.serialNumber)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono)
                .frame(width: 110)
                .labelsHidden()
                .accessibilityLabel("Serial number")
                .help("Six digits. The Windows app always writes 000001.")
        } else {
            readOnly(record?.serialNumber, monospaced: true)
        }
    }

    /// A value, or the placeholder, rendered as plain selectable text.
    private func readOnly(_ value: String?, monospaced: Bool = false, hint: String? = nil) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(value ?? emptyValue)
                .font(monospaced ? Theme.mono : .callout)
                .foregroundStyle(value == nil ? Theme.tertiaryLabel : Theme.label)
                .textSelection(.enabled)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
    }

    // MARK: Footer

    /// Everything the rows themselves cannot say: what state the tag is in, where the composed
    /// values came from, and what is wrong with them.
    @ViewBuilder
    private var footer: some View {
        let lines = footerNotes
        if !lines.isEmpty || provenance != nil || (isEditable && !model.draft.validationIssues.isEmpty) {
            Divider()
                .padding(.top, Theme.Spacing.xs)
        }

        ForEach(lines, id: \.self) { line in
            Text(line)
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }

        if isEditable, let provenance {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(provenance)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.s)
                if !model.draftMatchesPrefill, model.prefill != nil {
                    Button("Use Tag Values") { Task { await model.applyPrefill() } }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Button("Reset") { Task { await model.resetDraft() } }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Empties the form back to the app defaults")
            }
        }

        if isEditable, !model.draft.validationIssues.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(model.draft.validationIssues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Form problems")
        }
    }

    /// The one quiet inline sentence the empty and unusual states get, instead of a whole
    /// different screen. The layout never changes; only this line does.
    private var footerNotes: [String] {
        if model.activity.supersedesTagContents { return [model.activity.label] }
        if isEditable {
            if case let .unavailable(reason) = catalog.state {
                return ["Catalogue unavailable — \(reason) Enter the material ID by hand."]
            }
            return []
        }
        if let failure = model.readFailure {
            return ["This tag could not be read — \(failure)",
                    "Sector 1 did not open with either the UID-derived key or the factory key."]
        }
        switch model.condition {
        case .none:
            return monitor.state.card == nil
                ? ["Place a tag on the reader. It is read automatically."]
                : ["Not read yet. Reading starts on its own; ⌘R tries again."]
        case .some(.blank):
            return ["This tag is blank: sector 1 opened with the factory key and holds no spool "
                    + "record. Writing it programs it for the first time."]
        case let .some(.unrecognisedPayload(reason)):
            return ["This tag was programmed by an app in this family, but sector 1 does not "
                    + "decode to a spool record.", reason]
        case .some(.programmed):
            return []
        }
    }

    /// Where the values in the write form came from. Prefilling silently would be a trap: "write
    /// the same spool again" and "write something new" produce identical-looking forms.
    private var provenance: String? {
        guard let prefill = model.prefill else { return nil }
        guard model.draftSourceUID == prefill.uid else {
            return "Tag \(prefill.uidSpaced) was read. Its values are not in this form."
        }
        if model.draftIsEdited { return "Edited — started from tag \(prefill.uidSpaced)." }
        return model.draftCarriesFreshSerial
            ? "These values were read from tag \(prefill.uidSpaced), with a new serial."
            : "These values were read from tag \(prefill.uidSpaced)."
    }

    // MARK: Accessory

    @ViewBuilder
    private var statePill: some View {
        if model.activity.isRunning {
            StatusPill(symbol: "hourglass", text: shortActivity, tone: .active, isBusy: true)
        } else if model.readFailure != nil {
            StatusPill(symbol: "exclamationmark.triangle.fill", text: "Unreadable", tone: .bad)
        } else {
            switch model.condition {
            case .none:
                StatusPill(symbol: "questionmark.circle", text: "No tag read", tone: .neutral)
            case .some(.blank):
                StatusPill(symbol: "square.dashed", text: "Blank tag", tone: .neutral)
            case .some(.programmed):
                StatusPill(symbol: "checkmark.seal.fill", text: "Programmed", tone: .good)
            case .some(.unrecognisedPayload):
                StatusPill(symbol: "questionmark.square.dashed",
                           text: "Unrecognised", tone: .caution)
            }
        }
    }

    private var shortActivity: String {
        switch model.activity {
        case .idle: return ""
        case .reading: return "Reading"
        case .preparingWrite: return "Checking"
        case .writing: return "Writing"
        }
    }

    // MARK: Colour palette sources

    /// The selected filament's own colour, when the database carries something that is not the
    /// `#ffffff`/`#000000` placeholder every shipped record holds.
    private var catalogueSwatch: PaletteSwatch? {
        PaletteSwatch.catalogue(for: catalog.filament(id: model.draft.materialID))
    }

    /// What this user has actually read or written, most recent first.
    private var recentSwatches: [PaletteSwatch] {
        model.recentColors.map { PaletteSwatch(hex: $0, source: .recent) }
    }

    // MARK: Cascade bindings
    //
    // Plain `Binding`s rather than `@Published` `didSet` chains: each step has to run the *next*
    // step, and a `didSet` cascade would re-enter itself the moment a step assigned to a property
    // an earlier step also writes.

    private var printerBinding: Binding<PrinterType?> {
        Binding(get: { model.draft.printerType },
                set: { new in Task { await model.printerTypeChanged(to: new) } })
    }

    private var vendorBinding: Binding<String> {
        Binding(get: { model.selectedVendor },
                set: { model.selectVendor($0) })
    }

    private var materialBinding: Binding<String> {
        Binding(get: { model.draft.materialID },
                set: { model.selectMaterial(id: $0) })
    }

    private func filament(for id: String?) -> Filament? {
        guard let id else { return nil }
        return catalog.filament(id: id)
    }

    private func label(for filament: Filament) -> String {
        filament.materialType.isEmpty || filament.name.contains(filament.materialType)
            ? filament.name
            : "\(filament.name) · \(filament.materialType)"
    }
}

// MARK: - Auto-write

/// The armed-state indicator and the off switch for auto-write.
///
/// This exists because auto-write is a mode in which *touching the reader changes a tag*. That has
/// to be legible before it happens, not inferred afterwards from a toast, so the state is a
/// sentence and a pill rather than a silent behaviour. The switch is here, next to the thing it
/// governs, rather than in a preferences pane.
struct AutoWriteCard: View {
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var model: TagViewModel

    var body: some View {
        Card("Auto-Write", symbol: "bolt.fill", accessory: AnyView(pill)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Toggle("Write automatically when a tag is presented",
                       isOn: $model.autoWriteEnabled)
                    .help("When off, nothing is written until you choose Write Tag… (⇧⌘W) and "
                          + "confirm the before/after diff.")

                Text(stateLine)
                    .font(.callout)
                    .foregroundStyle(model.autoWriteEnabled ? Theme.label : Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)

                if let skipped = model.autoWriteSkipped {
                    Label(skipped, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.autoWriteEnabled {
                    Divider()
                    // There used to be an "Allow writing sector keys (advanced)" opt-in here, and
                    // a blank tag presented with it off raised the confirmation sheet instead of
                    // being written. It gated the app's most ordinary operation — tagging a new
                    // spool — behind a checkbox worded like a hazard, so it is gone.
                    // The reasoning — why programming a blank tag needs no confirmation — is in
                    // `docs/DECISIONS.md` D-006. The screen states what happens, not the argument.
                    Text("Blank tags are programmed on presentation.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stateLine: String {
        switch model.autoWriteState {
        case .off:
            return "Off. Nothing is written until you choose Write Tag… (⇧⌘W) and confirm."
        case let .blocked(issue):
            return "Not ready — \(issue)"
        case let .busy(label):
            return label
        case let .deferred(reason):
            return "Seen — the tag on the reader will be written as soon as \(reason)."
        case .unsupportedTag:
            return "The tag on the reader is not one this app can write. Lift it and present a "
                 + "MIFARE Classic 1K tag with a 4-byte UID."
        case .armed:
            return monitor.state.card == nil
                ? "Ready — present a tag to write."
                : "Ready — writing the tag on the reader."
        case .handled:
            return "Ready — present a tag to write. The tag on the reader now has already been "
                 + "handled; lift it and put it back to write it again, or press ⇧⌘W."
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch model.autoWriteState {
        case .off:
            StatusPill(symbol: "pause.circle.fill", text: "Off", tone: .neutral)
        case .blocked:
            StatusPill(symbol: "exclamationmark.circle.fill", text: "Not ready", tone: .caution)
        case .busy:
            StatusPill(symbol: "hourglass", text: "Working", tone: .active, isBusy: true)
        case .deferred:
            StatusPill(symbol: "clock.fill", text: "Queued", tone: .active)
        case .unsupportedTag:
            StatusPill(symbol: "questionmark.circle.fill", text: "Unsupported tag", tone: .caution)
        case .armed:
            StatusPill(symbol: "bolt.fill", text: "Ready", tone: .good)
        case .handled:
            StatusPill(symbol: "checkmark.circle.fill", text: "Tag handled", tone: .good)
        }
    }
}

// MARK: - Write outcome

/// The persistent record of the last write.
///
/// A successful write used to produce a two-second toast and nothing else, which is what made the
/// stale-record bug so confusing: the only evidence a write had happened vanished before the user
/// looked away from the tag. This panel names what was written and to which tag, states whether
/// the app has actually seen those bytes come back off the card, and stays until the next read or
/// a different tag.
struct WriteOutcomeCard: View {
    let outcome: WriteOutcome
    @ObservedObject var model: TagViewModel
    @Environment(\.toastCenter) private var toasts

    var body: some View {
        switch outcome {
        case let .succeeded(summary):
            Card("Write Succeeded", symbol: "checkmark.seal", accessory: AnyView(readbackPill)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("Written to tag \(summary.uidSpaced)", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.success)

                    ValueRow(label: "Material",
                             value: summary.materialLabel.isEmpty
                                 ? summary.record.materialId
                                 : "\(summary.materialLabel) (\(summary.record.materialId))",
                             monospaced: false, copyable: false)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                        Text("Colour")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryLabel)
                            .frame(width: TagFormMetrics.labelWidth, alignment: .leading)
                        ColorSwatch(color: Color(tagHex: summary.record.rgbHex) ?? .gray,
                                    hex: summary.record.rgbHex)
                        Spacer(minLength: 0)
                    }
                    ValueRow(label: "Serial number", value: summary.record.serialNumber)
                    ValueRow(label: "Weight",
                             value: summary.record.knownLength?.label ?? "\(summary.record.weightGrams) g",
                             monospaced: false, copyable: false)
                    ValueRow(label: "Printer (sector 2)",
                             value: summary.wroteSector2
                                 ? (summary.printerTypeString.isEmpty ? "cleared" : summary.printerTypeString)
                                 : "skipped — could not authenticate",
                             monospaced: false, copyable: false)

                    Divider()
                    readbackNote

                    if summary.wroteTrailer {
                        Label("Sector 1 keys were rewritten (first-time programming).",
                              systemImage: "key.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.warning)
                    }

                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            ValueRow(label: "Blocks written",
                                     value: summary.blocksWritten.map(String.init).joined(separator: ", "),
                                     copyable: false)
                            Label("A backup of \(summary.backupSectorCount) readable "
                                  + "sector\(summary.backupSectorCount == 1 ? "" : "s") was taken "
                                  + "before the first write.",
                                  systemImage: "arrow.counterclockwise.circle")
                                .font(.callout)
                                .foregroundStyle(Theme.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            if !summary.backupFailedSectors.isEmpty {
                                Text("Sectors that could not be backed up: "
                                     + summary.backupFailedSectors.map(String.init).joined(separator: ", "))
                                    .font(.callout)
                                    .foregroundStyle(Theme.tertiaryLabel)
                            }
                            HStack {
                                Spacer()
                                Button("Save Backup…") { saveBackup(summary) }
                                    .help("Writes the pre-write sector dump to a text file")
                            }
                        }
                        .padding(.top, Theme.Spacing.s)
                    }
                    .font(.callout)
                }
            }

        case let .failed(message):
            Card("Write Failed", symbol: "xmark.octagon") {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("Nothing was changed, or the write stopped part-way.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.danger)
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Switch to Read, or press ⌘R, to see the tag's current contents before "
                         + "retrying.")
                        .font(.callout)
                        .foregroundStyle(Theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The honest version of "did it work". A failed read-back is **not** a failed write — the
    /// bytes were verified block-by-block by `TagService` before this panel existed — so it is
    /// stated as a display problem with a way to try again, never as an error about the tag.
    @ViewBuilder
    private var readbackNote: some View {
        switch model.readback {
        case .confirmed:
            Label("The tag was read again straight after the write, and the values above are "
                  + "what came back off it.",
                  systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(Theme.success)
                .fixedSize(horizontal: false, vertical: true)

        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("The write completed and was verified, but the tag could not be read back, "
                      + "so this panel shows what was sent rather than what was read.",
                      systemImage: "questionmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reason)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.tertiaryLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Read the Tag Again") { Task { await model.retryReadback() } }
                        .disabled(model.activity.isRunning)
                        .help("Reads the tag again so the values above can be confirmed")
                }
            }

        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var readbackPill: some View {
        switch model.readback {
        case .confirmed:
            StatusPill(symbol: "checkmark.shield.fill", text: "Read back", tone: .good)
        case .unavailable:
            StatusPill(symbol: "questionmark.circle.fill", text: "Not read back", tone: .caution)
        case .none:
            EmptyView()
        }
    }

    private func saveBackup(_ summary: WriteSummary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tag-\(summary.uid.hexString)-backup.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try summary.backupDump.write(to: url, atomically: true, encoding: .utf8)
            toasts?.success("Backup saved")
        } catch {
            toasts?.error("Could not save the backup — \(error.localizedDescription)")
        }
    }
}
