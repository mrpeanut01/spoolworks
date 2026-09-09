import CoreGraphics

/// Where the colour is measured, as one definition used by both sides.
///
/// The reticle the user aims with and the crop the estimator receives have to be the *same square*.
/// They are computed in different places — one from the preview layer's video rectangle, one from
/// the pixel buffer's dimensions — and when two copies of a geometry rule drift apart, nothing
/// visible breaks: the box is simply not where the measurement is, and every reading is of
/// somewhere slightly else. So the rule lives here once and both callers ask it.
enum ScanTarget {

    /// Side of the square, as a fraction of the shorter side of whatever it is placed in.
    ///
    /// Small on purpose, for three separate reasons that all pull the same way. The estimator's
    /// sampling grid has to stay finer than the strands themselves, so fewer strands in the box is
    /// better. The user is being asked to fill it with filament and nothing else, which is easier
    /// the smaller it is. And the camera's white balance is computed over the whole frame, so
    /// keeping the measured colour a small part of that frame is what stops the camera from
    /// neutralising the very colour being measured.
    static let fraction: CGFloat = 0.22

    /// The centred square inside `bounds`.
    ///
    /// Centred, which is also what makes mirroring a non-issue: the built-in camera's preview is
    /// mirrored, and a rect symmetric about the centre covers the same pixels either way round.
    ///
    /// Rounded to whole units, because the crop is taken in pixels and a half-pixel origin would
    /// have Core Image resample the whole patch for no reason.
    static func rect(in bounds: CGRect, fraction: CGFloat = fraction) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              fraction > 0 else { return .zero }
        let side = (min(bounds.width, bounds.height) * fraction).rounded()
        guard side >= 1 else { return .zero }
        return CGRect(x: (bounds.midX - side / 2).rounded(),
                      y: (bounds.midY - side / 2).rounded(),
                      width: side,
                      height: side)
    }

    /// The centred square in a frame of the given pixel size, with its origin at the top left.
    static func rect(inPixelSize size: CGSize, fraction: CGFloat = fraction) -> CGRect {
        rect(in: CGRect(origin: .zero, size: size), fraction: fraction)
    }
}
