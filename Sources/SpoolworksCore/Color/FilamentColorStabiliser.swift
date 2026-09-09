import Foundation

/// Holds the last few frames of a live scan and reports the value that has actually settled.
///
/// A per-frame estimate is honest but twitchy. Auto-exposure hunts, the user's hand moves, and a
/// webcam's sensor noise survives patch averaging as a unit or two of drift — so a readout wired
/// straight to ``FilamentColorEstimator`` changes several times a second and there is no moment at
/// which it is obviously right to press the button. This is what turns that into "hold it there
/// until it settles, then take it".
///
/// The window is combined by **median**, not mean: a single frame ruined by a hand crossing the
/// light, or by the moment auto-exposure steps, moves a mean and does not move a median.
///
/// Steadiness is reported separately from the value. A value is always available — the scanner can
/// be used the instant it opens — but ``Reading/isSteady`` is what the UI leads with, because it is
/// the difference between a number that happens to be on screen and a measurement.
public struct FilamentColorStabiliser: Sendable {

    /// What the window currently says.
    public struct Reading: Equatable, Sendable {
        public let color: RGB8
        public let lab: LabColor
        /// Frames in the window.
        public let frameCount: Int
        /// The largest ΔE between any frame in the window and this value. This is the number
        /// steadiness is judged on.
        public let deviation: Double
        /// The **lowest** confidence seen in the window, not the average: one bad frame in the last
        /// half-second is a reason to hesitate, and quietly averaging it away would hide exactly
        /// the case the user needs to see.
        public let confidence: FilamentColorEstimate.Confidence
        /// Warnings present in more than half the window, so a warning that flickers on one frame
        /// does not flicker on screen.
        public let warnings: [FilamentColorEstimate.Warning]
        /// The window is full and the frames agree.
        public let isSteady: Bool
    }

    /// Frames kept. At the scanner's ~12 fps this is roughly the last second.
    public let capacity: Int
    /// The ΔE below which a full window counts as settled. 2.0 is around the point where a
    /// difference stops being visible on adjacent patches, so a window this tight is one the user
    /// could not see moving anyway.
    public let steadyThreshold: Double

    private var window: [FilamentColorEstimate] = []

    public init(capacity: Int = 12, steadyThreshold: Double = 2.0) {
        self.capacity = max(1, capacity)
        self.steadyThreshold = steadyThreshold
    }

    public var frameCount: Int { window.count }
    public var isEmpty: Bool { window.isEmpty }

    public mutating func add(_ estimate: FilamentColorEstimate) {
        window.append(estimate)
        if window.count > capacity { window.removeFirst(window.count - capacity) }
    }

    /// Drops everything. Called when the camera changes, or the sheet is reopened — a window that
    /// survived a device switch would report a value measured through the other lens.
    public mutating func reset() {
        window.removeAll(keepingCapacity: true)
    }

    public var reading: Reading? {
        guard !window.isEmpty else { return nil }

        let lab = LabColor(l: median(window.map(\.lab.l)),
                           a: median(window.map(\.lab.a)),
                           b: median(window.map(\.lab.b)))
        let deviation = window.map { $0.lab.deltaE(to: lab) }.max() ?? 0

        var counts: [FilamentColorEstimate.Warning: Int] = [:]
        for estimate in window {
            for warning in estimate.warnings { counts[warning, default: 0] += 1 }
        }
        let majority = window.count / 2
        let warnings = FilamentColorEstimate.Warning.allCases.filter { (counts[$0] ?? 0) > majority }

        return Reading(color: lab.rgb8,
                       lab: lab,
                       frameCount: window.count,
                       deviation: deviation,
                       confidence: window.map(\.confidence).min() ?? .low,
                       warnings: warnings,
                       isSteady: window.count >= capacity && deviation <= steadyThreshold)
    }

    /// The lower of the two middle values on an even count, rather than their mean. Keeps the
    /// result a value that was actually measured, which matters when the window straddles a step
    /// change: averaging across it would report a colour no frame ever saw.
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[(sorted.count - 1) / 2]
    }
}
