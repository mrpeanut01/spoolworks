import SwiftUI
import SpoolworksCore

/// Log incoming spools, one after another, without leaving the reader.
struct IntakeView: View {
    @ObservedObject var model: IntakeViewModel
    @ObservedObject var inventory: InventoryViewModel
    @ObservedObject var env: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Reader stays hot · scan spool after spool", title: "Intake")
                    .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        methodCard
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
                        Task { await model.readTag(model.tags[0]) }
                    } else {
                        model.reset()
                    }
                }
                .buttonStyle(.sw(.primary))
                .disabled(model.busy)

                Button("Start over") { model.reset() }
                    .buttonStyle(.sw(.ghost))
            }

            if let failure = model.failure {
                InlineFailure(text: failure).padding(.top, 14)
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
            HStack(alignment: .firstTextBaseline) {
                Text(model.tagPanelLabel).kicker()
                Spacer()
                Text(model.tagProgress)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.bottom, 12)

            ForEach(model.tags) { slot in
                TagRow(slot: slot,
                       isScan: model.isScan,
                       busy: model.busy,
                       previousDone: slot.index == 0 || model.tags[0].isDone) {
                    if model.isScan {
                        Task { await model.readTag(slot) }
                    } else {
                        // Writing a blank tag is irreversible, so it goes through the Write
                        // screen's confirmation and read-back verification rather than happening
                        // silently from here.
                        env.sidebarSelection = .write
                    }
                }
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
                FieldBox(label: "Brand") {
                    Picker("", selection: $model.brand) {
                        Text("—").tag("")
                        ForEach(IntakeViewModel.brands, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                FieldBox(label: "Name", note: "auto from brand + material, editable") {
                    TextField("", text: $model.name).textFieldStyle(.plain).swInput()
                }
                FieldBox(label: "Material") {
                    Picker("", selection: $model.materialType) {
                        ForEach(IntakeViewModel.materialTypes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                FieldBox(label: "Net weight") {
                    Picker("", selection: $model.netWeightGrams) {
                        ForEach(IntakeViewModel.weights, id: \.self) {
                            Text(Spool.weightLabel($0)).tag($0)
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
                FieldBox(label: "Colour") {
                    TextField("", text: $model.colorHex).textFieldStyle(.plain).swInput()
                }
                Swatch(hex: model.colorHex, size: 52, height: 44)
            }
            .padding(.bottom, 18)

            if !model.isScan {
                tagPanel(tinted: true).padding(.bottom, 18)
            }

            Rule().padding(.bottom, 16)

            HStack(alignment: .top, spacing: 12) {
                Button(model.confirmTitle) { model.confirm() }
                    .buttonStyle(.sw(.primary, size: 13, h: 20, v: 12))
                    .disabled(!model.canConfirm)
                Button("Discard") { model.reset() }
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

private struct TagRow: View {
    let slot: IntakeViewModel.TagSlot
    let isScan: Bool
    let busy: Bool
    let previousDone: Bool
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
            Text(state).kicker().foregroundStyle(Theme.accent)
            Button(cta, action: action)
                .buttonStyle(.sw(.primary, size: 11.5, h: 16, v: 8))
                .disabled(busy || !previousDone)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if isScan {
            return slot.isDone ? "read and decoded · payload matches" : "present this tag to the reader"
        }
        if slot.isDone { return "written and verified byte for byte" }
        return previousDone ? "present a blank MIFARE Classic 1K tag" : "waiting for tag 1"
    }

    private var state: String {
        if isScan { return slot.isDone ? "read" : "ready" }
        if slot.isDone { return "verified" }
        return previousDone ? "ready" : "waiting"
    }

    private var cta: String {
        if isScan { return slot.isDone ? "Re-read" : "Read" }
        return slot.isDone ? "Rewrite" : "Write"
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
