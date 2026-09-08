import SwiftUI
import SpoolworksCore

/// Program a tag for a third-party spool, or replace a damaged one.
///
/// ## What is reused, and why
///
/// The form, the auto-write arming, the outcome panel and — critically — the confirmation sheet and
/// its `commitWrite` wiring are the existing ``TagFormCard`` / ``AutoWriteCard`` /
/// ``WriteOutcomeCard`` and the `pendingPlan` sheet, moved here from `TagView`. They carry the
/// write-safety guarantees this app is built on: a full sector dump before the first write,
/// verification by read-back, validated trailer access bits, and a separate acknowledgement before
/// any sector key is rewritten. Redrawing that machinery to match a mockup would have meant
/// reimplementing it, and every one of those guarantees is a thing it would have been possible to
/// lose quietly.
///
/// So this screen supplies the design's **shell**: the header, the two-column split, and the
/// right-hand "Write & verify" panel that narrates the write as it happens.
struct WriteTagView: View {
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var model: TagViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "For third-party spools, or replacing a damaged tag",
                             title: "Write tag")
                    .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let notice = HardwareNotice(monitor: monitor) {
                            HardwareNoticeBanner(notice: notice, monitor: monitor)
                        }
                        TagFormCard(monitor: monitor, model: model)
                        AutoWriteCard(monitor: monitor, model: model, settings: settings)
                        WriteOptionsCard(settings: settings)
                        if let outcome = model.writeOutcome {
                            WriteOutcomeCard(outcome: outcome, model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    WriteVerifyPanel(model: model, monitor: monitor, settings: settings)
                        .frame(width: 420)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Theme.background)
        .onAppear { model.mode = .write }
        .task { await model.prepareCatalog() }
        .task(id: model.draft.colorHex) { await model.refreshDraftColorName() }
        // The confirmation sheet must be attached to whichever screen builds a plan, or the plan
        // is raised against a view that is not on screen and auto-write stays blocked until
        // something else clears it. That defect is documented in `AppEnvironment.sidebarSelection`.
        .sheet(item: $model.pendingPlan) { plan in
            WriteConfirmationSheet(plan: plan, model: model, settings: settings) { confirmed in
                if confirmed {
                    Task { await model.commitWrite(plan, allowTrailerWrite: settings.advancedTagOperations) }
                } else {
                    model.cancelPendingWrite()
                }
            }
        }
    }
}

// MARK: - Write & verify

/// The five steps a write goes through, and the payload it will write.
///
/// The states are derived from what the model is actually doing rather than animated on a timer —
/// a progress display that runs ahead of the operation is worse than none, because it says a tag
/// was verified before anything read it back.
private struct WriteVerifyPanel: View {
    @ObservedObject var model: TagViewModel
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Write & verify").kicker().padding(.bottom, 14)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", index + 1))
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.kickerLabel)
                        .frame(width: 18, alignment: .leading)
                    Text(step.what)
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(step.state).kicker().foregroundStyle(stateColor(step.state))
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Hairline() }
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Payload to write").kicker()
                Text(payload)
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.label)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The colour as the tag actually stores it. Worth showing on its own: the field is
                // seven characters, not six, and the leading nibble is not part of the colour —
                // every implementation writes '0' there and nobody has documented what it means
                // (see SpoolRecord.color). Without this the extra digit looks like a bug.
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text("Tag colour field").kicker()
                    Text(tagColourField)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
                Text("Seven hex digits — one flag nibble, then RRGGBB.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    private struct Step { let what: String; let state: String }

    private var hasCard: Bool { monitor.state.card?.isUsable == true }
    private var wrote: Bool { model.writeOutcome != nil }

    private var steps: [Step] {
        [
            Step(what: "Dump every readable sector",
                 state: wrote ? "done" : (hasCard ? "ready" : "waiting")),
            Step(what: "Authenticate sector 1 with the UID key",
                 state: wrote ? "done" : (hasCard ? "ready" : "waiting")),
            Step(what: "Write the record to blocks 4–6",
                 state: wrote ? "done" : (model.canWrite ? "ready" : "waiting")),
            Step(what: "Read back and compare byte for byte",
                 state: wrote ? "done" : "waiting"),
            Step(what: "Add the spool to inventory",
                 state: settings.addWrittenSpoolsToInventory ? (wrote ? "done" : "ready") : "off"),
        ]
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return Theme.success
        case "ready": return Theme.accent
        default: return Theme.kickerLabel
        }
    }

    /// `"0C12E1F"` — the colour exactly as it is written into the record.
    private var tagColourField: String {
        let hex = model.draft.colorHex
        return hex.isEmpty ? "—" : "0" + hex.uppercased()
    }

    /// The 40 characters the current form would write, or why it cannot yet.
    private var payload: String {
        guard model.draft.isValid,
              let record = try? SpoolRecord(materialId: model.draft.materialID,
                                            colorRGB: model.draft.colorHex,
                                            filamentLength: model.draft.weight,
                                            serialNumber: model.draft.serialNumber)
        else {
            return model.draft.validationIssues.first ?? "— the form is not complete —"
        }
        return record.encoded
    }
}


// MARK: - Options

/// The three switches the design puts under the write form.
///
/// One is a setting, one is a statement of fact, and the third lives on the Auto-Write card above.
///
/// **Verify by read-back is not optional** — the design draws it as a checkbox, but making it one
/// would let someone turn off the check that distinguishes "the reader returned 90 00" from "the
/// bytes are on the tag", which is the guarantee this app is built on. It is shown, always on, and
/// says why.
private struct WriteOptionsCard: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            // The design's third switch here is "Write on scan". It is not repeated: the Auto-Write
            // card above owns that value and surrounds it with the arming state and the sector-key
            // gate, which a bare checkbox cannot carry. Two controls for one setting on one screen
            // reads as a bug even when they stay in sync.
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify by read-back").font(.system(size: 13))
                    Text("Always on. A reader answering 90 00 means the command was accepted, not that the bytes landed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Verify by read-back, always on")

            Toggle("Add to inventory", isOn: $settings.addWrittenSpoolsToInventory)
                .help("Log the spool to stock after a verified write. Turn off when replacing a damaged tag on a spool that is already listed.")
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Theme.Spacing.l)
    }
}
