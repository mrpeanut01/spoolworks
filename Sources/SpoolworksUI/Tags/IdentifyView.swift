import SwiftUI
import SpoolworksCore

/// Put a tag on the reader and find out which spool it is.
///
/// This is the design's reframing of the old Read screen, and the reframing is the point: the
/// question a spool tag answers is not "what bytes are on this tag" but **"which of my spools is
/// this, and how much is left"**. So the tag's decoded fields move to a secondary panel and the
/// matched inventory record takes the hero.
///
/// The old Reader diagnostics screen is folded in here as the right-hand column, where its output
/// is actually wanted, rather than living as a separate destination nobody visits until something
/// is broken.
struct IdentifyView: View {
    @ObservedObject var env: AppEnvironment
    /// Observed individually, not reached through `env`.
    ///
    /// This is the same trap the header bar documents, and it is what made this screen look broken:
    /// `AppEnvironment` holds these as plain `let`s, and a nested `ObservableObject` does not
    /// republish through its owner. Reaching `env.tagModel.lastRead` from a computed property
    /// therefore *read* the right value and never re-rendered when it changed — so a tag was read,
    /// the record was decoded, and the screen went on showing whatever had been there when it was
    /// last drawn. Both reported symptoms, "it does not read" and "it starts pre-filled", were the
    /// one missing subscription.
    @ObservedObject var model: TagViewModel
    @ObservedObject var monitor: ReaderMonitor
    @ObservedObject var inventory: InventoryViewModel

    @State private var showDebug = false
    /// Tags answered "Not this time", so presenting one again does not ask again.
    @State private var declinedLookalikeUIDs: Set<[UInt8]> = []
    /// Why the last tag presented during a pairing was not the spool's other side.
    @State private var pairingProblem: String?
    /// A tag read for the spool the user asked to attach, that does not look like that spool.
    @State private var unlikeReadUID: [UInt8]?

    /// The untagged spool waiting for this read, if the user asked for one from Inventory.
    private var attachTarget: Spool? {
        guard let id = inventory.awaitingTagFor else { return nil }
        return inventory.inventory.spool(id: id)
    }

    /// What the catalogue calls a record's filament. The tag carries only the id.
    private func catalogue(_ record: SpoolRecord) -> (brand: String, name: String, type: String) {
        let row = env.materialsModel.rows.first { $0.id == record.materialId }
        return (row?.brand ?? "", row?.name ?? "", row?.materialType ?? "")
    }

    /// `"Creality Hyper PLA · #FFFFFF"`, or the filament id where the catalogue has no name.
    private func tagDescription(_ record: SpoolRecord) -> String {
        let described = catalogue(record)
        let head = [described.brand, described.name].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(head.isEmpty ? "filament \(record.filamentId)" : head) · #\(record.rgbHex)"
    }

    /// Binds a read tag to `spool`, and starts waiting for the spool's other side.
    ///
    /// The source is derived from the tag rather than assumed: `isProgrammed` means sector 1 opened
    /// with the UID-derived key, which is only true of a tag something in this family wrote. A
    /// factory tag opens with the default key, and calling it Spoolworks-written would be a claim
    /// about provenance the app has no basis for.
    private func attach(_ read: TagReadResult, to spool: Spool) {
        guard let record = read.record else { return }
        inventory.attachTag(to: spool)
        inventory.attachTag(record: record,
                            materialType: catalogue(record).type,
                            source: read.isProgrammed ? .spoolworksWritten : .crealityFactory,
                            readUIDs: [read.uid])
    }

    /// Decides what a freshly read tag means here: the other side of a spool being paired, the tag
    /// a spool was waiting for, or simply a tag to identify.
    private func handleRead() {
        pairingProblem = nil
        unlikeReadUID = nil
        guard let read = model.lastRead else { return }

        if let pairing = inventory.pairing {
            if pairing.isComplete {
                // A finished pairing stays on screen for its own tags and gives way to the next.
                if !pairing.contains(read.uid) { inventory.endPairing() }
            } else {
                switch inventory.absorbPairedRead(uid: read.uid, record: read.record) {
                case .sameTag, .completed: return
                case let .mismatch(why):
                    pairingProblem = why
                    return
                case .notPairing: break
                }
            }
        }

        guard let target = attachTarget, let record = read.record else { return }
        let described = catalogue(record)
        // Asked for by the user, so only a tag that is *evidently* another spool is questioned —
        // a black PETG tag presented for a white PLA record is a wrong spool picked up, and
        // attaching it would quietly rewrite that record's colour.
        if target.couldBe(brand: described.brand, name: described.name,
                          filamentId: record.filamentId, colorHex: record.rgbHex) {
            attach(read, to: target)
        } else {
            unlikeReadUID = read.uid
        }
    }

    /// Untagged spools in stock the tag on screen looks like — the offer made when nobody asked.
    private var lookalikes: [Spool] {
        guard attachTarget == nil, let read = model.lastRead, let record = read.record,
              !declinedLookalikeUIDs.contains(read.uid) else { return [] }
        if let pairing = inventory.pairing, pairing.contains(read.uid) || !pairing.isComplete {
            return []
        }
        let described = catalogue(record)
        return inventory.untaggedLookalikes(for: record, brand: described.brand, name: described.name)
    }

    /// The inventory row this tag belongs to, if any.
    ///
    /// A tag just attached answers for itself: with factory tags alike across every spool of a
    /// filament and colour, looking the record up would return whichever twin was listed first.
    private var matched: Spool? {
        guard let read = model.lastRead, let record = read.record else { return nil }
        if let pairing = inventory.pairing, pairing.contains(read.uid),
           let spool = inventory.inventory.spool(id: pairing.spoolID) {
            return spool
        }
        return inventory.existing(for: record)
    }

    private var heroKicker: String {
        guard let read = model.lastRead, let record = read.record, matched != nil else {
            return "Not in inventory"
        }
        if let pairing = inventory.pairing, pairing.contains(read.uid) { return "Attached to this spool" }
        let identity = SpoolIdentity(record: record)
        let sharing = inventory.inventory.active.filter { $0.identity == identity }.count
        return sharing > 1 ? "One of \(sharing) spools with this tag" : "Matched in inventory"
    }

    /// The offer to attach a tag nobody asked about to the untagged spool it looks like.
    private func lookalikePrompt(_ first: Spool, others: [Spool], read: TagReadResult) -> some View {
        var message = "This tag matches \(first.label), which is in stock without a tag "
            + "(\(first.location.description)). If that is the spool on the reader, attach the tag to it."
        if let record = read.record, let twin = inventory.existing(for: record), twin.id != first.id {
            message += twin.location.isOnPrinter
                ? " It reads the same as \(twin.label) in \(twin.location.description) because "
                    + "Creality tags for one filament and colour are identical — but that spool is "
                    + "in the printer, not on the reader."
                : " It also reads the same as \(twin.label) (\(twin.location.description)) — "
                    + "Creality tags for one filament and colour are identical, so the tag alone "
                    + "cannot say which spool it is."
        }
        return SpoolPrompt(message: message) {
            Button("Attach to this spool") { attach(read, to: first) }
            if !others.isEmpty {
                Menu("A different one") {
                    ForEach(others) { spool in
                        Button("\(spool.label) · \(spool.location.description)") {
                            attach(read, to: spool)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button("Not this time") { declinedLookalikeUIDs.insert(read.uid) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(kicker: "Place a spool tag on the reader", title: "Read / identify") {
                    HStack(spacing: 9) {
                        Button("Read tag") { Task { await model.read() } }
                            .buttonStyle(.sw(.secondary))
                            .disabled(!model.canRead)
                        Button(showDebug ? "Hide tag memory" : "Show tag memory") {
                            showDebug.toggle()
                        }
                        .buttonStyle(.sw(.ghost))
                    }
                }
                .padding(.bottom, 18)
                Rule().padding(.bottom, 20)

                // Which spool this read is for, when it is for one. Without it the screen looks
                // identical whether the next tag attaches to a record in stock or merely gets
                // identified, and those are very different outcomes.
                if let pairing = inventory.pairing,
                   let spool = inventory.inventory.spool(id: pairing.spoolID) {
                    PairingBanner(spool: spool, pairing: pairing, problem: pairingProblem) {
                        inventory.endPairing()
                        pairingProblem = nil
                    }
                    .padding(.bottom, 18)
                } else if let target = attachTarget {
                    Group {
                        if let read = model.lastRead, read.uid == unlikeReadUID {
                            SpoolPrompt(symbol: "exclamationmark.triangle.fill",
                                        tint: Theme.warning,
                                        message: "This tag reads as "
                                            + (read.record.map(tagDescription) ?? "no spool record")
                                            + ", which does not look like \(target.label). Attach it "
                                            + "to that spool anyway?") {
                                Button("Attach anyway") {
                                    attach(read, to: target)
                                    unlikeReadUID = nil
                                }
                                Button("Not this tag") { unlikeReadUID = nil }
                                Button("Stop attaching") {
                                    inventory.cancelTagRequest()
                                    unlikeReadUID = nil
                                }
                            }
                        } else {
                            AttachBanner(spool: target, direction: .read) {
                                inventory.cancelTagRequest()
                            }
                        }
                    }
                    .padding(.bottom, 18)
                } else if let first = lookalikes.first, let read = model.lastRead {
                    lookalikePrompt(first, others: Array(lookalikes.dropFirst()), read: read)
                        .padding(.bottom, 18)
                }

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        hero
                        // The spool is already in front of you. Sending someone to Inventory to
                        // say "this one is nearly empty" is a round trip through a screen they
                        // were just on, so the same controls appear here — the same ones, not a
                        // second set that could disagree about what a tenth of a spool means.
                        if let spool = matched {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Correct this spool").kicker().padding(.bottom, 12)
                                SpoolEditControls(spool: spool,
                                                  model: inventory,
                                                  materials: env.materialsModel)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(padding: 20)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 18) {
                        readerPanel
                        if showDebug { memoryPanel }
                    }
                    .frame(width: 380)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Theme.background)
        // Blank on arrival, then read whatever is on the reader. Verifying a tag you have just
        // written is the main reason to come here, and the answer has to come from the tag rather
        // than from what the write left behind — see `beginIdentification`.
        .onAppear { model.beginIdentification() }
        // A read asked for from Inventory attaches to the spool that asked. Keyed on the UID rather
        // than the record, for the same reason Intake is: a spool's two tags carry the *same*
        // payload, so watching the record would miss the second one entirely.
        .onChange(of: model.lastRead?.uid ?? []) { _, _ in handleRead() }
        // The loop. Every arrival is a new presentation, including the *same* tag lifted and put
        // back — which the model otherwise treats as nothing having happened, deliberately, because
        // on every other screen one tag means one read. Here re-presenting a tag is the gesture:
        // check this spool, check the next, check that one again.
        .onChange(of: monitor.insertionCount) { _, _ in model.beginIdentification() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroTop
                .padding(22)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
                }

            statsRow
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.rule).frame(height: Theme.ruleWidth)
                }

            // "Read tag" is in the screen header and was here too — one screen, one control. The
            // paragraph about what identity means went with it: the screen states the answer, and
            // the reasoning lives in `SpoolIdentity`.
            HStack(spacing: 10) {
                Button("Clear") { model.clearRetainedRead() }
                    .buttonStyle(.sw(.secondary, h: 16, v: 10))
                    .disabled(model.lastRead == nil && model.readFailure == nil)
                    .accessibilityLabel("Clear the tag on screen")
                if let spool = matched {
                    Button("Retire spool") { inventory.retireTarget = spool }
                        .buttonStyle(.sw(.outline, h: 16, v: 10))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(Theme.surface)
        .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
    }

    @ViewBuilder
    private var heroTop: some View {
        if let record = model.lastRead?.record {
            HStack(alignment: .top, spacing: 20) {
                Swatch(hex: record.rgbHex, size: 120)
                VStack(alignment: .leading, spacing: 0) {
                    Text(heroKicker)
                        .kicker()
                        .padding(.bottom, 8)
                    Text(matched?.label ?? "Filament \(record.filamentId)")
                        .font(Theme.heroTitle)
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                    Text(subtitle(record))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.secondaryLabel)
                        .padding(.bottom, 14)
                    HStack(spacing: 8) {
                        SWTag(text: (matched?.tagSource ?? .crealityFactory).description, style: .neutral)
                        SWTag(text: "serial \(record.serialNumber)", style: .outline)
                        if let matched {
                            SWTag(text: matched.location.description, style: .accent)
                        }
                    }
                }
                Spacer(minLength: Theme.Spacing.m)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Remaining").kicker()
                    Text(matched?.remainingLabel ?? "—")
                        .font(Theme.monoFigure(38))
                        .foregroundStyle(Theme.label)
                    Text(matched?.remainingGramsLabel ?? Spool.weightLabel(record.weightGrams) + " net")
                        .font(Theme.monoCaption)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
        } else if let failure = model.readFailure {
            InlineFailure(text: failure)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(monitor.state.card == nil ? "No tag on the reader" : "Tag present, not read yet")
                    .kicker()
                Text("Place a spool tag on the reader")
                    .font(Theme.heroTitle)
                    .foregroundStyle(Theme.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitle(_ record: SpoolRecord) -> String {
        var parts: [String] = []
        if let matched, !matched.materialType.isEmpty { parts.append(matched.materialType) }
        parts.append("\(Spool.weightLabel(record.weightGrams)) net")
        parts.append("colour #\(record.rgbHex)")
        parts.append("vendor \(record.vendorId)")
        return parts.joined(separator: " · ")
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                VStack(alignment: .leading, spacing: 6) {
                    Text(stat.0).kicker()
                    Text(stat.1)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .overlay(alignment: .trailing) {
                    if index < stats.count - 1 {
                        Rectangle().fill(Theme.separator).frame(width: 1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var stats: [(String, String)] {
        guard let record = model.lastRead?.record else {
            return [("Filament ID", "—"), ("Last CFS reading", "—"), ("Used since intake", "—")]
        }
        let used: String
        if let matched {
            let jobs = matched.usage.filter { $0.kind == .job }.count
            used = jobs > 0
                ? String(format: "%.0f g over %d job%@", matched.consumedGrams, jobs,
                         jobs == 1 ? "" : "s")
                : String(format: "%.0f g", matched.consumedGrams)
        } else {
            used = "not in inventory"
        }
        return [
            ("Filament ID", "\(record.filamentId) · vendor \(record.vendorId)"),
            ("Last reading", matched?.remainingSource ?? "—"),
            ("Used since intake", used),
        ]
    }

    // MARK: Reader

    private var readerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reader").kicker().padding(.bottom, 12)
            DataRow("Device", deviceName)
            DataRow("Tag ID", uidLabel, mono: true)
            DataRow("Type", cardType)
            DataRow("Sector 1", sectorState)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(padding: 18)
    }

    private var deviceName: String {
        monitor.state.deviceNames.first ?? "none"
    }

    private var uidLabel: String {
        guard let uid = model.lastRead?.uid else { return "—" }
        return uid.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private var cardType: String {
        monitor.state.card.map { "\($0.type)" } ?? "—"
    }

    private var sectorState: String {
        guard let read = model.lastRead else { return "—" }
        return read.isProgrammed ? "Encrypted · UID key" : "Factory key"
    }

    // MARK: Tag memory

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tag memory · debug").kicker()
                Spacer()
                Text("blocks 4–6").font(Theme.monoSmall).foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.bottom, 12)

            // Slicing blind would trap: `decryptedSector1` is 48 bytes on a good read, but a
            // truncated one is exactly the case this panel exists to show.
            if let read = model.lastRead, read.decryptedSector1.count >= 48 {
                ForEach(0..<3, id: \.self) { block in
                    let bytes = Array(read.decryptedSector1[(block * 16)..<((block + 1) * 16)])
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Block \(block + 4)").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("decrypted").kicker()
                        }
                        Text(bytes.map { String(format: "%02X", $0) }.joined())
                            .font(Theme.monoSmall)
                            .foregroundStyle(Theme.secondaryLabel)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Hairline() }
                }
            } else if let read = model.lastRead {
                Text("Sector 1 decrypted to \(read.decryptedSector1.count) bytes, not the 48 a spool record occupies.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Read a tag to see its memory.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Text("Kept from the original read-tag screen for diagnostics only. Identification never needs it.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
    }
}
