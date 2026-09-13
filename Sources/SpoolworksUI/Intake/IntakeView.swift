import SwiftUI
import SpoolworksCore

/// Log incoming spools, one after another, without leaving the reader.
struct IntakeView: View {
    @ObservedObject var model: IntakeViewModel
    @ObservedObject var inventory: InventoryViewModel
    @ObservedObject var env: AppEnvironment
    /// Observed directly rather than reached through `env`: the confirmation sheet binds to
    /// `pendingPlan`, and a binding cannot be projected through a `let` on the environment.
    @ObservedObject var tagModel: TagViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Reader stays hot · scan spool after spool", title: "Intake")
                    .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        methodCard
                        FilamentPushNotice(model: env.filamentPushModel)
                        if model.isScan { tagPanel(tinted: false) }
                        formCard
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 18) {
                        decodedPanel
                        sessionPanel
                    }
                    .frame(width: 420)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        // Auto-read, so no button has to be pressed. Read mode is what arms TagViewModel's
        // arrival handling; Intake is a reading screen whichever method is chosen, and a blank tag
        // presented in Method B simply fails to decode and is ignored.
        .onAppear {
            model.isActive = true
            arm()
        }
        .onDisappear {
            model.isActive = false
            // Leave the reader in read mode. A write arming that outlived this screen would make
            // a tag presented anywhere else get written.
            tagModel.mode = .read
        }
        // Re-arm whenever anything that decides the mode or feeds the written record changes. One
        // key rather than a list of fields: the list missed the spool size, so a tag auto-written
        // after the size was changed carried the old length code.
        .onChange(of: model.armingKey) { _, _ in arm() }
        // Feed the reader's activity through so the slot rows can show it — and absorb the result
        // of every read that finishes. This used to key on the UID that came back, which is a
        // value, not an event: after "Discard" the same tag read again is the same value set
        // again, SwiftUI reports no change, and "Read now" did nothing however often it was
        // pressed. The end of a read happens once per read, so that is what is watched. Verified
        // writes reach the model through `TagViewModel.onWriteSucceeded` (see `AppEnvironment`),
        // carrying the record that was actually written.
        .onChange(of: tagModel.activity) { previous, activity in
            model.activityLabel = activity.isRunning ? activity.label : nil
            if previous == .reading, !activity.isRunning, let result = tagModel.lastRead {
                model.absorb(result)
            }
        }
        // The same sheet the Write screen raises. A plan must be confirmed on whichever screen
        // built it, or it is raised against a view that is not on screen — the defect documented
        // in AppEnvironment.sidebarSelection.
        .sheet(item: $tagModel.pendingPlan) { plan in
            WriteConfirmationSheet(plan: plan, model: env.tagModel) { confirmed in
                if confirmed {
                    // The slot is not ticked off here. A verified write reaches the model through
                    // `onWriteSucceeded`, keyed on the tag's UID, whichever path programmed it;
                    // ticking by slot index as well let "Write now" on the second row claim both
                    // sides after rewriting the first row's tag.
                    Task {
                        await tagModel.commitWrite(
                            plan, allowTrailerWrite: plan.isBlankTagProgramming)
                    }
                } else {
                    tagModel.cancelPendingWrite()
                }
            }
        }
    }

    /// Whether the camera colour scanner is open.
    @State private var isScanningColour = false

    /// Puts the reader into the mode this screen currently needs.
    ///
    /// Method A reads. Method B **writes on presentation** — the draft is loaded and auto-write
    /// armed, so a blank tag laid on the reader is written without a button. Once both tags are
    /// done the arming is dropped again: a third tag presented while tidying up must not be
    /// written.
    private func arm() {
        guard model.isActive else { return }
        if model.isArmedToWrite {
            model.loadDraft(into: tagModel)
            tagModel.mode = .write
        } else {
            tagModel.mode = .read
        }
    }

    /// Loads the intake form into the tag draft and raises the standard write confirmation.
    private func beginWrite(_ slot: IntakeViewModel.TagSlot) {
        guard model.canWriteTags else { return }
        model.loadDraft(into: env.tagModel)
        Task { await tagModel.prepareWrite() }
    }

    /// Clears the form and, in Method A, looks at the reader again.
    ///
    /// `reset()` forgets the tags this intake absorbed, but `TagViewModel` still remembers the
    /// last one it read and will not auto-read a UID it already holds — so after discarding, the
    /// tag sitting on the reader was ignored until it was lifted and put back. Forgetting it on
    /// that side too means a discarded spool's tag is read afresh, which is what "the reader
    /// stays hot" promises. Method B is left alone: its reader is armed to write, not to read.
    private func discard() {
        model.reset()
        if model.isScan { tagModel.beginIdentification() }
    }

    // MARK: Step 1

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Step 1 · Choose a method").kicker()
                Spacer()
                SWTag(text: model.stateLabel, style: model.duplicate == nil ? .accent : .outline)
            }
            .padding(.bottom, 14)

            HStack(spacing: 0) {
                ForEach(IntakeViewModel.Method.allCases) { method in
                    MethodButton(method: method,
                                 isSelected: model.method == method) { model.method = method }
                    if method != IntakeViewModel.Method.allCases.last {
                        Rectangle().fill(Theme.separator).frame(width: 1)
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                Button(model.isScan ? "Read a tag" : "New blank spool") {
                    if model.isScan {
                        Task { await tagModel.read() }
                    } else {
                        model.reset()
                    }
                }
                .buttonStyle(.sw(.primary))
                .disabled(tagModel.activity.isRunning)

                Button("Start over") { discard() }
                    .buttonStyle(.sw(.ghost))
            }

            if let failure = model.failure {
                InlineFailure(text: failure).padding(.top, 14)
            }
            if let mismatch = model.mismatch {
                InlineFailure(text: mismatch).padding(.top, 14)
            }
            if let duplicate = model.duplicate {
                DuplicateNotice(spool: duplicate) {
                    model.openDuplicate()
                    env.sidebarSelection = .inventory
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    // MARK: Steps 2/3 — the two tags

    private func tagPanel(tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(model.tagPanelLabel).kicker()
                Spacer()
                if model.allTagsHandled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.success)
                        .accessibilityHidden(true)
                }
                Text(model.tagSummary)
                    .font(Theme.monoSmall)
                    .foregroundStyle(model.allTagsHandled ? Theme.success : Theme.secondaryLabel)
            }
            .padding(.bottom, 12)

            TagCountControl(model: model).padding(.bottom, 12)

            if model.isArmedToWrite {
                HStack(spacing: 7) {
                    StatusDot(level: .ready, size: 8)
                    Text("Armed — lay a blank tag on the reader and it is written, then read back to verify.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .padding(.bottom, 10)
            }

            if model.tagsRequired > 0 {
                ForEach(model.tags) { slot in
                TagRow(slot: slot,
                       isScan: model.isScan,
                       busy: tagModel.activity.isRunning,
                       action: {
                           if model.isScan {
                               // The one shared reader path. `onChange(of: lastRead.uid)` files
                               // the result in the next slot, exactly as an untouched tag would.
                               Task { await tagModel.read() }
                           } else {
                               beginWrite(slot)
                           }
                       })
                }
            }

            if let blocker = model.writeBlocker {
                InlineFailure(text: blocker).padding(.top, 12)
            }

            Text(model.tagNote)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20, fill: tinted ? Theme.surfaceRecessed : Theme.surface)
    }

    // MARK: The form

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.formLabel).kicker()
                Spacer()
                Text(model.uidLabel)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.bottom, 16)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18),
                                GridItem(.flexible(), spacing: 18)],
                      alignment: .leading, spacing: 14) {
                if model.isScan {
                    // Method A: the tag is authoritative, so these are read-backs, not choices.
                    FieldBox(label: "Brand") { ReadOnlyValue(model.brand.isEmpty ? "—" : model.brand) }
                    FieldBox(label: "Name", note: "from the catalogue, editable") {
                        TextField("", text: $model.name).textFieldStyle(.plain).swInput()
                    }
                    FieldBox(label: "Material") {
                        ReadOnlyValue(model.materialType.isEmpty ? "—" : model.materialType)
                    }
                } else {
                    // Method B: the form is authoritative, so the material must resolve to a real
                    // catalogue entry — that is where the tag's filament ID comes from.
                    //
                    // Authoritative only until a tag is written. From then on the tag is a
                    // physical fact and the form has to describe it, so everything the tag
                    // encodes — material, colour, spool size, serial — is locked; the name stays
                    // open because it is not on the tag. Without the lock a colour corrected
                    // after the first write put a spool in stock under an identity its tags did
                    // not carry, and the next CFS poll found the tags as a second spool.
                    FieldBox(label: "Brand",
                             note: model.isIdentityLocked ? "on the tag" : "from the catalogue") {
                        Picker("", selection: $model.catalogueBrand) {
                            Text("—").tag("")
                            ForEach(model.catalogueBrands, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(model.isIdentityLocked)
                    }
                    FieldBox(label: "Name", note: "follows the material") {
                        TextField("", text: $model.name).textFieldStyle(.plain).swInput()
                    }
                    FieldBox(label: "Material",
                             note: model.isIdentityLocked ? "on the tag" : "decides the filament ID") {
                        Picker("", selection: $model.materialID) {
                            Text("—").tag("")
                            ForEach(model.materials(for: model.catalogueBrand)) { row in
                                Text("\(row.name) · \(row.materialType)").tag(row.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isIdentityLocked)
                    }
                }
                // Two questions, and they were one field. "Net weight" beside nothing else about
                // quantity reads as "how much is here", so every spool taken in was silently
                // recorded as full — which is right for a spool out of its box and wrong for the
                // reason most people count their stock: they already own it, and some of it is
                // half used. The labels now say which is which, and both are asked.
                FieldBox(label: "Spool size",
                         note: model.isIdentityLocked ? "on the tag" : "what a full one holds") {
                    Picker("", selection: $model.netWeightGrams) {
                        ForEach(IntakeViewModel.weights, id: \.self) {
                            Text(Spool.weightLabel($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    // The length code is on the tag, so the size is locked with the rest.
                    .disabled(model.isIdentityLocked)
                }
                FieldBox(label: "How much is left", note: "on the spool now") {
                    Picker("", selection: $model.remainingPercent) {
                        ForEach(model.remainingOptions, id: \.percent) { option in
                            Text(option.label).tag(option.percent)
                        }
                    }
                    .labelsHidden()
                }
                FieldBox(label: "Serial", note: model.isScan ? "from tag" : "generated") {
                    ReadOnlyValue(model.serial)
                }
                FieldBox(label: "Filament ID", note: "from material profile") {
                    ReadOnlyValue(model.filamentId.isEmpty ? "—" : model.filamentId)
                }
            }
            .padding(.bottom, 16)

            HStack(alignment: .bottom, spacing: 18) {
                FieldBox(label: "Colour",
                         note: model.isScan ? "from tag" : model.isIdentityLocked ? "on the tag" : nil) {
                    TextField("", text: $model.colorHex).textFieldStyle(.plain).swInput()
                        .disabled(model.isIdentityLocked)
                }
                // Method B only. In Method A the tag is the authority on colour, and colour is
                // part of how a spool is identified (see the README on serial collisions) — a
                // camera reading laid over a decoded one would quietly break that key.
                if !model.isScan {
                    Button("Scan…") { isScanningColour = true }
                        .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 10))
                        .help("Read the colour off the spool with a camera.")
                        .disabled(model.isIdentityLocked)
                    // The swatch is the third way in, beside typing a code and scanning one. All
                    // three write the same `colorHex`, which is what makes "the last thing you did
                    // wins" fall out rather than needing to be arbitrated: there is one value, and
                    // no input holds a copy of its own.
                    Button { openColorPanel() } label: {
                        Swatch(hex: model.colorHex, size: 52, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isIdentityLocked)
                    .help("Pick the colour from the macOS colour palette.")
                    .accessibilityLabel("Colour \(model.colorHex.isEmpty ? "not set" : model.colorHex)")
                    .accessibilityHint("Opens the macOS colour palette")
                } else {
                    Swatch(hex: model.colorHex, size: 52, height: 44)
                }
            }
            .padding(.bottom, 18)

            if !model.isScan {
                tagPanel(tinted: true).padding(.bottom, 18)
            }

            // The model's own check behind the lock above. A value can still arrive around the
            // disabled inputs — the camera sheet commits when it closes, and the colour panel is
            // a window of its own — and a form that no longer says what the tags say must not be
            // confirmed. The button puts the tag's values back; "Discard" is the other way out.
            if !model.isScan, let drift = model.writtenDrift {
                InlineFailure(text: drift).padding(.bottom, 12)
                Button("Use the tag's values") { model.restoreWrittenValues() }
                    .buttonStyle(.sw(.secondary, size: 12, h: 14, v: 10))
                    .padding(.bottom, 18)
            }

            Rule().padding(.bottom, 16)

            HStack(alignment: .top, spacing: 12) {
                Button(model.confirmTitle) { model.confirm() }
                    .buttonStyle(.sw(.primary, size: 13, h: 20, v: 12))
                    .disabled(!model.canConfirm)
                Button("Discard") { discard() }
                    .buttonStyle(.sw(.ghost, h: 14, v: 11))
                Spacer(minLength: 0)
                Text(model.hint)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
        .sheet(isPresented: $isScanningColour) {
            ColorScanSheet(hex: $model.colorHex)
        }
        // A colour typed or scanned while the panel is open has to reach the panel too, or its next
        // click would quietly undo the newer value.
        .onChange(of: model.colorHex) { _, hex in
            SystemColorPanel.shared.update(hex: Spool.normaliseHex(hex), owner: colorPanelOwner)
        }
        // Switching to Method A hands authority over colour back to the tag, so an open panel must
        // stop writing to the field. Without this a click in a panel left over from Method B would
        // overwrite a colour that had been decoded off a spool.
        .onChange(of: model.isScan) { _, isScan in
            if isScan { SystemColorPanel.shared.relinquish(owner: colorPanelOwner) }
        }
        // The same handover once a tag is written: the panel is a window of its own, so disabling
        // the swatch does not stop a panel already open from pushing a colour into a form whose
        // colour is now fixed by the tag.
        .onChange(of: model.isIdentityLocked) { _, locked in
            if locked { SystemColorPanel.shared.relinquish(owner: colorPanelOwner) }
        }
        // Unconditional on purpose: `relinquish` is a no-op unless this screen still owns the
        // panel, which is exactly the check that makes it safe to call from here.
        .onDisappear { SystemColorPanel.shared.relinquish(owner: colorPanelOwner) }
    }

    /// Identifies this screen to the app-wide colour panel. See ``SystemColorPanel``.
    private var colorPanelOwner: AnyHashable { "intake.colour" }

    private func openColorPanel() {
        SystemColorPanel.shared.present(hex: Spool.normaliseHex(model.colorHex),
                                        owner: colorPanelOwner) { hex in
            model.colorHex = hex
        }
    }

    // MARK: Right column

    private var decodedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Decoded from tag").kicker().padding(.bottom, 12)
            Text(model.payload)
                .font(Theme.monoCaption)
                .foregroundStyle(Theme.label)
                .textSelection(.enabled)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Hairline().padding(.vertical, 14)
            VStack(spacing: 0) {
                ForEach(model.fields, id: \.0) { key, value in
                    DataRow(key, value, mono: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Logged this session").kicker().padding(.bottom, 12)
            if model.session.isEmpty {
                Text("Nothing logged yet. Spools you add appear here.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                ForEach(model.session) { spool in
                    HStack(spacing: 10) {
                        Swatch(hex: spool.colorHex, size: 16)
                        Text(spool.label)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(spool.serialLabel)
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Hairline() }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
    }
}

// MARK: - Pieces

private struct MethodButton: View {
    let method: IntakeViewModel.Method
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(method.title).font(.system(size: 13.5, weight: .bold))
                Text(method.subtitle).font(.system(size: 11.5)).opacity(0.75)
            }
            .foregroundStyle(isSelected ? Theme.navActiveLabel : Theme.label)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.navActiveFill : (hovering ? Theme.navHoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// How many tags this spool takes: both sides, one, or none at all.
///
/// Above the rows rather than on them, because it is one decision about the spool and not a
/// property of a slot — and because "none" is not a thing you can express by skipping rows one at
/// a time. Each option is a real case: both sides is a spool going into a CFS, one is a spool that
/// will only ever sit on the external holder (read from the same side every time, often with a
/// reusable tag), and none is unopened stock you are counting onto a shelf.
private struct TagCountControl: View {
    @ObservedObject var model: IntakeViewModel

    private struct Option: Hashable, Identifiable {
        let count: Int
        let title: String
        var id: Int { count }
    }

    private var options: [Option] {
        var offered = [Option(count: 2, title: model.isScan ? "Read both" : "Write both"),
                       Option(count: 1, title: model.isScan ? "Read one" : "Write one")]
        // Method A cannot finish without a decoded tag, so "no tag" there would be a button that
        // makes the screen impossible to complete.
        if !model.isScan { offered.append(Option(count: 0, title: "No tag")) }
        return offered
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            SegmentedFilter(options: options,
                            title: \.title,
                            selection: Binding(get: { options.first { $0.count == model.tagsRequired }
                                                        ?? options[0] },
                                               set: { model.setTagsRequired($0.count) }))
            Text(note)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var note: String {
        switch model.tagsRequired {
        case 0: return "Counted onto the shelf. Nothing is read or written, and the reader stays idle."
        case 1: return "For a spool that lives on the external holder, or a tag you reuse."
        default: return "Both sides of the hub, so it reads whichever way it is loaded."
        }
    }
}

private struct TagRow: View {
    let slot: IntakeViewModel.TagSlot
    let isScan: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(slot.name)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 84, alignment: .leading)

            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            // A write takes several seconds — dump, authenticate, write, read back — and the row
            // used to sit there saying "ready" throughout, which reads as nothing happening.
            if slot.state.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else if slot.state == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
            }

            Text(slot.state.caption)
                .kicker()
                .foregroundStyle(captionColour)
                .frame(minWidth: 62, alignment: .trailing)

            // A skipped row keeps its shape but has nothing to press: how many tags this spool
            // takes is decided once, above the rows, not per row.
            if slot.state != .skipped {
                Button(cta, action: action)
                    .buttonStyle(.sw(.primary, size: 11.5, h: 16, v: 8))
                    .disabled(busy || slot.state == .waiting)
                    .opacity(slot.state == .done ? 0.6 : 1)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.name), \(slot.state.caption). \(detail)")
    }

    private var captionColour: Color {
        switch slot.state {
        case .done: return Theme.success
        case .working: return Theme.busy
        case .ready: return Theme.accent
        case .waiting: return Theme.kickerLabel
        case .skipped: return Theme.kickerLabel
        }
    }

    private var detail: String {
        switch slot.state {
        case .done:
            return isScan ? "read and decoded · payload matches"
                          : "written, then read back byte for byte"
        case let .working(what):
            return what
        case .ready:
            return isScan ? "present this tag to the reader"
                          : "present a blank MIFARE Classic 1K tag"
        case .waiting:
            return isScan ? "waiting for the first tag" : "waiting for tag 1"
        case .skipped:
            return isScan ? "not needed — one tag is enough for this spool"
                          : "not needed — this spool gets one tag"
        }
    }

    private var cta: String {
        // The normal path never needs this pressed — tags are read and written on presentation.
        // It stays for a tag the reader saw but could not decode.
        if isScan { return slot.isDone ? "Re-read" : "Read now" }
        return slot.isDone ? "Rewrite" : "Write now"
    }
}

private struct DuplicateNotice: View {
    let spool: Spool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text("This tag already belongs to \(spool.label) in stock — \(spool.remainingLabel) left, \(spool.location.description).")
                .font(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            Button("Open it", action: open).buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08))
        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
    }
}

/// A labelled form field, matching the design's `.field` + `label`.
struct FieldBox<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                if let note {
                    Text("· \(note)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.kickerLabel)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A value the user cannot edit because something else owns it — the tag, or the catalogue.
struct ReadOnlyValue: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.monoCaption)
            .foregroundStyle(Theme.secondaryLabel)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceSunken)
            .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
            .textSelection(.enabled)
    }
}

extension View {
    /// The design's `.input`: square, tinted fill, 1 pt border, accent caret.
    func swInput() -> some View {
        self
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(Theme.surfaceSunken)
            .overlay(Rectangle().strokeBorder(Theme.separator, lineWidth: 1))
            .tint(Theme.accent)
    }
}
