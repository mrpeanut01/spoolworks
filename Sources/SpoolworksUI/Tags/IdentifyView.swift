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
    @State private var showDebug = false

    private var model: TagViewModel { env.tagModel }
    private var monitor: ReaderMonitor { env.monitor }

    /// The inventory row this tag belongs to, if any.
    private var matched: Spool? {
        guard let record = model.lastRead?.record else { return nil }
        return env.inventoryModel.existing(for: record)
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

                HStack(alignment: .top, spacing: 24) {
                    hero.frame(maxWidth: .infinity, alignment: .topLeading)
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
        .onAppear { model.mode = .read }
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

            HStack(spacing: 10) {
                Button("Read tag") { Task { await model.read() } }
                    .buttonStyle(.sw(.primary, h: 16, v: 10))
                    .disabled(!model.canRead)
                if let spool = matched {
                    Button("Retire spool") { env.inventoryModel.retireTarget = spool }
                        .buttonStyle(.sw(.secondary, h: 16, v: 10))
                }
                Spacer(minLength: Theme.Spacing.m)
                Text("Identity is the tag's serial, filament ID and colour. Either of a spool's two tags resolves the same record.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 320, alignment: .trailing)
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
                    Text(matched == nil ? "Not in inventory" : "Matched in inventory")
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
                Text("Spoolworks reads Creality factory tags and tags it wrote itself. The record it decodes is matched against your inventory by serial, filament ID and colour.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
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
            let consumed = matched.netWeightGrams - matched.remainingGrams
            let jobs = matched.usage.filter { $0.deltaGrams < 0 }.count
            used = "\(consumed) g over \(jobs) entr\(jobs == 1 ? "y" : "ies")"
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
