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
                        if let outcome = model.writeOutcome {
                            WriteOutcomeCard(outcome: outcome, model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    WriteVerifyPanel(model: model, monitor: monitor)
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
                 state: "on intake"),
        ]
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return Theme.success
        case "ready": return Theme.accent
        default: return Theme.kickerLabel
        }
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
