@preconcurrency import AVFoundation
import SwiftUI

/// The live camera image, with the target square drawn on it.
///
/// The reticle is drawn **inside** the preview layer's own coordinate space rather than as a
/// SwiftUI overlay, and that is the point of the whole file. The layer letterboxes the video inside
/// whatever rectangle the sheet gives it, so a SwiftUI square centred on the view is only in the
/// right place when the aspect ratios happen to agree — and when they do not, the box the user is
/// filling with filament is not the box being measured. Nothing about that failure is visible: the
/// reading is simply of somewhere else.
///
/// `layerRectConverted(fromMetadataOutputRect:)` is the layer's own answer to "where is the video",
/// so asking it for the full frame and centring inside the result gives a reticle that is correct
/// for every window size, every camera aspect ratio and every gravity, without this file having to
/// know the sensor's resolution.
struct CameraPreview: NSViewRepresentable {

    let session: AVCaptureSession
    /// Drawn in the accent when the reading has settled, so "hold still" has a visible end.
    var isSettled: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.isSettled = isSettled
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.isSettled = isSettled
    }

    final class PreviewView: NSView {

        let previewLayer = AVCaptureVideoPreviewLayer()
        private let dimLayer = CAShapeLayer()
        private let reticleLayer = CAShapeLayer()

        var isSettled = false {
            didSet {
                guard oldValue != isSettled else { return }
                applyReticleColour()
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor

            // `.resizeAspect`, not `.resizeAspectFill`: a fill crops the frame, and a user lining a
            // spool up against the edge of the picture would be aiming at something the sensor can
            // see and the estimator never receives.
            previewLayer.videoGravity = .resizeAspect
            layer?.addSublayer(previewLayer)

            // Everything outside the target, knocked back. Colour is never the only cue — the
            // reticle is a drawn box as well — but the dim is what makes "fill this with filament"
            // read instantly.
            dimLayer.fillRule = .evenOdd
            dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
            layer?.addSublayer(dimLayer)

            reticleLayer.fillColor = nil
            reticleLayer.lineWidth = 2
            layer?.addSublayer(reticleLayer)
            applyReticleColour()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Re-resolved on every appearance change, because `Theme.accent` is a dynamic `NSColor`
        /// and a `CGColor` snapshot of it would keep the light-mode value in dark mode.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyReticleColour()
        }

        private func applyReticleColour() {
            let colour = isSettled ? Theme.success : Theme.accent
            effectiveAppearance.performAsCurrentDrawingAppearance {
                reticleLayer.strokeColor = NSColor(colour).cgColor
            }
        }

        override func layout() {
            super.layout()
            // No implicit animation: these layers are repositioned on every resize, and a quarter
            // second of interpolation on each one makes the reticle swim behind the window edge.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            previewLayer.frame = bounds
            dimLayer.frame = bounds
            reticleLayer.frame = bounds

            let target = targetRect()
            guard !target.isEmpty else {
                dimLayer.path = nil
                reticleLayer.path = nil
                return
            }

            let mask = CGMutablePath()
            mask.addRect(bounds)
            mask.addRect(target)
            dimLayer.path = mask
            reticleLayer.path = reticlePath(in: target)
        }

        /// The target square, in this view's coordinates.
        ///
        /// Asking the layer where the *whole frame* lands is what makes this correct under
        /// letterboxing: the video rectangle is the only region the sensor covers, and the target
        /// is a square centred inside it.
        private func targetRect() -> CGRect {
            let video = previewLayer.layerRectConverted(
                fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            return ScanTarget.rect(in: video)
        }

        /// Corner ticks rather than a closed box: the filament being aimed at is the thing worth
        /// looking at, and a continuous outline sits directly on top of the pixels being measured.
        private func reticlePath(in rect: CGRect) -> CGPath {
            let path = CGMutablePath()
            let arm = (rect.width * 0.28).rounded()
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: rect.minX, y: rect.minY + arm), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + arm, y: rect.minY)),
                (CGPoint(x: rect.maxX - arm, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + arm)),
                (CGPoint(x: rect.maxX, y: rect.maxY - arm), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - arm, y: rect.maxY)),
                (CGPoint(x: rect.minX + arm, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - arm))
            ]
            for (start, corner, end) in corners {
                path.move(to: start)
                path.addLine(to: corner)
                path.addLine(to: end)
            }
            return path
        }
    }
}
