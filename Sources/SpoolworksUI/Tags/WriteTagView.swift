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
    @ObservedObject var env: AppEnvironment
    /// Observed individually. `AppEnvironment` holds it as a plain `let`, and a nested
    /// `ObservableObject` does not republish through its owner — the same trap that made
    /// Read / identify look as though it never read anything.
    @ObservedObject var inventory: InventoryViewModel

    /// The spool this write is for, if the user asked for one from Inventory.
    private var taggingTarget: Spool? {
        guard let id = inventory.awaitingTagFor else { return nil }
        return inventory.inventory.spool(id: id)
    }

    /// The spool a tag was just attached to, so the screen can say so and invite the second tag.
    ///
    /// Read off the write outcome rather than remembered: the record on the outcome is the one that
    /// actually landed, and a spool matching it is one this write is responsible for.
    private var justTagged: Spool? {
        guard taggingTarget == nil,
              case let .succeeded(summary) = model.writeOutcome else { return nil }
        return inventory.inventory.spool(matching: summary.record)
    }

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
                        // Which spool this write belongs to, when it belongs to one. Without it the
                        // screen looks identical whether the next verified write attaches to a
                        // spool in stock or creates a new record, and those are very different.
                        if let target = taggingTarget {
                            AttachBanner(spool: target, what: "written") {
                                inventory.cancelTagRequest()
                            }
                        } else if let tagged = justTagged {
                            AttachedBanner(spool: tagged)
                        }
                        TagFormCard(monitor: monitor, model: model)
                        AutoWriteCard(monitor: monitor, model: model)
                        WriteOptionsCard()
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
        // The confirmation sheet must be attached to whichever screen builds a plan, or the plan
        // is raised against a view that is not on screen and auto-write stays blocked until
        // something else clears it. That defect is documented in `AppEnvironment.sidebarSelection`.
        .sheet(item: $model.pendingPlan) { plan in
            WriteConfirmationSheet(plan: plan, model: model) { confirmed in
                if confirmed {
                    // The plan's own claim about the tag, not a preference: a blank tag needs its
                    // sector-1 keys programmed, and Core re-checks that against its own read.
                    Task { await model.commitWrite(plan,
                                                   allowTrailerWrite: plan.isBlankTagProgramming) }
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

                // The colour as the tag actually stores it. Worth showing on its own: the field is
                // seven characters, not six, and the leading nibble is not part of the colour —
                // every implementation writes '0' there and nobody has documented what it means
                // (see SpoolRecord.color). Without this the extra digit looks like a bug.
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text("Serial · generated").kicker()
                    Text(model.draft.serialNumber)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)

                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text("Tag colour field").kicker()
                    Text(tagColourField)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    private var hasCard: Bool { monitor.state.card?.isUsable == true }

    private var steps: [WriteVerifyStep] {
        WriteVerifyStep.steps(outcome: model.writeOutcome,
                              readback: model.readback,
                              hasCard: hasCard,
                              canWrite: model.canWrite)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "done": return Theme.success
        case "ready": return Theme.accent
        case "unconfirmed": return Theme.warning
        default: return Theme.kickerLabel
        }
    }

    /// `"0C12E1F"` — the colour exactly as it is written into the record, or an em dash before
    /// one has been chosen.
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

/// One row of the "Write & verify" panel, derived from what the model has actually established.
///
/// Internal rather than nested in the panel so the derivation can be tested: the rule that
/// matters is that a step reads "done" only for a write that **succeeded**. It used to key off
/// `writeOutcome != nil`, which is also true of `.failed`, so every row went green beside a red
/// "Write Failed" card.
struct WriteVerifyStep: Equatable {
    let what: String
    let state: String

    static func steps(outcome: WriteOutcome?,
                      readback: PostWriteReadback?,
                      hasCard: Bool,
                      canWrite: Bool) -> [WriteVerifyStep] {
        let wrote: Bool
        if case .succeeded = outcome { wrote = true } else { wrote = false }
        // `TagService` verifies blocks 4–6 against what it sent before it reports success, but
        // the row promises a read-back, and the read-back the screen can vouch for is the one
        // whose record is on screen. A success the app could not read back is said to be exactly
        // that, not quietly counted as verified.
        let readBack: String
        switch (wrote, readback) {
        case (true, .confirmed?): readBack = "done"
        case (true, _): readBack = "unconfirmed"
        case (false, _): readBack = "waiting"
        }
        return [
            WriteVerifyStep(what: "Dump every readable sector",
                            state: wrote ? "done" : (hasCard ? "ready" : "waiting")),
            WriteVerifyStep(what: "Authenticate sector 1 with the UID key",
                            state: wrote ? "done" : (hasCard ? "ready" : "waiting")),
            WriteVerifyStep(what: "Write the record to blocks 4–6",
                            state: wrote ? "done" : (canWrite ? "ready" : "waiting")),
            WriteVerifyStep(what: "Read back and compare byte for byte", state: readBack),
            WriteVerifyStep(what: "Add the spool to inventory", state: wrote ? "done" : "ready"),
        ]
    }
}


// MARK: - Options

/// One line, stating the guarantee the whole screen rests on.
///
/// **Verify by read-back is not optional.** The design draws it as a checkbox; making it one would
/// let someone turn off the check that distinguishes "the reader returned 90 00" from "the bytes
/// are on the tag". It is shown and always on. The paragraph that used to explain *why* is gone —
/// it is in the docs, and the reason a screen states a guarantee is so you can see it holds, not so
/// you can read an essay about it.
///
/// The "Add to inventory" checkbox that sat beside it is gone too, with the setting behind it: a
/// verified write now always logs its spool. It existed for re-tagging a spool already in stock,
/// which the attach flow handles properly — and `logWrittenSpool` matches an existing record by
/// identity anyway, so leaving it on never created a duplicate.
private struct WriteOptionsCard: View {

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.square.fill")
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text("Verify by read-back · always on").font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Theme.Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

/// Says a tag landed on a spool already in stock, and that the second one is ready to write.
///
/// The write outcome panel says "written and verified", which is true and answers the wrong
/// question: the user's question is whether the spool in their hand now *has* this tag. It also
/// invites the second tag explicitly, because a spool carries one on each side of the hub and the
/// form is already holding the right payload to write it — the same serial, deliberately, since
/// both sides must carry the same record.
private struct AttachedBanner: View {
    let spool: Spool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text("Saved to \(spool.label). Present another blank tag to write this spool's second "
                 + "side — it gets the same payload.")
                .font(Theme.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.success.opacity(0.10))
        .overlay(Rectangle().strokeBorder(Theme.success, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
