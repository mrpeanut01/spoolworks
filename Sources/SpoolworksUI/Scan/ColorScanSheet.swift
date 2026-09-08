import SwiftUI
import SpoolworksCore

/// Point the camera at the spool, hold still, take the colour.
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
        .frame(width: 640, height: 620)
        .background(Theme.background)
        .task {
            original = hex
            await scanner.start()
        }
        // The acceptance. Anything that has held still for a full window is as good as this
        // scanner gets, so it is taken without asking — see `accepted`.
        .onChange(of: scanner.reading?.isSteady == true) { _, steady in
            guard steady, accepted == nil, let reading = scanner.reading else { return }
            accepted = reading.color.hexString
            hex = reading.color.hexString
        }
        .task(id: accepted) {
            if let accepted { await nameCache.resolve([accepted]) }
        }
        .onDisappear { scanner.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step 2 · Colour").kicker()
            Text("Scan the filament")
                .font(.system(size: 20, weight: .heavy))
            Text("Hold the spool so the box is filled with filament and nothing else. "
                 + "Several points across the box are measured, so the shadow between strands and "
                 + "the shine along them are discarded rather than averaged in.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
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
                          isSettled: scanner.reading?.isSteady == true,
                          tick: scanner.frameTick)
                .frame(maxWidth: .infinity, minHeight: 300)
                .overlay(Rectangle().strokeBorder(Theme.rule, lineWidth: Theme.ruleWidth))
                .accessibilityLabel("Camera preview with a target square in the centre")

            readout
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
                        if accepted != nil {
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
            if accepted != nil {
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

            if scanner.state == .running {
                Button("Re-measure") {
                    accepted = nil
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
                dismiss()
            }
            .buttonStyle(.sw(.ghost))
            .keyboardShortcut(.cancelAction)

            Button(useTitle) {
                // Nothing to commit when a reading has already been taken — the binding wrote it
                // the moment it settled. This only closes.
                if accepted == nil, let reading = scanner.reading {
                    hex = reading.color.hexString
                }
                dismiss()
            }
            .buttonStyle(.sw(.primary))
            .disabled(scanner.reading == nil && accepted == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    /// Says what the button will actually do, which is not the same in the two states: with a
    /// reading taken it only closes, and without one it takes whatever is on screen first.
    private var useTitle: String {
        accepted != nil ? "Save" : "Use it anyway"
    }

    // MARK: Derived

    /// What the readout shows: the taken reading once there is one, the live one until then.
    private var shownHex: String {
        accepted ?? scanner.reading?.color.hexString ?? ""
    }

    private var shownName: String? {
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
