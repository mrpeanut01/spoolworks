import Foundation

// Reading a spool's colour off a camera.
//
// ## Why this is not "average the pixels"
//
// Filament is a 1.75 mm cylinder wound in a flat spiral, so a close-up of a wrap is not a flat
// patch of colour. It is a corrugated surface, and it produces three things at once:
//
//   1. **A specular highlight along the top of every strand.** Glossy PLA reflects the light source
//      almost unchanged, so those pixels carry the colour of the *lamp*, not of the filament. They
//      are the brightest pixels in the frame, which is why "pick the brightest point" is the worst
//      possible rule and why a mean is dragged toward white.
//   2. **Deep shadow in the valley between strands.** Each strand occludes its neighbour, so much
//      of the visible area is the filament's own colour at a fraction of the illumination. A mean
//      is dragged dark by these, and a median usually lands squarely in them.
//   3. **Whatever shows through the gaps** — the spool's core, a label, the bench. One dark gap
//      across the target moves a mean a long way.
//
// A single pixel is one draw from that distribution plus sensor noise, so the scanner samples a
// grid across a small target and reasons about the distribution instead.
//
// ## The rule
//
// > **The filament's colour is the mean of the best-lit slice of the dominant colour in the target,
// > after clipped and specular samples are discarded.**
//
// Each clause earns its place:
//
//   - *dominant colour* — a mode seek finds the densest cluster, and everything outside it is
//     dropped. That is what removes the spool core showing through a gap: a contaminant has to
//     out-cover the filament before it can win.
//   - *best-lit slice* — within one material, shading only ever makes a sample **darker** than the
//     true diffuse colour, so the unshadowed samples are the honest ones and the bulk of the
//     distribution is not. A median deliberately reports a shadow.
//   - *after clipped and specular* — a highlight is brighter than the diffuse colour, so it would
//     otherwise win the previous clause outright.
//
// ## The metric: chromatic angle, not colour distance
//
// Membership of the dominant cluster is decided by the **angle between linear-RGB vectors**, and
// this is the one genuinely load-bearing choice in the file.
//
// Lambertian shading multiplies all three linear channels by the same scalar. The *direction* of
// the linear-RGB vector is therefore **exactly** invariant under shading, and the angle between two
// directions is exactly zero when two samples differ only in how much light reached them. Measured
// on real values: a lit red and its own deep shadow are 1.8° apart, while red and blue are 86°
// apart and a red with a strong specular wash is 23° away from its own diffuse colour.
//
// The obvious alternative — distance in CIELAB's a*/b* plane — does not have this property, and
// the numbers say so plainly: that same lit red and its shadow are **35 units** apart in a*/b*,
// which is further apart than many pairs of genuinely different colours. CIELAB chroma falls as
// lightness falls, so a shading-invariant cluster cannot be expressed as an a*/b* ball. Lab is
// still used here, but only for the L* axis and for the final averaging, where it is the right
// tool.
//
// Two consequences worth stating, because they are the limits of the method:
//
//   - The angle is **undefined for black and unstable near it**, since the direction of a very
//     short vector is mostly quantisation. That is not a flaw to engineer around; it is the reason
//     an underlit shot cannot be trusted, and it is reported as such rather than hidden.
//   - The angle cannot tell a dark neutral from a light neutral — a black spool core and grey
//     filament are 3.8° apart. Lightness has to do that work, which is why the cluster is bounded
//     above along L* as well.

/// A rectangular field of 8-bit sRGB pixels, row-major, top-left origin.
///
/// The scanner's input. Deliberately a plain value type with no image framework in sight: the UI
/// layer is responsible for getting camera frames *into* sRGB, and everything after that is
/// arithmetic this package can test without a camera.
public struct PixelField: Equatable, Sendable {
    public let pixels: [RGB8]
    public let width: Int
    public let height: Int

    /// Nil unless `pixels.count == width * height` and both dimensions are positive.
    public init?(pixels: [RGB8], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    public subscript(x: Int, y: Int) -> RGB8 { pixels[y * width + x] }
}

/// The direction of a colour in linear light — what shading leaves alone.
///
/// See the file comment: Lambertian shading scales the linear-RGB vector, so its direction is the
/// invariant and the angle between two directions is the shading-blind distance between two
/// colours.
public struct ChromaticDirection: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(_ linear: LinearRGB) {
        let r = max(0, linear.r), g = max(0, linear.g), b = max(0, linear.b)
        let length = (r * r + g * g + b * b).squareRoot()
        if length > 0 {
            x = r / length; y = g / length; z = b / length
        } else {
            // Degenerate. Neutral is the only non-arbitrary answer, and it keeps `angle` finite.
            let n = 1 / 3.0.squareRoot()
            x = n; y = n; z = n
        }
    }

    public init(_ rgb: RGB8) { self.init(rgb.linear) }

    /// Angle to another direction, in degrees. `0` for two samples of one material at different
    /// levels of illumination.
    public func angle(to other: ChromaticDirection) -> Double {
        acos(cosine(to: other)) * 180 / .pi
    }

    /// The cosine of that angle. The hot loops compare cosines against a precomputed threshold
    /// rather than taking `acos` on every pair: `cos` is monotonically decreasing on `0...180°`, so
    /// the comparison is exactly equivalent, and the mode seek is O(n²) in the sample count.
    public func cosine(to other: ChromaticDirection) -> Double {
        min(max(x * other.x + y * other.y + z * other.z, -1), 1)
    }
}

/// What the scanner concluded, and how much of it to believe.
public struct FilamentColorEstimate: Equatable, Sendable {

    /// The colour to write to the tag.
    public let color: RGB8
    /// The same value before quantisation. The stabiliser averages in Lab.
    public let lab: LabColor

    /// Every patch sampled from the target.
    public let sampleCount: Int
    /// Patches carrying a usable measurement — neither clipped bright nor crushed to black.
    public let usableCount: Int
    /// Usable patches that matched the dominant cluster: the filament itself.
    public let dominantCount: Int
    /// Dominant patches in the best-lit slice, which is what the answer is averaged from.
    public let litCount: Int

    /// Fraction of *all* samples with a channel at or above the clipping level.
    public let overexposedFraction: Double
    /// Fraction of *all* samples too dark for their hue to survive 8-bit quantisation.
    public let underexposedFraction: Double
    /// Mean chromatic angle, in degrees, between the dominant cluster and the answer. Large means a
    /// mottled or noisy target.
    public let chromaticSpread: Double

    /// How much of the usable target was one colour. Low means something else is in the box.
    public var dominance: Double {
        usableCount > 0 ? Double(dominantCount) / Double(usableCount) : 0
    }

    public enum Confidence: Int, Comparable, Sendable {
        case low, fair, high
        public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .low: return "Low"
            case .fair: return "Fair"
            case .high: return "Good"
            }
        }
    }

    /// Something about the shot the user can fix, phrased as the fix.
    public enum Warning: String, Sendable, CaseIterable {
        case tooDark, tooBright, mixedColours, mottled

        public var guidance: String {
            switch self {
            case .tooDark:
                return "Too dark — add light. Below this level the colour is mostly quantisation."
            case .tooBright:
                return "Highlights are clipping — angle the spool away from the lamp."
            case .mixedColours:
                return "More than one colour in the box — fill it with filament only."
            case .mottled:
                return "The target is mottled — move closer, or onto a flatter part of the wrap."
            }
        }
    }

    public var warnings: [Warning] {
        var found: [Warning] = []
        if underexposedFraction > 0.25 { found.append(.tooDark) }
        if overexposedFraction > 0.25 { found.append(.tooBright) }
        if dominance < 0.60 { found.append(.mixedColours) }
        if chromaticSpread > 6 { found.append(.mottled) }
        return found
    }

    public var confidence: Confidence {
        if dominance < 0.55 || chromaticSpread > 9
            || overexposedFraction > 0.5 || underexposedFraction > 0.5 { return .low }
        if dominance >= 0.70 && chromaticSpread <= 3
            && overexposedFraction <= 0.20 && underexposedFraction <= 0.20 { return .high }
        return .fair
    }
}

/// Turns a patch of camera pixels into the one colour to write on the tag.
///
/// Stateless and `Sendable`: one instance is shared by the capture queue and the tests. The file
/// comment carries the algorithm and the reasoning behind every constant below.
public struct FilamentColorEstimator: Sendable {

    public struct Options: Sendable {
        /// How far, in degrees of chromatic angle, a sample may sit from the dominant colour and
        /// still be part of it. 8° holds one material across its whole shading range (measured at
        /// 1.8°) with room for post-averaging sensor noise, while excluding a specular wash (23°)
        /// and anything genuinely a different colour (40°+).
        public var chromaticAngleTolerance: Double = 8
        /// Half-width of the mode-seek neighbourhood along L*. Generous, because one material under
        /// uneven light spans a wide range of lightness and must not be split into two clusters.
        public var lightnessBandwidth: Double = 22
        /// How far above the mode a sample may sit and still be filament rather than a reflection.
        ///
        /// Shading only ever makes a surface darker, so the dominant cluster is bounded above and
        /// unbounded below. This is the guard that works on *neutral* filament, where a highlight
        /// is the same colour as the surface and the angle test cannot see it.
        public var specularHeadroom: Double = 10
        /// A channel at or above this is a measurement floor rather than a measurement: the sensor
        /// ran out of headroom and the true value is unknown. 250 rather than 255 because most
        /// camera pipelines round a clipped value down a little.
        public var highClipLevel: UInt8 = 250
        /// All three channels at or below this and there is no colour left at all.
        public var blackClipLevel: UInt8 = 6
        /// A sample whose largest channel is at or below this is counted toward the too-dark
        /// warning. Not excluded — a black spool is a real spool — but at this level 8-bit
        /// quantisation dominates the chromatic angle, which is measured at 11° for a single pixel
        /// against 3° at mid-tone.
        public var lowSignalLevel: UInt8 = 30
        /// The slice of the dominant cluster averaged as "best lit".
        ///
        /// 0.30 is not arbitrary. For a cylinder lit by a distant source, the brightest 30% of the
        /// projected area is illuminated at 90% or more of peak, whatever angle the light comes
        /// from — the geometry works out that way because screen position maps to `sin φ` on the
        /// surface. A third is therefore about as much as can be averaged before shadow starts
        /// pulling the answer down.
        public var litFraction: Double = 0.30
        /// Never average fewer than this many patches, however small the lit slice works out.
        public var minimumLitCount = 4
        /// Below this share of usable samples, exposure filtering is abandoned and the raw samples
        /// are used instead. White filament legitimately clips and black filament legitimately
        /// crushes; refusing to read either is worse than reading it with a warning attached.
        public var minimumUsableFraction: Double = 0.25
        /// Mean-shift refinement passes after the discrete mode is picked.
        public var meanShiftPasses = 4
        /// Patches per side of the sampling grid over the target.
        ///
        /// This has to stay **finer than the strands themselves**. A cell wider than a strand
        /// averages its lit top together with the shadow beside it, and no patch anywhere in the
        /// grid is then a measurement of well-lit filament — the very thing the estimate is built
        /// from. With the reticle framing four or five strands and the crop rendered at 160 px, 20
        /// cells a side puts roughly four patches across each strand while still averaging 64
        /// pixels per patch.
        public var gridSize = 20

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// One patch, in the two forms the algorithm needs.
    private struct Sample {
        let lab: LabColor
        let direction: ChromaticDirection

        init(_ rgb: RGB8) {
            let linear = rgb.linear
            lab = LabColor(linear: linear)
            direction = ChromaticDirection(linear)
        }

        init(_ lab: LabColor) {
            self.lab = lab
            direction = ChromaticDirection(lab.linear)
        }
    }

    // MARK: - Sampling

    /// Reduces the target to a `gridSize × gridSize` grid of patch means.
    ///
    /// Two jobs in one step. Averaging each cell in **linear light** removes sensor noise, which at
    /// the ISO a webcam picks indoors is the difference between a stable readout and one that
    /// jitters several units a frame — a 64-pixel cell cuts the noise angle by eight. Reducing to a
    /// fixed grid also makes everything downstream independent of whatever resolution the camera
    /// delivers: the mode seek is O(n²), and n is 400 whether the crop was 60 px across or 600.
    ///
    /// Cells divide the field evenly; a remainder of fewer than `gridSize` pixels at the right or
    /// bottom edge is left out rather than unevenly weighted into the last row.
    public func samples(from field: PixelField) -> [RGB8] {
        let grid = max(1, options.gridSize)
        let cellWidth = field.width / grid
        let cellHeight = field.height / grid
        guard cellWidth > 0, cellHeight > 0 else {
            // Smaller than the grid: every pixel is its own sample.
            return field.pixels
        }

        var result: [RGB8] = []
        result.reserveCapacity(grid * grid)
        for row in 0..<grid {
            for column in 0..<grid {
                var sum = LinearRGB(r: 0, g: 0, b: 0)
                for y in (row * cellHeight)..<((row + 1) * cellHeight) {
                    for x in (column * cellWidth)..<((column + 1) * cellWidth) {
                        let linear = field[x, y].linear
                        sum.r += linear.r
                        sum.g += linear.g
                        sum.b += linear.b
                    }
                }
                let n = Double(cellWidth * cellHeight)
                result.append(RGB8(linear: LinearRGB(r: sum.r / n, g: sum.g / n, b: sum.b / n)))
            }
        }
        return result
    }

    /// Grid-samples the field and estimates in one step.
    public func estimate(from field: PixelField) -> FilamentColorEstimate? {
        estimate(from: samples(from: field))
    }

    // MARK: - The estimate

    /// Nil only when handed no samples at all. Anything else produces an answer *and* the
    /// diagnostics needed to decide whether to trust it — refusing to report a poor reading would
    /// leave the UI with nothing to explain.
    public func estimate(from samples: [RGB8]) -> FilamentColorEstimate? {
        guard !samples.isEmpty else { return nil }

        // 1 — exposure. A clipped channel is a floor, not a measurement, and a crushed one is
        //     nothing at all.
        var overexposed = 0
        var lowSignal = 0
        var usable: [RGB8] = []
        usable.reserveCapacity(samples.count)
        for sample in samples {
            let peak = max(sample.r, max(sample.g, sample.b))
            if peak <= options.lowSignalLevel { lowSignal += 1 }
            if peak >= options.highClipLevel {
                overexposed += 1
            } else if peak <= options.blackClipLevel {
                // Nothing to read at all; counted only through `lowSignal`.
            } else {
                usable.append(sample)
            }
        }
        let total = Double(samples.count)
        let overexposedFraction = Double(overexposed) / total
        let underexposedFraction = Double(lowSignal) / total

        // White filament clips on every channel; black filament crushes on every channel. Both are
        // real spools, and reading them with a warning attached beats refusing to read them.
        if Double(usable.count) < options.minimumUsableFraction * total {
            usable = samples
        }

        let cloud = usable.map(Sample.init)

        // 2 — the dominant colour: the densest point under an anisotropic neighbourhood, tight
        //     across chromatic angle and generous along L*.
        let mode = self.mode(of: cloud)

        // 3 — everything that shares the mode's colour. Unbounded *below* in lightness, because
        //     shadow is the same material; bounded above, because nothing on a diffuse surface is
        //     brighter than the surface.
        let ceiling = mode.lab.l + options.specularHeadroom
        let cosineTolerance = cos(options.chromaticAngleTolerance * .pi / 180)
        let family = cloud.filter {
            $0.lab.l <= ceiling && $0.direction.cosine(to: mode.direction) >= cosineTolerance
        }
        let dominant = family.isEmpty ? cloud : family

        // 4 — the best-lit slice of it, averaged. Shading only subtracts, so the brightest
        //     survivors are the ones closest to the filament's own colour.
        let ordered = dominant.sorted { $0.lab.l > $1.lab.l }
        let wanted = max(min(options.minimumLitCount, ordered.count),
                         Int((Double(ordered.count) * options.litFraction).rounded()))
        let lit = Array(ordered.prefix(max(1, wanted)))
        let estimate = LabColor.mean(of: lit.map(\.lab)) ?? mode.lab
        let estimateDirection = ChromaticDirection(estimate.linear)

        // 5 — diagnostics, measured against what the estimate claims.
        let chromaticSpread = dominant.isEmpty ? 0
            : dominant.reduce(0.0) { $0 + $1.direction.angle(to: estimateDirection) }
                / Double(dominant.count)

        return FilamentColorEstimate(color: estimate.rgb8,
                                     lab: estimate,
                                     sampleCount: samples.count,
                                     usableCount: usable.count,
                                     dominantCount: dominant.count,
                                     litCount: lit.count,
                                     overexposedFraction: overexposedFraction,
                                     underexposedFraction: underexposedFraction,
                                     chromaticSpread: chromaticSpread)
    }

    // MARK: - Mode seek

    /// The densest point in the sample cloud under the anisotropic neighbourhood.
    ///
    /// A discrete pass picks the sample with the most neighbours; a few mean-shift passes then move
    /// the centre off that sample and onto the cloud's actual peak.
    ///
    /// The discrete pass breaks ties on the **lowest index**, scanning front to back with a strict
    /// `>`. Ties are reachable — a two-colour target split exactly in half is the obvious case — and
    /// a nondeterministic winner would show up as a readout flipping between two colours while
    /// nothing in front of the camera moves. This is the tie-break discipline ``ColorMatcher`` uses
    /// and for the same reason: determinism is worth more than the arbitrary preference it costs.
    private func mode(of cloud: [Sample]) -> Sample {
        guard let first = cloud.first else { return Sample(LabColor(l: 0, a: 0, b: 0)) }
        guard cloud.count > 1 else { return first }

        let hL = max(options.lightnessBandwidth, .ulpOfOne)
        let hA = max(options.chromaticAngleTolerance, .ulpOfOne)
        // Anything this far apart in colour cannot be in the ellipsoid whatever its lightness, so
        // the cheap cosine test rejects most pairs before an `acos` is ever taken.
        let cosineTolerance = cos(hA * .pi / 180)

        /// `true` when `sample` is inside the ellipsoid around `centre`.
        func inRange(_ sample: Sample, of centre: Sample) -> Bool {
            let dl = (sample.lab.l - centre.lab.l) / hL
            let lightnessTerm = dl * dl
            if lightnessTerm > 1 { return false }
            let cosine = sample.direction.cosine(to: centre.direction)
            if cosine < cosineTolerance { return false }
            let da = (acos(cosine) * 180 / .pi) / hA
            return lightnessTerm + da * da <= 1
        }

        var best = first
        var bestCount = -1
        for candidate in cloud {
            var count = 0
            for sample in cloud where inRange(sample, of: candidate) { count += 1 }
            if count > bestCount {          // strict `>` ⇒ the earliest sample wins a tie
                bestCount = count
                best = candidate
            }
        }

        var centre = best
        for _ in 0..<options.meanShiftPasses {
            let neighbours = cloud.filter { inRange($0, of: centre) }
            guard let shifted = LabColor.mean(of: neighbours.map(\.lab)) else { break }
            let movement = shifted.deltaE(to: centre.lab)
            centre = Sample(shifted)
            if movement < 0.05 { break }
        }
        return centre
    }
}
