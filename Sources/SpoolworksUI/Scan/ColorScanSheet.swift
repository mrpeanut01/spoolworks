import SwiftUI
import SpoolworksCore

/// Point the camera at the spool, hold still, take the colour — or point it at the box and take
/// the barcode, which says the maker, the line and the colour in one go.
///
/// The sheet's whole job is to make one thing unambiguous: **which reading is worth taking**. A live
/// colour readout is always showing *something*, and a user with no way to tell a settled
/// measurement from a value that happens to be on screen will take whichever one was there when
/// they reached for the mouse. So the reticle turns green, the button changes its own label, and the
/// window's own summary line says whether the frames agree yet.
///
/// The colour is never applied silently. It is handed back for confirmation, into a field the user
/// can still type over — see the note about white balance in ``CameraColorScanner``, which is the
/// honest reason a camera reading is a good starting point rather than an answer.
struct ColorScanSheet: View {

    /// The form's colour, written **as soon as a reading settles** rather than when the sheet is
    /// dismissed.
    ///
    /// It began as a `(String) -> Void` fired from the Use button, and that was wrong twice over.
    /// It made the commit depend on the dismissal — one state write and one sheet teardown in the
    /// same runloop turn, in a view that already presents a second sheet — which is a fragile place
    /// to put the only thing this screen exists to do. And it meant a settled, obviously-correct
    /// reading still needed a button press to become real.
    ///
    /// A binding writes through immediately and the button is only a way out.
    @Binding var hex: String

    /// What the form already says the filament is, so the matches offered are *this maker's*
    /// colours first. All three may be empty, in which case every maker is searched.
    var brand: String = ""
    var line: String = ""
    var material: String = ""
    /// Told which maker's colour was chosen from the list, or nil when the choice is undone.
    var onPickFilament: (BrandColour?) -> Void = { _ in }

    /// Which of the two the sheet opens on.
    var startsOn: CameraColorScanner.Mode = .colour
    /// Says what a box barcode is, or nil when the caller has no use for one — the barcode mode is
    /// then not offered at all.
    var resolveBarcode: ((String) -> BarcodeFilament?)? = nil
    /// Told which barcode was read and what it turned out to be. A nil filament is a box nobody
    /// has described yet: the caller keeps the code, so describing the spool teaches it.
    var onBarcode: (String, BarcodeFilament?) -> Void = { _, _ in }

    /// The filaments nearest the taken reading.
    @State private var matches: [BrandColourCatalogue.Match] = []
    /// The one the user chose, if any. Its hex has replaced the reading in the form.
    @State private var picked: BrandColour?
    /// Every colour the maker sells this filament in — nearest the reading first once there is
    /// one, by name until then.
    @State private var makerColours: [BrandColour] = []
    @State private var makerScope: BrandColourCatalogue.Scope = .anywhere

    @StateObject private var scanner = CameraColorScanner()
    @ObservedObject private var nameCache = ColorNameCache.shared
    @Environment(\.dismiss) private var dismiss

    /// The reading that has been taken, latched.
    ///
    /// Latched rather than tracking live: once the corners turn green the value is the one that
    /// will be saved, and a number that keeps moving after it has been ticked is a number you
    /// cannot act on. `Re-measure` is how you take another.
    @State private var accepted: String?
    /// What the field held on the way in, so `Cancel` can undo an automatic acceptance.
    @State private var original: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rule()
            content
            Rule()
            footer
        }
        .frame(width: 640, height: 760)
        .background(Theme.background)
        .task {
            original = hex
            scanner.mode = resolveBarcode == nil ? .colour : startsOn
            await scanner.start()
        }
        // The acceptance. Anything that has held still for a full window is as good as this
        // scanner gets, so it is taken without asking — see `accepted`.
        .onChange(of: scanner.reading?.isSteady == true) { _, steady in
            guard steady, accepted == nil, let reading = scanner.reading else { return }
            accepted = reading.color.hexString
            // A maker's colour chosen off the list before the reading settled is the user's
            // answer; the reading then only orders the list, it does not replace the choice.
            if picked == nil { hex = reading.color.hexString }
        }
        .task(id: "\(accepted ?? "")|\(brand)|\(line)|\(material)") {
            if let accepted { await nameCache.resolve([accepted]) }
            // Seventeen thousand colours and a CIEDE2000 each — a few milliseconds, but not ones
            // to spend on the main thread while the preview is drawing.
            let (brand, line, material, accepted) = (brand, line, material, accepted)
            let found = await Task.detached(priority: .userInitiated) {
                let catalogue = BrandColourCatalogue.shared
                var listed = catalogue.colours(brand: brand, name: line, material: material)
                var nearest: [BrandColourCatalogue.Match] = []
                if let accepted {
                    nearest = catalogue.matches(brand: brand, name: line, material: material,
                                                hex: accepted, limit: 4)
                    if let rgb = try? RGB8(hex: accepted) {
                        let lab = LabColor(rgb)
                        func distance(_ colour: BrandColour) -> Double {
                            (try? RGB8(hex: colour.hex)).map { lab.deltaE2000(to: LabColor($0)) } ?? .infinity
                        }
                        listed.colours.sort { distance($0) < distance($1) }
                    }
                }
                return (listed, nearest)
            }.value
            guard !Task.isCancelled else { return }
            makerColours = found.0.colours
            makerScope = found.0.scope
            matches = found.1
        }
        .onDisappear { scanner.stop() }
    }

    private var isBarcode: Bool { scanner.mode == .barcode }

    /// Takes a maker's colour in place of the reading, or — with nil — goes back to the reading.
    private func choose(_ colour: BrandColour?) {
        picked = colour
        if let colour {
            hex = colour.hex
        } else if let fallback = accepted ?? original {
            hex = fallback
        }
        onPickFilament(colour)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isBarcode ? "Step 2 · The box" : "Step 2 · Colour").kicker()
            Text(isBarcode ? "Scan the box's barcode" : "Scan the filament")
                .font(.system(size: 20, weight: .heavy))
            Text(isBarcode
                 ? "Hold the barcode on the box up to the camera. It names the maker, the product "
                   + "line and the colour exactly — nothing is measured, so the lighting does not "
                   + "matter."
                 : "Hold the spool so the box is filled with filament and nothing else. "
                   + "Several points across the box are measured, so the shadow between strands and "
                   + "the shine along them are discarded rather than averaged in.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            if resolveBarcode != nil {
                SegmentedFilter(options: CameraColorScanner.Mode.allCases,
                                title: { $0 == .barcode ? "The box's barcode" : "The filament's colour" },
                                selection: $scanner.mode)
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch scanner.state {
        case .running:
            liveBody
        case .idle, .requestingAccess:
            message(symbol: "camera",
                    title: "Starting the camera…",
                    detail: "macOS will ask for permission the first time.")
        case .denied:
            message(symbol: "camera.metering.none",
                    title: "Spoolworks cannot use the camera",
                    detail: "Camera access is off for this app. Turn it on in System Settings ▸ "
                          + "Privacy & Security ▸ Camera, then reopen this window.",
                    isProblem: true)
        case .noCamera:
            message(symbol: "video.slash",
                    title: "No camera found",
                    detail: "Connect a USB camera, or use an iPhone as a Continuity Camera — an "
                          + "iPhone focuses within a few centimetres, which a built-in Mac camera "
                          + "cannot, and gives a much better reading.",
                    isProblem: true)
        case .notInAnAppBundle:
            // Only reachable from `swift run`, and worth saying plainly rather than crashing.
            // AVFoundation terminates a process that touches the camera without the usage
            // description, and a bare SwiftPM binary has no Info.plist to put it in.
            message(symbol: "hammer",
                    title: "Not available in this build",
                    detail: "Camera scanning needs the app bundle, which carries the camera usage "
                          + "description macOS requires. Build it with Tools/make-app.sh and run "
                          + "Spoolworks.app.",
                    isProblem: true)
        case let .failed(reason):
            message(symbol: "exclamationmark.triangle",
                    title: "The camera could not be started",
                    detail: reason,
                    isProblem: true)
        }
    }

    private var liveBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            CameraPreview(session: scanner.session,
                          isSettled: isBarcode ? scanner.barcode != nil
                                               : scanner.reading?.isSteady == true,
                          tick: scanner.frameTick)
                .frame(maxWidth: .infinity, minHeight: 300)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
                .accessibilityLabel("Camera preview with a target square in the centre")

            Group {
                if isBarcode { barcodeReadout } else { readout }
            }
            .padding(20)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Swatch(hex: shownHex, size: 64, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // The tick is the whole point of accepting automatically: it says which
                        // value is the one that will be saved, without the user having to decide
                        // when the number had stopped moving.
                        if accepted != nil || picked != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.success)
                                .accessibilityHidden(true)
                        }
                        Text(shownName ?? "—")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text("#" + shownHex)
                        .font(Theme.monoCaption)
                        .foregroundStyle(Theme.secondaryLabel)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let reading = scanner.reading {
                    VStack(alignment: .trailing, spacing: 5) {
                        SWTag(text: accepted != nil ? "Taken"
                                                    : (reading.isSteady ? "Steady" : "Hold still"),
                              style: accepted != nil || reading.isSteady ? .accent : .neutral)
                        // Confidence and steadiness are different questions and both matter: a
                        // rock-steady reading of a badly lit target is steady and wrong.
                        HStack(spacing: 6) {
                            StatusDot(level: dotLevel(reading.confidence), size: 8)
                            Text(reading.confidence.title)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenReading)

            Hairline().padding(.bottom, 12)

            // At most one piece of advice at a time. A stack of four warnings on a mediocre shot
            // is a wall of text nobody reads; the first one is the one to fix first.
            if !makerColours.isEmpty || picked != nil {
                makerColourPicker.padding(.bottom, 10)
            }
            if let picked {
                if accepted != nil, !matches.isEmpty {
                    closestFilaments.padding(.bottom, 10)
                }
                Text("Using \(picked.brand)'s “\(picked.name)” in place of "
                     + (accepted == nil ? "a reading" : "the reading")
                     + ". Choose “As measured” to go back to what the camera sees.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else if accepted != nil {
                if !matches.isEmpty {
                    closestFilaments.padding(.bottom, 10)
                }
                Text("Taken — this colour is already in the form. Save to close, Re-measure to "
                     + "take another, or Cancel to put back what was there.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let warning = scanner.reading?.warnings.first {
                InlineFailure(text: warning.guidance)
            } else {
                Text("Keep the box filled with filament until the corners turn green — the reading "
                     + "is taken for you as soon as it settles.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The filaments this reading most resembles — the maker's own colours when the form says who
    /// the maker is, anyone's when it does not.
    ///
    /// A camera reading is a colour; what goes on a label is a filament. The reading alone names
    /// itself "Malibu Dune", and the box says "Skin". Offering the nearest real filaments here is
    /// the moment that gap can be closed, while the spool is still in the user's hand to compare.
    ///
    /// Choosing one replaces the reading with that filament's own colour. That is deliberate: two
    /// spools of one filament then carry one colour rather than two slightly different camera
    /// readings, which is what lets the inventory — and the printer — treat them as the same.
    private var closestFilaments: some View {
        let anywhere = matches.first?.scope == .anywhere
        return VStack(alignment: .leading, spacing: 6) {
            Text(anywhere ? "Closest filaments"
                          : "Closest \(matches.first?.colour.brand ?? "") filaments").kicker()
            FilamentMatchChips(matches: matches, showsBrand: anywhere, selectedID: picked?.id) { match in
                choose(picked?.id == match.id ? nil : match.colour)
            }
        }
    }

    /// The maker's own names for this filament's colours — all of them, not only the near ones.
    ///
    /// The chips above are the camera's guess at which it is. This is for when the user already
    /// knows, because it is printed on the box in their other hand: the name can be chosen before
    /// anything has been measured, and no reading is needed at all.
    private var makerColourPicker: some View {
        // A chip's colour need not be in the list — it may come from another line, or be the
        // other source's reading of the same name — and a picker with no row for its own
        // selection renders blank.
        let listed = makerColours.contains { $0.id == picked?.id }
        return HStack(spacing: Theme.Spacing.s) {
            Text(makerScope == .line ? "Maker's colours" : "Maker's range").kicker()
            Picker("", selection: Binding(get: { picked?.id ?? "" },
                                          set: { id in choose(makerColours.first { $0.id == id }) })) {
                Text(accepted == nil ? "Not chosen" : "As measured").tag("")
                if let picked, !listed {
                    Text(Self.menuTitle(picked, showsLine: true)).tag(picked.id)
                }
                ForEach(makerColours) { colour in
                    Text(Self.menuTitle(colour, showsLine: makerScope != .line)).tag(colour.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
            .accessibilityLabel("The maker's name for this colour")
            Spacer(minLength: 0)
        }
    }

    static func menuTitle(_ colour: BrandColour, showsLine: Bool) -> String {
        showsLine && !colour.line.isEmpty ? "\(colour.name) · \(colour.line)" : colour.name
    }

    // MARK: Barcode

    /// What the box's barcode turned out to be.
    private var barcodeReadout: some View {
        let found = scanner.barcode.flatMap { resolveBarcode?($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                if let found {
                    Swatch(hex: found.hex, size: 64, height: 52)
                } else {
                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.secondaryLabel)
                        .frame(width: 64, height: 52)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(found.map { "\($0.product) · \($0.colourName)" }
                         ?? (scanner.barcode == nil ? "Looking for a barcode…" : "Not a box Spoolworks knows"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(barcodeDetail(found))
                        .font(Theme.monoCaption)
                        .foregroundStyle(Theme.secondaryLabel)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if scanner.barcode != nil {
                    SWTag(text: found == nil ? "Unlisted"
                                             : (found?.source == .learned ? "Seen before" : "Found"),
                          style: found == nil ? .neutral : .accent)
                }
            }
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)

            Hairline().padding(.bottom, 12)

            Text(barcodeAdvice(found))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barcodeDetail(_ found: BarcodeFilament?) -> String {
        guard let code = scanner.barcode else { return "EAN-13 or UPC-A, usually on the end of the box" }
        var parts = [BoxBarcode.display(code)]
        if let found {
            parts.append("#" + found.hex)
            if let grams = found.netWeightGrams { parts.append(Spool.weightLabel(grams)) }
        }
        return parts.joined(separator: " · ")
    }

    private func barcodeAdvice(_ found: BarcodeFilament?) -> String {
        guard scanner.barcode != nil else {
            return "Keep the whole barcode in view and in focus. A Mac's built-in camera focuses "
                + "at arm's length, so hold the box back rather than close."
        }
        guard found != nil else {
            return "No filament is listed under this barcode. Describe the spool on the form — "
                + "scan its colour, or choose it from the maker's list — and the barcode is "
                + "remembered, so the next box of it is one scan."
        }
        return "Use it to fill in the maker, the material and the colour. The colour is the "
            + "maker's published one; everything stays editable."
    }

    private func message(symbol: String, title: String, detail: String,
                         isProblem: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(isProblem ? Theme.danger : Theme.secondaryLabel)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if scanner.cameras.count > 1 {
                Picker("", selection: $scanner.selectedCameraID) {
                    ForEach(scanner.cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .accessibilityLabel("Camera")
            }

            if scanner.state == .running, isBarcode {
                if scanner.barcode != nil {
                    Button("Scan again") { scanner.resetReading() }
                        .buttonStyle(.sw(.ghost))
                        .help("Forgets this barcode and looks for another.")
                }
            } else if scanner.state == .running {
                Button("Re-measure") {
                    accepted = nil
                    choose(nil)
                    scanner.resetReading()
                }
                    .buttonStyle(.sw(.ghost))
                    .help("Throws away the last second of frames and starts the measurement again.")
            }

            Spacer(minLength: 0)

            Button("Cancel") {
                // Undoes an automatic acceptance. Taking a reading without being asked is only
                // reasonable if leaving without saving puts back exactly what was there.
                if let original { hex = original }
                onPickFilament(nil)
                dismiss()
            }
            .buttonStyle(.sw(.ghost))
            .keyboardShortcut(.cancelAction)

            if isBarcode {
                barcodeAction
            } else {
                Button(useTitle) {
                    // Nothing to commit when a reading has already been taken, or a maker's colour
                    // chosen — the binding wrote it at the time. This only closes.
                    if accepted == nil, picked == nil, let reading = scanner.reading {
                        hex = reading.color.hexString
                    }
                    dismiss()
                }
                .buttonStyle(.sw(.primary))
                .disabled(scanner.reading == nil && accepted == nil && picked == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    /// The barcode mode's way out, which depends on whether the box was recognised: a known box
    /// fills the form and closes, an unknown one hands over to the colour scan with the code kept.
    @ViewBuilder
    private var barcodeAction: some View {
        let code = scanner.barcode
        if let code, let found = resolveBarcode?(code) {
            Button("Use this filament") {
                onBarcode(code, found)
                dismiss()
            }
            .buttonStyle(.sw(.primary))
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Scan the colour instead") {
                if let code { onBarcode(code, nil) }
                scanner.mode = .colour
            }
            .buttonStyle(.sw(.primary))
            .disabled(code == nil)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Says what the button will actually do, which is not the same in the two states: with a
    /// reading taken it only closes, and without one it takes whatever is on screen first.
    private var useTitle: String {
        accepted != nil || picked != nil ? "Save" : "Use it anyway"
    }

    // MARK: Derived

    /// What the readout shows: the taken reading once there is one, the live one until then.
    private var shownHex: String {
        picked?.hex ?? accepted ?? scanner.reading?.color.hexString ?? ""
    }

    private var shownName: String? {
        if let picked { return picked.name }
        guard let accepted else { return scanner.readingName }
        return nameCache.name(forHex: accepted) ?? scanner.readingName
    }

    private func dotLevel(_ confidence: FilamentColorEstimate.Confidence) -> StatusLevel {
        switch confidence {
        case .high: return .ready
        case .fair: return .busy
        case .low: return .offline
        }
    }

    private var spokenReading: String {
        guard let reading = scanner.reading else { return "Waiting for the camera" }
        let name = shownName.map { "\($0), " } ?? ""
        guard accepted == nil else {
            return "Colour taken, \(name)hex \(shownHex). Save to close."
        }
        return "Measured colour, \(name)hex \(shownHex), "
            + "\(reading.confidence.title.lowercased()) confidence, still settling"
    }
}
