import SwiftUI
import SpoolworksCore

// MARK: - Draft

/// One editable `kvParam` entry. `kvParam` is a flat `String → String` map whose *key set* varies
/// per record (90–100 keys), so it is edited as rows, never as a fixed struct.
struct KVParam: Identifiable, Hashable {
    let id = UUID()
    var key: String
    var value: String
}

/// A mutable, all-strings mirror of a `Filament`, so that a half-typed number is a normal editing
/// state rather than something the model has to represent.
///
/// Everything not surfaced here — `rank`, `costPerMeter`, `weightPerMeter`, `shrinkageRate`,
/// `additionalFields`, `engineVersion`, `nozzleDiameter` — is carried through from ``original``
/// untouched, which is what makes a round-trip loss-free.
struct FilamentDraft {
    var id = ""
    var brand = ""
    var name = ""
    var materialType = ""
    var minTemp = ""
    var maxTemp = ""
    var softeningTemp = ""
    var dryingTemp = ""
    var dryingTime = ""
    var density = ""
    var diameter = ""
    var color: Color = .blue
    var isSoluble = false
    var isSupport = false
    var params: [KVParam] = []

    /// The record this draft edits or clones. `nil` only when creating from nothing.
    var original: Filament?

    enum Field: Hashable {
        case id, brand, name, materialType, minTemp, maxTemp, softeningTemp, dryingTemp, dryingTime,
             density, diameter, params
    }

    // MARK: Construction

    static func make(mode: MaterialsViewModel.EditorMode,
                     printerType: PrinterType,
                     existingIDs: Set<String>) -> FilamentDraft {
        switch mode {
        case let .edit(filament):
            return FilamentDraft(filament)
        case let .add(template):
            var draft = template.map(FilamentDraft.init) ?? FilamentDraft.blank(printerType: printerType)
            // Windows clears brand and name but keeps type/temps/flags and the whole slicer profile
            // (`FilamentForm.cs:80-83`) — a new filament is a variant of an existing one.
            draft.brand = ""
            draft.name = ""
            draft.id = Self.freshID(avoiding: existingIDs)
            draft.original = template
            return draft
        }
    }

    private static func blank(printerType _: PrinterType) -> FilamentDraft {
        var draft = FilamentDraft()
        draft.minTemp = "190"
        draft.maxTemp = "240"
        draft.density = "1.24"
        draft.diameter = "1.75"
        draft.softeningTemp = "0"
        draft.dryingTemp = "0"
        draft.dryingTime = "0"
        draft.color = Color(RGB8(r: 0, g: 0, b: 255))
        // `Invalid paramList` (`FilamentForm.cs:236`) rejects an empty slicer profile. When there is
        // no template to clone, seed the two keys the app itself owns so a from-scratch filament is
        // not born un-saveable.
        draft.params = [
            KVParam(key: "filament_type", value: ""),
            KVParam(key: "filament_vendor", value: ""),
        ]
        return draft
    }

    init() {}

    init(_ filament: Filament) {
        original = filament
        id = filament.base.id
        brand = filament.base.brand
        name = filament.base.name
        materialType = filament.base.materialType
        minTemp = String(filament.base.minTemp)
        maxTemp = String(filament.base.maxTemp)
        softeningTemp = String(filament.base.softeningTemp)
        dryingTemp = String(filament.base.dryingTemp)
        dryingTime = String(filament.base.dryingTime)
        density = Self.trimTrailingZeros(filament.base.density)
        diameter = filament.base.diameter
        color = FilamentColor.color(fromHex: filament.base.colors.first ?? "") ?? .blue
        isSoluble = filament.base.isSoluble
        isSupport = filament.base.isSupport
        params = filament.kvParam
            .map { KVParam(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// Windows pre-fills `string.Format("{0:D5}", random.Next(99999))` and does not check for a
    /// collision (`FilamentForm.cs:80-81`), leaving the duplicate to be caught by the save
    /// validator. Checking here means the pre-filled value is always usable.
    static func freshID(avoiding taken: Set<String>) -> String {
        for _ in 0..<200 {
            let candidate = String(format: "%05d", Int.random(in: 0..<100_000))
            if !taken.contains(candidate) { return candidate }
        }
        return ""
    }

    private static func trimTrailingZeros(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9
            ? String(format: "%g", value)
            : String(value)
    }

    // MARK: Validation

    /// Per-field errors, keyed so each one can be rendered next to its own control rather than in a
    /// single alert. Empty means the draft is saveable.
    ///
    /// **Deliberate divergence from Windows.** `FilamentForm.SaveJsonAdd` demands
    /// `int.TryParse(txtId.Text)` and `Length == 5` (`FilamentForm.cs:265-275`), and the field
    /// itself is digits-only with paste suppressed. But the shipped catalogues contain `E1001`,
    /// `P1001`, `P1002` and `P1003` — four ids the app's own validator rejects, so Windows can load
    /// them, write them to a tag, and refuse to let you create another one like them. The rule
    /// enforced here is what the data actually is: **exactly five alphanumeric characters**
    /// (`SPEC/02-material-db.md §1.1` — "5 characters, zero-padded, not necessarily numeric").
    /// ASCII ones: a tag stores the id in five *bytes* (`SpoolRecord` checks `utf8.count == 5`),
    /// so a five-character id with an accented letter would be accepted here and refused at the
    /// point of writing the tag.
    func errors(existingIDs: Set<String>, isEditingExisting: Bool) -> [Field: String] {
        var out: [Field: String] = [:]

        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty {
            out[.id] = "An ID is required."
        } else if trimmedID.count != 5 {
            out[.id] = "ID must be exactly 5 characters (letters or digits), for example 01001 or P1001."
        } else if !trimmedID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            out[.id] = "ID may contain only the letters A–Z and the digits 0–9."
        } else if !isEditingExisting, existingIDs.contains(trimmedID) {
            // Windows string, preserved: `Filament ID Exists\nDuplicate IDs are not allowed`.
            out[.id] = "Filament ID exists. Duplicate IDs are not allowed."
        }

        if brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out[.brand] = "A brand is required."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out[.name] = "A name is required."
        }
        if materialType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out[.materialType] = "A material type is required."
        }

        let min = Int(minTemp.trimmingCharacters(in: .whitespacesAndNewlines))
        let max = Int(maxTemp.trimmingCharacters(in: .whitespacesAndNewlines))
        if min == nil {
            out[.minTemp] = "Min temp must be a whole number of °C."
        } else if !(0...600).contains(min!) {
            out[.minTemp] = "Min temp must be between 0 °C and 600 °C."
        }
        if max == nil {
            out[.maxTemp] = "Max temp must be a whole number of °C."
        } else if !(0...600).contains(max!) {
            out[.maxTemp] = "Max temp must be between 0 °C and 600 °C."
        }
        if let min, let max, min > max, out[.minTemp] == nil, out[.maxTemp] == nil {
            out[.maxTemp] = "Max temp must be at least the min temp (\(min) °C)."
        }

        // Whole numbers, like the print temperatures. These went unvalidated and quietly fell back
        // to the original record's value on save, so a typo was neither refused nor kept.
        let wholeNumberFields: [(Field, String, String)] = [
            (.softeningTemp, softeningTemp, "Softening temp"),
            (.dryingTemp, dryingTemp, "Drying temp"),
            (.dryingTime, dryingTime, "Drying time"),
        ]
        for (field, text, label) in wholeNumberFields {
            guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                out[field] = "\(label) must be a whole number; use 0 if it is not known."
                continue
            }
            if value < 0 { out[field] = "\(label) cannot be negative." }
        }

        // `density` is a JSON number and `diameter` a JSON *string* — easy to swap, and swapping
        // them makes the printer reject the file (SPEC/02 §9.2). Both are validated as numbers here
        // and re-encoded in their own wire types on save.
        if let value = Double(density.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if value <= 0 { out[.density] = "Density must be greater than 0 g/cm³." }
        } else {
            out[.density] = "Density must be a number, for example 1.24."
        }
        if let value = Double(diameter.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if value <= 0 { out[.diameter] = "Diameter must be greater than 0 mm." }
        } else {
            out[.diameter] = "Diameter must be a number, for example 1.75."
        }

        let keys = params.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        if params.isEmpty {
            out[.params] = "A filament needs at least one slicer parameter."
        } else if keys.contains(where: \.isEmpty) {
            out[.params] = "Every parameter needs a key."
        } else if Set(keys).count != keys.count {
            let duplicates = Set(keys.filter { key in keys.filter { $0 == key }.count > 1 })
            out[.params] = "Duplicate parameter keys: \(duplicates.sorted().joined(separator: ", "))."
        }

        return out
    }

    // MARK: Materialisation

    /// Builds the `Filament` to persist, preserving every field the editor does not surface.
    func filament(printerType: PrinterType) -> Filament {
        var base = original?.base ?? MaterialBase(id: "", brand: "", name: "", materialType: "")
        base.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        base.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        base.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        base.materialType = materialType.trimmingCharacters(in: .whitespacesAndNewlines)
        base.colors = [FilamentColor.hex(from: color)]
        base.minTemp = Int(minTemp.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.minTemp
        base.maxTemp = Int(maxTemp.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.maxTemp
        base.softeningTemp = Int(softeningTemp.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.softeningTemp
        base.dryingTemp = Int(dryingTemp.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.dryingTemp
        base.dryingTime = Int(dryingTime.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.dryingTime
        base.density = Double(density.trimmingCharacters(in: .whitespacesAndNewlines)) ?? base.density
        base.diameter = diameter.trimmingCharacters(in: .whitespacesAndNewlines)
        base.isSoluble = isSoluble
        base.isSupport = isSupport

        var kv: [String: String] = [:]
        for param in params {
            let key = param.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            kv[key] = param.value
        }

        var filament = Filament(
            engineVersion: original?.engineVersion ?? "3.0.0",
            // A new record must claim the family it is being filed under, not the one the template
            // came from — `Utils.cs:874` hardcodes "F008" for every family, which mislabels K1/Hi.
            printerIntName: original?.printerIntName ?? printerType.printerIntName,
            nozzleDiameter: original?.nozzleDiameter ?? ["0.4"],
            kvParam: kv,
            base: base,
            additionalFields: original?.additionalFields ?? [:]
        )
        // Keep the slicer profile's vendor/type in step with the identity fields
        // (`FilamentForm.cs:279-286`).
        filament.syncDerivedKVParams()
        return filament
    }
}

// MARK: - Editor

/// Add / edit sheet for a single filament.
///
/// Windows used a 1159 × 847 window with a `TabControl` whose first tab *disappeared* in edit mode
/// (`FilamentForm.cs:96`) — i.e. a mode wearing a tab. Here both modes show the same form; only the
/// ID field locks, because the id is the record's primary key in the on-disk catalogue.
struct FilamentEditorView: View {
    let mode: MaterialsViewModel.EditorMode
    @ObservedObject var model: MaterialsViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var draft = FilamentDraft()
    @State private var didPrepare = false
    @State private var didAttemptSave = false
    @State private var touched: Set<FilamentDraft.Field> = []
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var paramSearch = ""
    @State private var paramsExpanded = false
    @State private var colorName: String?
    @FocusState private var focused: FilamentDraft.Field?

    private var isEditingExisting: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingIDs: Set<String> {
        var ids = model.existingIDs
        if case let .edit(filament) = mode { ids.remove(filament.base.id) }
        return ids
    }

    private var errors: [FilamentDraft.Field: String] {
        draft.errors(existingIDs: existingIDs, isEditingExisting: isEditingExisting)
    }

    /// Errors appear once a field has been visited and left, or once Save has been attempted — so
    /// the form does not greet the user in red, but never hides why Save is refusing either.
    private func visibleError(_ field: FilamentDraft.Field) -> String? {
        guard didAttemptSave || touched.contains(field) else { return nil }
        return errors[field]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 540, idealHeight: 660)
        .onChange(of: focused) { previous, _ in
            if let previous { touched.insert(previous) }
        }
        .onAppear {
            guard !didPrepare else { return }
            didPrepare = true
            draft = FilamentDraft.make(mode: mode,
                                       printerType: model.printerType,
                                       existingIDs: model.existingIDs)
            paramsExpanded = draft.params.count <= 4
            refreshColorName()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditingExisting ? "Edit Filament" : "Add Filament")
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        if case let .edit(filament) = mode {
            return "\(filament.base.brand) — \(filament.base.name) · \(model.printerType.displayName)"
        }
        if case let .add(template) = mode, let template {
            return "Based on \(template.base.brand) \(template.base.name) · \(model.printerType.displayName)"
        }
        return model.printerType.displayName
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section("Identity") {
                LabeledContent("ID") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("ID", text: $draft.id)
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 140)
                            .focused($focused, equals: .id)
                            .disabled(isEditingExisting)
                        if isEditingExisting {
                            Text("The ID is how the printer and the tag refer to this filament, so it cannot be changed. Duplicate it as a new filament instead.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        errorLabel(.id)
                    }
                }

                LabeledContent("Brand") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Brand", text: $draft.brand)
                            .labelsHidden()
                            .focused($focused, equals: .brand)
                        suggestions(model.knownBrands) { draft.brand = $0 }
                        errorLabel(.brand)
                    }
                }

                LabeledContent("Name") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $draft.name)
                            .labelsHidden()
                            .focused($focused, equals: .name)
                        errorLabel(.name)
                    }
                }

                LabeledContent("Type") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Type", text: $draft.materialType)
                            .labelsHidden()
                            .focused($focused, equals: .materialType)
                        suggestions(model.knownMaterialTypes) { draft.materialType = $0 }
                        errorLabel(.materialType)
                    }
                }
            }

            Section("Colour") {
                // Replaces the blank 259 × 40 button whose only affordance was its fill colour
                // (`MainForm.cs:698-712`); `ColorPicker` brings the native colour panel for free.
                ColorPicker("Filament colour", selection: $draft.color, supportsOpacity: false)
                    .onChange(of: draft.color) { _, _ in refreshColorName() }
                LabeledContent("Hex") {
                    Text(FilamentColor.hex(from: draft.color))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Nearest name") {
                    Text(colorName ?? "—")
                        .foregroundStyle(colorName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                .help("Closest entry in the bundled colour table, used when naming a spool")
            }

            Section("Temperatures") {
                numericField("Min temp", unit: "°C", text: $draft.minTemp, field: .minTemp)
                numericField("Max temp", unit: "°C", text: $draft.maxTemp, field: .maxTemp)
                numericField("Softening temp", unit: "°C", text: $draft.softeningTemp, field: .softeningTemp)
                numericField("Drying temp", unit: "°C", text: $draft.dryingTemp, field: .dryingTemp)
                numericField("Drying time", unit: "hours", text: $draft.dryingTime, field: .dryingTime)
            }

            Section("Physical") {
                numericField("Density", unit: "g/cm³", text: $draft.density, field: .density)
                numericField("Diameter", unit: "mm", text: $draft.diameter, field: .diameter)
            }

            Section("Behaviour") {
                Toggle("Filament is soluble", isOn: $draft.isSoluble)
                Toggle("Filament is support", isOn: $draft.isSupport)
            }

            Section {
                DisclosureGroup(isExpanded: $paramsExpanded) {
                    paramEditor
                } label: {
                    HStack {
                        Text("Slicer Parameters")
                        Spacer()
                        Text("\(draft.params.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                errorLabel(.params)
            } footer: {
                Text("These are the key/value pairs the printer's slicer reads. Values are always text; the literal “nil” means “inherit”, so leave it alone unless you know otherwise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var paramEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter parameters", text: $paramSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button {
                    withAnimation {
                        draft.params.insert(KVParam(key: "", value: ""), at: 0)
                        paramSearch = ""
                    }
                } label: {
                    Label("Add Parameter", systemImage: "plus")
                }
                .accessibilityLabel("Add parameter")
                .help("Add a slicer parameter")
            }

            if draft.params.isEmpty {
                Text("No parameters. The printer will reject a filament with an empty slicer profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if visibleParams.isEmpty {
                Text("No parameter matches “\(paramSearch)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // Rows are identified by the parameter's own id, never by its position.
                        // An index-keyed row held a `$draft.params[index]` binding, and removing a
                        // row while the list was filtered shrank the array under a row that was
                        // still animating out — whose text field then read a subscript that no
                        // longer existed.
                        ForEach(visibleParams) { param in
                            paramRow(param)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            }
        }
    }

    private func paramRow(_ param: KVParam) -> some View {
        HStack(spacing: 8) {
            TextField("Key", text: paramBinding(param.id, \.key))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 230)
                .accessibilityLabel("Parameter key")
            TextField("Value", text: paramBinding(param.id, \.value))
                .font(.system(.callout, design: .monospaced))
                .accessibilityLabel("Value for \(param.key)")
            Button(role: .destructive) {
                withAnimation { draft.params.removeAll { $0.id == param.id } }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove parameter \(param.key)")
            .help("Remove this parameter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    /// A binding into one parameter, found by id on every access. Tolerates the parameter being
    /// gone — reads as empty, writes are dropped — which is the state a row is in while it
    /// animates out after removal.
    private func paramBinding(_ id: UUID, _ keyPath: WritableKeyPath<KVParam, String>) -> Binding<String> {
        Binding(
            get: { draft.params.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = draft.params.firstIndex(where: { $0.id == id }) else { return }
                draft.params[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var visibleParams: [KVParam] {
        let needle = paramSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return draft.params }
        return draft.params.filter {
            $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if didAttemptSave, !errors.isEmpty, saveError == nil {
                Label("Fix the highlighted fields before saving.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.danger)
                    .font(.callout)
            }
            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditingExisting ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(isSaving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Actions

    private func save() {
        didAttemptSave = true
        saveError = nil
        guard errors.isEmpty else {
            // Focus the first offending field so keyboard users are taken to the problem.
            let order: [FilamentDraft.Field] = [.id, .brand, .name, .materialType,
                                                .minTemp, .maxTemp, .softeningTemp, .dryingTemp,
                                                .dryingTime, .density, .diameter, .params]
            focused = order.first { errors[$0] != nil }
            return
        }
        let filament = draft.filament(printerType: model.printerType)
        isSaving = true
        Task {
            let failure: String?
            if isEditingExisting {
                failure = await model.update(filament)
            } else {
                failure = await model.add(filament)
            }
            isSaving = false
            if let failure {
                saveError = failure
            } else {
                dismiss()
            }
        }
    }

    private func refreshColorName() {
        let hex = FilamentColor.hex(from: draft.color)
        Task {
            colorName = await ColorNameResolver.shared.name(forHex: hex)
        }
    }

    // MARK: Small builders

    @ViewBuilder
    private func errorLabel(_ field: FilamentDraft.Field) -> some View {
        if let message = visibleError(field) {
            // Icon + text, never colour alone.
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Error: \(message)")
        }
    }

    private func numericField(_ title: String,
                              unit: String,
                              text: Binding<String>,
                              field: FilamentDraft.Field) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Paste is deliberately NOT blocked. The Windows fields suppress Ctrl+V and
                    // gut the context menu (`FilamentForm.cs:430-486`) purely to prop up a weak
                    // validator; SPEC/03-ui.md §8.5 lists that as a non-goal. Validate on commit.
                    TextField(title, text: text)
                        .labelsHidden()
                        .frame(maxWidth: 100)
                        .focused($focused, equals: field)
                    Text(unit).foregroundStyle(.secondary)
                }
                errorLabel(field)
            }
        }
    }

    @ViewBuilder
    private func suggestions(_ values: [String], apply: @escaping (String) -> Void) -> some View {
        if !values.isEmpty {
            Menu("Choose…") {
                ForEach(values, id: \.self) { value in
                    Button(value) { apply(value) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .accessibilityLabel("Choose an existing value")
        }
    }
}

