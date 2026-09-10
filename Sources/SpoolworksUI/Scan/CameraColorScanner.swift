// `@preconcurrency` because AVFoundation is not Sendable-audited: `AVCaptureSession` is documented
// as safe to drive from any thread — `startRunning` explicitly *should* be called off the main one,
// since it blocks — but the type carries no `Sendable` conformance to say so. Without this the file
// is a wall of warnings about a rule the framework predates.
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI
import SpoolworksCore

/// Drives the Mac's camera and turns what it sees into one filament colour.
///
/// The measurement itself is not here — that is ``FilamentColorEstimator`` in `SpoolworksCore`,
/// which has no camera in it and is tested against synthetic wraps with known colours. This class
/// is the plumbing on either side of it: get frames, get them into sRGB, crop to the reticle, and
/// publish a settled reading.
///
/// ## Getting the pixels into the right colour space
///
/// The tag stores raw sRGB code values and ``ColorMatcher`` compares them as integers, so a colour
/// measured in the wrong space is simply the wrong colour. Camera frames are **not** reliably sRGB:
/// a modern Mac camera may deliver Display P3 or BT.709, and the same physical spool would then
/// read as a different hex depending on which machine it was scanned on.
///
/// So the crop is not read out of the pixel buffer directly. It goes through Core Image, which
/// carries the buffer's attached colour space, and is rendered into an explicitly sRGB bitmap. That
/// is a real conversion, not a reinterpretation, and it is why the crop is deliberately tiny — 160
/// px square is a rounding error of work per frame, and it makes the whole pipeline colour-managed
/// for free.
///
/// ## What this cannot fix
///
/// **The camera's own white balance is the largest remaining source of error, and nothing here
/// corrects for it.** A spool photographed under a warm lamp reads warm, because as far as the
/// sensor is concerned it *is* warm. Auto white balance makes it stranger rather than better: point
/// a camera at a large field of one colour and it will try to neutralise exactly the colour being
/// measured. Keeping the reticle small relative to the frame is a partial defence — the camera
/// balances on the whole scene, most of which is not filament — and the honest rest of the answer
/// is that this reads a colour close enough to pick a swatch, and is not a colorimeter. The UI says
/// so, and the value it produces is offered for confirmation rather than applied silently.
@MainActor
final class CameraColorScanner: NSObject, ObservableObject {

    /// Everything the scanner can be doing, so none of it is an accident.
    enum State: Equatable {
        case idle
        /// Running from a bare binary with no `Info.plist`. See ``usageDescriptionIsPresent``.
        case notInAnAppBundle
        case requestingAccess
        case denied
        case noCamera
        case failed(String)
        case running
    }

    @Published private(set) var state: State = .idle
    /// The settled colour, or nil until the first frame lands.
    @Published private(set) var reading: FilamentColorStabiliser.Reading?
    /// The nearest name from the 31,861-row table, for the colour currently being reported.
    @Published private(set) var readingName: String?
    /// Increments on every measured frame.
    ///
    /// Its only job is to be a value that changes, so `CameraPreview` gets an `updateNSView` while
    /// the capture pipeline is coming up. See the note there on why the reticle cannot be placed
    /// until the first frame has flowed.
    @Published private(set) var frameTick = 0
    @Published private(set) var cameras: [Camera] = []
    @Published var selectedCameraID: String? {
        didSet {
            guard oldValue != selectedCameraID, state == .running else { return }
            restart()
        }
    }

    /// A camera, reduced to what the picker needs. `AVCaptureDevice` is not `Sendable` and is a
    /// poor thing to hold in view state.
    struct Camera: Identifiable, Equatable {
        let id: String
        let name: String
        /// Continuity Camera and external cameras focus close; the built-in one usually does not.
        let focusesClose: Bool
    }

    let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.obsidiang.spoolworks.colour-scan",
                                      qos: .userInitiated)
    private var processor: FrameProcessor?
    private var input: AVCaptureDeviceInput?

    // MARK: - Availability

    /// Whether this process may touch the camera at all.
    ///
    /// AVFoundation does not return an error when `NSCameraUsageDescription` is missing — it
    /// **terminates the process**. A binary built by `swift build` and launched with `swift run` has
    /// no `Info.plist` at all, which is exactly how this app is run during development, so the
    /// scanner has to check before it touches a capture API rather than after. `Tools/make-app.sh`
    /// writes the key into the bundle it assembles and verifies it is there.
    static var usageDescriptionIsPresent: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    // MARK: - Lifecycle

    /// Asks for access if needed and starts the session. Safe to call more than once.
    func start() async {
        guard state != .running else { return }
        guard Self.usageDescriptionIsPresent else {
            state = .notInAnAppBundle
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            state = .requestingAccess
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            // The sheet can close while the system prompt is up; `stop()` then resets the
            // state, and a start that carried on regardless would bring the camera up for a
            // view that is gone.
            guard state == .requestingAccess else { return }
            guard granted else {
                state = .denied
                return
            }
        case .denied, .restricted:
            state = .denied
            return
        @unknown default:
            state = .denied
            return
        }

        refreshCameras()
        guard let device = chosenDevice() else {
            state = .noCamera
            return
        }
        configure(with: device)
    }

    func stop() {
        // Off the main thread: `stopRunning` blocks until the capture pipeline has torn down, and
        // on the main thread that is a visible hitch as the sheet closes.
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
        processor?.reset()
        state = .idle
        reading = nil
        readingName = nil
        frameTick = 0
    }

    /// Throws the settled window away — used when the user has moved the camera to a new spot and
    /// the last second of frames is about the old one.
    func resetReading() {
        processor?.reset()
        reading = nil
        readingName = nil
    }

    private func restart() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
        resetReading()
        state = .idle
        Task { await start() }
    }

    // MARK: - Devices

    private func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        cameras = discovery.devices.map {
            Camera(id: $0.uniqueID,
                   name: $0.localizedName,
                   // The built-in camera is fixed-focus at conversation distance, so a spool held
                   // up to it is soft and the colour reads flat. An iPhone over Continuity Camera
                   // focuses at a few centimetres and is much the better instrument here — worth
                   // saying in the UI rather than leaving the user to wonder why it looks bad.
                   focusesClose: $0.deviceType != .builtInWideAngleCamera)
        }
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            // Prefer a camera that can actually focus on something held close to it.
            selectedCameraID = (cameras.first { $0.focusesClose } ?? cameras.first)?.id
        }
    }

    private func chosenDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        if let id = selectedCameraID, let match = discovery.devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        return discovery.devices.first
    }

    // MARK: - Session

    private func configure(with device: AVCaptureDevice) {
        session.beginConfiguration()

        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }

        // 720p rather than the highest the camera offers: the reticle is 22% of the shorter side,
        // which is still about 160 px of real sensor data, and everything above that is pixels
        // thrown away a millisecond later.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                state = .failed("This Mac refused to open \(device.localizedName).")
                return
            }
            session.addInput(input)
            self.input = input
        } catch {
            session.commitConfiguration()
            state = .failed(error.localizedDescription)
            return
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // A dropped frame costs nothing here — the next one is 80 ms away and says the same thing.
        // Queueing them instead would let the estimator fall behind the preview, which is the one
        // failure the user would actually notice.
        output.alwaysDiscardsLateVideoFrames = true

        let processor = FrameProcessor { [weak self] reading in
            Task { @MainActor [weak self] in self?.publish(reading) }
        }
        self.processor = processor
        output.setSampleBufferDelegate(processor, queue: queue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            state = .failed("This Mac refused to read frames from \(device.localizedName).")
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        configureFocus(on: device)

        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
        state = .running
    }

    /// Continuous autofocus, where the device has any focus control at all.
    ///
    /// Best-effort and non-fatal, in the same spirit as the reader's optional escapes (D-004): a
    /// camera that cannot focus still produces a usable colour, it is just a softer picture.
    private func configureFocus(on device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        do {
            try device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch {
            // Another process holds the device's configuration lock. Not worth surfacing.
        }
    }

    // MARK: - Publishing

    private var nameTask: Task<Void, Never>?

    private func publish(_ reading: FilamentColorStabiliser.Reading) {
        let previous = self.reading?.color
        self.reading = reading
        frameTick &+= 1
        guard reading.color != previous else { return }

        // The name lookup is a 31,861-row linear scan. It is 0.04 ms in a release build but ~14 ms
        // in a debug one, and at twelve frames a second that is a visible stutter on the main
        // thread — so it is never done there. See `ColorMatcher`'s own note.
        nameTask?.cancel()
        let hex = reading.color.hexString
        nameTask = Task { [weak self] in
            let name = await Task.detached(priority: .utility) { () -> String? in
                guard let matcher = try? ColorMatcher.shared() else { return nil }
                return try? matcher.nearestName(forHex: hex)
            }.value
            guard !Task.isCancelled else { return }
            // Still the current reading? A slow lookup that lands after the colour has moved on
            // would put the wrong name under the right swatch.
            guard self?.reading?.color.hexString == hex else { return }
            self?.readingName = name
        }
    }
}

// MARK: - The capture-queue side

/// Receives frames on the capture queue, measures them, and hands out settled readings.
///
/// Separate from ``CameraColorScanner`` so that everything touching a sample buffer lives on one
/// serial queue and nothing has to reach back onto the main actor to do its work. The only thing
/// that crosses is the finished reading.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Side of the square the crop is rendered into.
    ///
    /// Fixed, so the estimator's grid is the same size whatever resolution the camera delivers, and
    /// small, because everything downstream is per-pixel work repeated twelve times a second.
    private static let cropSide = 160

    private let onReading: (FilamentColorStabiliser.Reading) -> Void

    private let estimator = FilamentColorEstimator()
    private var stabiliser = FilamentColorStabiliser()
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              .useSoftwareRenderer: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Frames are read at ~12 per second rather than at whatever the camera offers.
    ///
    /// Not for CPU — a frame costs about 1.4 ms in a release build. It is so the stabiliser's window
    /// covers a useful span of *time*: twelve frames of a 60 fps camera is a fifth of a second, over
    /// which a shaky hand has barely moved and "these frames agree" means almost nothing.
    private static let minimumInterval: CFTimeInterval = 1.0 / 12
    private var lastFrame: CFTimeInterval = 0

    private let lock = NSLock()
    private var resetRequested = false

    init(onReading: @escaping (FilamentColorStabiliser.Reading) -> Void) {
        self.onReading = onReading
    }

    /// Asks for the window to be cleared. Applied on the capture queue, so the stabiliser is only
    /// ever touched from there.
    func reset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= Self.minimumInterval else { return }
        lastFrame = now

        lock.lock()
        if resetRequested {
            stabiliser.reset()
            resetRequested = false
        }
        lock.unlock()

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let field = crop(buffer),
              let estimate = estimator.estimate(from: field),
              let reading = { stabiliser.add(estimate); return stabiliser.reading }() else { return }
        onReading(reading)
    }

    /// The target square, colour-managed into sRGB and scaled to a fixed size.
    ///
    /// The square itself comes from ``ScanTarget``, which is also what the preview draws — the two
    /// must not be able to disagree.
    private func crop(_ buffer: CVPixelBuffer) -> PixelField? {
        let size = CGSize(width: CVPixelBufferGetWidth(buffer),
                          height: CVPixelBufferGetHeight(buffer))
        // Core Image's origin is bottom-left and `ScanTarget` reasons top-left, which does not
        // matter here for the one reason that also makes mirroring not matter: the rect is centred,
        // so it is the same rectangle measured from either edge.
        let target = ScanTarget.rect(inPixelSize: size)
        guard target.width >= 8 else { return nil }

        let origin = target.origin
        let image = CIImage(cvPixelBuffer: buffer).cropped(to: target)
        let scale = CGFloat(Self.cropSide) / target.width
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let count = Self.cropSide * Self.cropSide
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let bounds = CGRect(x: 0, y: 0, width: Self.cropSide, height: Self.cropSide)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            // `colorSpace: sRGB` is the whole point: whatever the camera delivered — P3, BT.709,
            // anything — comes out of here as the sRGB code values the tag format is defined in.
            context.render(scaled,
                           toBitmap: base,
                           rowBytes: Self.cropSide * 4,
                           bounds: bounds,
                           format: .RGBA8,
                           colorSpace: sRGB)
        }

        var pixels: [RGB8] = []
        pixels.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * 4
            pixels.append(RGB8(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2]))
        }
        return PixelField(pixels: pixels, width: Self.cropSide, height: Self.cropSide)
    }
}
