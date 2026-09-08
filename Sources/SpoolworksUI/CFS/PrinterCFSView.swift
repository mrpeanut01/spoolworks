import SwiftUI
import SpoolworksCore

/// What the printer and its CFS units are holding right now.
///
/// Everything on this screen is read from `material_box_info.json` over SSH. Nothing is simulated:
/// with no printer configured the screen says so and offers the way forward, rather than rendering
/// a plausible-looking CFS that does not exist.
struct PrinterCFSView: View {
    @ObservedObject var model: CFSViewModel
    @ObservedObject var inventory: InventoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Read from material_box_info.json · every \(Int(CFSViewModel.pollInterval)) s",
                             title: "Printer & CFS") {
                    Button(model.state.isPolling ? "Polling…" : "Poll now") {
                        Task { await model.poll() }
                    }
                    .buttonStyle(.sw(.secondary))
                    .disabled(!model.canPoll || model.state.isPolling)
                }
                .padding(.bottom, 18)

                statusStrip.padding(.bottom, model.jobSummary == nil ? 20 : 12)

                if let summary = model.jobSummary {
                    JobBanner(text: summary).padding(.bottom, 20)
                }

                if let reason = model.blockedReason {
                    EmptyPanel(kicker: "Not connected",
                               title: "Spoolworks cannot reach a printer yet",
                               message: reason)
                } else if let info = model.info {
                    content(info)
                } else {
                    EmptyPanel(kicker: "No reading yet",
                               title: "Nothing polled from the printer",
                               message: "Choose Poll now to read the CFS. Spools found in a slot that are not yet in stock are added automatically, with their measured remaining figure.")
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Theme.background)
        // Deliberately no `onDisappear { stopAutoPoll() }`. The poll is app-wide: the header
        // reports CFS state from every screen, and job consumption has to keep accruing while the
        // user is looking at Inventory or writing a tag. Tying it to this screen meant the header
        // read "not polled" until someone happened to visit it, and a print running in the
        // background went unrecorded. `startAutoPoll` is idempotent, so appearing again is safe.
        .onAppear { model.startAutoPoll() }
    }

    // MARK: Status strip

    /// The design's "CFS units attached" row. It reports rather than asks — see ``CFSViewModel``
    /// for why the prototype's None/1/2/3/4 picker is not built as a picker.
    private var statusStrip: some View {
        HStack(spacing: 16) {
            Text("CFS units attached").kicker()
            Text(model.slotSummary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text(model.note)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
            Spacer(minLength: Theme.Spacing.s)
            Text(model.freshness)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRecessed)
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ info: MaterialBoxInfo) -> some View {
        if case let .failed(detail) = model.state {
            // The previous snapshot is still on screen, so say it is stale rather than blanking it.
            InlineFailure(text: "The last poll failed — showing the previous reading. \(detail)")
                .padding(.bottom, 20)
        }

        ForEach(info.boxes) { box in
            boxSection(box).padding(.bottom, 26)
        }

        if info.hasNoCFS {
            EmptyPanel(kicker: "No CFS attached",
                       title: "Running from the external spool holder only",
                       message: "Spoolworks reads rackMaterial from the printer for the mounted spool. The holder has no sensor, so remaining is whatever was last measured or entered — weigh-in corrections carry more weight here.")
                .padding(.bottom, 26)
        }

        HStack(alignment: .top, spacing: 20) {
            holderPanel(info)
            groupingPanel(info)
        }
    }

    private func boxSection(_ box: CFSBox) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Text(box.boxID)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Theme.label)
                SWTag(text: box.state.isEmpty ? "unknown" : box.state,
                      style: box.isConnected ? .neutral : .outline)
                Spacer(minLength: Theme.Spacing.s)
                HStack(spacing: 18) {
                    metric("Temp", box.temperatureLabel)
                    metric("Humidity", box.humidityLabel)
                    metric("Firmware", box.version.isEmpty ? "—" : box.version)
                }
            }

            // Four slots to a box. A fixed four-column grid rather than an adaptive one: the
            // hardware has exactly four, and a grid that reflows to three would misrepresent it.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4),
                      spacing: 0) {
                ForEach(box.list) { slot in
                    SlotCell(slot: slot, box: box, spool: matchedSpool(slot))
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).kicker()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.label)
        }
        .accessibilityElement(children: .combine)
    }

    /// Whether per-job consumption is actually running — the only remaining source of a remaining
    /// figure when there is no CFS to measure one.
    private var gcodeEstimateState: String {
        guard let job = model.job else { return "printer not reachable" }
        return job.state.isActive ? "active" : "idle"
    }

    /// The inventory row a slot resolves to, so the cell can show the spool's own history rather
    /// than only the firmware's snapshot.
    private func matchedSpool(_ slot: CFSSlot) -> Spool? {
        guard let identity = slot.identity else { return nil }
        return inventory.inventory.spool(identity: identity)
    }

    // MARK: Side panels

    private func holderPanel(_ info: MaterialBoxInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("External spool holder · rackMaterial").kicker()

            if let rack = info.rackMaterial, rack.attach {
                HStack(alignment: .top, spacing: 14) {
                    Swatch(hex: rack.rgbHex, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(rack.brand) \(rack.name)".trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.label)
                        Text([rack.materialType,
                              rack.temperatureLabel,
                              rack.selected ? "selected" : "attached, not selected"]
                             .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Nothing mounted on the holder.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 16)
    }

    private func groupingPanel(_ info: MaterialBoxInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if info.hasNoCFS {
                Text("Usage source · external spool").kicker()
                VStack(spacing: 0) {
                    DataRow("CFS remainLen", "unavailable")
                    DataRow("Gcode estimate", gcodeEstimateState)
                    DataRow("Auto refill", "not applicable")
                }
                Text("With no CFS attached there are no slots to group. Remaining comes from what the printer reports it has extruded, corrected by weighing.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Grouped by filament and colour · same_material").kicker()
                let groups = info.material.sameMaterial
                if groups.isEmpty {
                    Text("The printer reports no groupings.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryLabel)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                            HStack(spacing: Theme.Spacing.s) {
                                // The colour is the half of the key that is easy to miss: rendered
                                // as the raw 7-character tag field it reads as a second part
                                // number, which is exactly why this panel looked as though it
                                // grouped on material alone.
                                Swatch(hex: group.colorHex, size: 14)
                                Text(group.filamentId)
                                    .font(Theme.monoCaption)
                                Text(group.colorHex)
                                    .font(Theme.monoCaption)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(group.materialType).font(.system(size: 13))
                                Text(group.slotsLabel)
                                    .font(Theme.monoCaption)
                                    .frame(width: 78, alignment: .trailing)
                                // The distinction that matters. Every filament the printer holds is
                                // listed here whether or not it has a partner, so without this the
                                // one line that actually does something looks like the other three.
                                // `spooldiag` has always marked these; the screen did not.
                                SWTag(text: group.isPartnered ? "partners" : "alone",
                                      style: group.isPartnered ? .accent : .neutral)
                            }
                            .padding(.vertical, Theme.Spacing.s)
                            .overlay(alignment: .bottom) { Hairline() }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "Filament \(group.filamentId), colour \(group.colorHex), "
                                + "\(group.materialType), "
                                + (group.isPartnered
                                   ? "slots \(group.slotsLabel) are auto-refill partners"
                                   : "slot \(group.slotsLabel), no partner"))
                        }
                    }
                }

                // What the panel is, since it looks like a control and is not one.
                Text("The printer decides these and Spoolworks only reads them — nothing here is "
                     + "a setting, and none of it turns auto refill on or off. Two slots are "
                     + "grouped only when their filament ID and their colour both match, which is "
                     + "why slots holding one filament in three colours make three groups rather "
                     + "than one.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(info.material.isAutoRefillEnabled
                     ? "Auto refill is on: the printer draws from a partner slot as one runs out. Spoolworks binds each slot to its own spool, so the handover keeps usage attributed to the right one."
                     : "Auto refill is off.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 16)
    }
}

// MARK: - Slot

private struct SlotCell: View {
    let slot: CFSSlot
    let box: CFSBox
    let spool: Spool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(slot.label(in: box))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                Spacer()
                Text(slot.tagLabel).kicker()
            }

            SwatchBar(hex: slot.isLoaded ? slot.rgbHex : "")

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.isLoaded ? (slot.name.isEmpty ? slot.filamentId : slot.name) : "Empty")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.label)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if slot.isLoaded, let percent = slot.remainingPercent {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("\(Int(percent.rounded()))%")
                            .font(Theme.monoFigure(20))
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Text("≈ \(Int((Double(slot.netWeightGrams) * percent / 100).rounded())) g")
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .padding(.bottom, 5)
                    RemainingBar(percent: percent)
                    Text(delta)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.kickerLabel)
                        .padding(.top, 6)
                        .lineLimit(1)
                }
            } else {
                Text("No spool detected")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.kickerLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.separator).frame(width: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        guard slot.isLoaded else { return "Slot is empty" }
        var parts: [String] = []
        if !slot.brand.isEmpty { parts.append(slot.brand) }
        if !slot.materialType.isEmpty { parts.append(slot.materialType) }
        if let temps = slot.temperatureLabel { parts.append(temps) }
        return parts.joined(separator: " · ")
    }

    /// What the inventory knows that the firmware snapshot does not: the most recent movement.
    private var delta: String {
        guard let spool, let last = spool.usage.first else { return "no history yet" }
        return last.deltaGrams == 0 ? last.detail : "\(last.amountLabel) · \(last.detail)"
    }
}


// MARK: - Job banner

/// What the printer is doing, and what it has taken off a spool while this screen was open.
///
/// Shown only while a job is actually running. The gram figure is measured at the extruder — the
/// CFS reports whole percent, which is 10 g at a time on a 1 kg spool, so between its readings
/// this is the finer of the two numbers.
private struct JobBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Rectangle().fill(Theme.accent).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.10))
        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
