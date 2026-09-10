import Foundation
import CoreGraphics
import AppKit
import SwiftUI
@testable import SpoolworksCore
@testable import SpoolworksUI

// Camera colour-scan tests.
//
// The interesting claim this file has to support is not "the estimator returns a colour" — anything
// returns a colour. It is **"the estimator recovers the filament's actual colour from a picture in
// which most pixels are the wrong colour"**, which is what a photograph of a 1.75 mm wrap always
// is. So the tests render one.
//
// `StrandRenderer` below is a small physically-arranged image of a filament wrap: Lambertian
// cylinders with real inter-strand shadow, an optional specular lobe that clips, an optional
// contaminant (the spool core showing through a gap), and seeded sensor noise. The albedo it is
// given is the ground truth, and the tests assert distance from it — for the estimator, and for the
// plain mean and plain median of the very same pixels, so the improvement is measured rather than
// claimed.
//
// Everything is seeded, so these are exact numbers, not statistical hopes.

// MARK: - A synthetic filament wrap

/// Renders a patch of wound filament under a single distant light.
///
/// Normalised so that the **brightest diffuse point renders exactly at the albedo**
/// (`ambient + key == 1`). That is what makes the ground truth well defined: the scanner's job is
/// to report the colour of fully-lit filament, and here that colour is a known constant rather than
/// an artefact of the exposure chosen.
private struct StrandRenderer {

    /// The filament's true colour — what a perfect scanner would return.
    var albedo: RGB8
    /// Matches the crop the scanner actually renders.
    var size = 140
    /// Pixels per strand. The reticle is sized to frame four or five strands, so five across the
    /// crop. This has to stay well above the estimator's cell size or the test would be measuring
    /// a blur rather than a wrap — which is exactly the mistake that showed up the first time these
    /// numbers were run.
    var strandPeriod = 28
    /// Fill light. Everything not facing the key is at least this bright.
    var ambient = 0.15
    /// Key light. `ambient + key == 1` by construction.
    var key = 0.85
    /// Height of the light above the camera axis, as `sin φ`.
    var lightHeight = 0.35
    /// Phong lobe strength, in linear light. `0.9` clips on a mid-tone; `0` is matte filament.
    var specularStrength = 0.0
    var specularExponent = 40.0
    /// Overall gain on the rendered radiance. Above 1 is an overexposed shot; the clipping that
    /// follows is the real thing, not a flag set by hand.
    var exposure = 1.0
    /// Sensor noise amplitude, in 8-bit code values.
    var noise = 0.0
    /// Something that is not filament, occupying the first `contaminantRows` rows — the spool's
    /// core showing through a gap in the wrap.
    var contaminant: RGB8?
    var contaminantRows = 0
    var seed: UInt64 = 0x5EED_1EAF

    func render() -> PixelField {
        var rng = SplitMix64(seed: seed)
        let lightY = lightHeight
        let lightZ = (1 - lightY * lightY).squareRoot()

        var pixels: [RGB8] = []
        pixels.reserveCapacity(size * size)

        for y in 0..<size {
            // Screen y maps linearly to the cylinder's own y: an orthographic view of a cylinder
            // is exactly that projection, which is why the shading profile below is sampled
            // uniformly in `t` and not uniformly in angle.
            let t = (Double(y % strandPeriod) / Double(strandPeriod)) * 2 - 1
            let normalY = t
            let normalZ = (max(0, 1 - t * t)).squareRoot()

            let nDotL = max(0, normalY * lightY + normalZ * lightZ)
            let shade = ambient + key * nDotL

            // Phong: reflect the light about the normal and measure against the view axis (0,0,1).
            let reflectY = 2 * nDotL * normalY - lightY
            let reflectZ = 2 * nDotL * normalZ - lightZ
            _ = reflectY
            let specular = specularStrength * pow(max(0, reflectZ), specularExponent)

            let base = (contaminant != nil && y < contaminantRows) ? contaminant! : albedo
            let linear = base.linear

            for _ in 0..<size {
                var lit = LinearRGB(r: (linear.r * shade + specular) * exposure,
                                    g: (linear.g * shade + specular) * exposure,
                                    b: (linear.b * shade + specular) * exposure)
                if noise > 0 {
                    // Applied after encoding, where sensor noise actually lives. Triangular, from
                    // two uniforms — enough shape to be a fair test without dragging in a
                    // Gaussian.
                    let encoded = RGB8(linear: lit)
                    func jitter(_ value: UInt8) -> UInt8 {
                        let delta = (rng.unit() + rng.unit() - 1) * noise
                        return UInt8(min(max((Double(value) + delta).rounded(), 0), 255))
                    }
                    pixels.append(RGB8(r: jitter(encoded.r), g: jitter(encoded.g), b: jitter(encoded.b)))
                    continue
                }
                lit.r = min(lit.r, 1); lit.g = min(lit.g, 1); lit.b = min(lit.b, 1)
                pixels.append(RGB8(linear: lit))
            }
        }
        return PixelField(pixels: pixels, width: size, height: size)!
    }
}

/// Deterministic across platforms and runs — the tests assert exact distances.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
}

// MARK: - Baselines the estimator has to beat

private func plainMean(_ field: PixelField) -> RGB8 {
    RGB8.mean(ofLinear: field.pixels)!
}

private func plainMedian(_ field: PixelField) -> RGB8 {
    func median(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
    return RGB8(r: median(field.pixels.map(\.r)),
                g: median(field.pixels.map(\.g)),
                b: median(field.pixels.map(\.b)))
}

private func distance(_ a: RGB8, _ b: RGB8) -> Double {
    LabColor(a).deltaE(to: LabColor(b))
}

// MARK: - Colour space

let labColorTests = TestSuite(name: "Lab colour space", cases: [

    test("sRGB round-trips through Lab exactly for every primary and neutral") { t in
        let colors: [RGB8] = [
            RGB8(r: 0, g: 0, b: 0), RGB8(r: 255, g: 255, b: 255),
            RGB8(r: 255, g: 0, b: 0), RGB8(r: 0, g: 255, b: 0), RGB8(r: 0, g: 0, b: 255),
            RGB8(r: 128, g: 128, b: 128), RGB8(r: 193, g: 46, b: 31),
            RGB8(r: 60, g: 60, b: 61), RGB8(r: 222, g: 228, b: 225), RGB8(r: 1, g: 2, b: 3)
        ]
        for color in colors {
            t.equal(LabColor(color).rgb8, color, "round trip of \(color.hexString)")
        }
    },

    test("black and white land on the ends of the L* axis") { t in
        t.equal(LabColor(RGB8(r: 0, g: 0, b: 0)).l, 0, "black L*")
        t.expect(LabColor(RGB8(r: 128, g: 128, b: 128)).chroma < 0.01, "grey has no chroma")

        // White is 100.0000039, not 100, and that is *correct*: the published seven-digit
        // sRGB → XYZ matrix has rows summing to 1.0000001, so a full-scale white maps to Y just
        // over the white point. Every implementation using the standard coefficients has this.
        // Asserted at 1e-4 rather than papered over with a wider tolerance, because a real error
        // in the matrix would be orders of magnitude larger than this and must still fail.
        let white = LabColor(RGB8(r: 255, g: 255, b: 255)).l
        t.expect(abs(white - 100) < 1e-4, "white L* is 100 to within the matrix's own rounding (got \(white))")
        t.expect(white > 100, "and errs high, as the matrix's row sums predict")
    },

    test("averaging in linear light is brighter than averaging the encoded codes") { t in
        // The whole reason `RGB8.mean(ofLinear:)` exists. Mid-grey between black and white is 188,
        // not 128: encoded 128 is only 21.6% of the light. A patch mean taken in encoded space
        // biases every reading dark, worst exactly where a filament image has the most contrast.
        let black = RGB8(r: 0, g: 0, b: 0)
        let white = RGB8(r: 255, g: 255, b: 255)
        let linearMean = RGB8.mean(ofLinear: [black, white])!
        t.equal(linearMean, RGB8(r: 188, g: 188, b: 188), "linear-light mean of black and white")
        t.expect(linearMean.r > 180, "linear mean is far brighter than the encoded mean of 128")
    },

    test("chromatic angle survives shading where Lab chroma does not") { t in
        // The measurement the estimator's whole metric rests on, kept as a test because it is
        // counter-intuitive and because an earlier draft got it backwards. A lit red and its own
        // deep shadow are the *same material*: the chromatic angle says so, and CIELAB's a*/b*
        // plane emphatically does not — it puts them 35 units apart, further than many pairs of
        // genuinely different colours.
        let lit = RGB8(r: 200, g: 40, b: 40)
        let shadowed = RGB8(r: 90, g: 18, b: 18)

        let angle = ChromaticDirection(lit).angle(to: ChromaticDirection(shadowed))
        t.expect(angle < 2.5, "one material across shading is under 2.5° (got \(angle))")

        let chromaDistance = LabColor(lit).chromaDistance(to: LabColor(shadowed))
        t.expect(chromaDistance > 30,
                 "while Lab a*/b* separates them by over 30 (got \(chromaDistance))")

        // And the angle still separates things that really are different.
        let blue = ChromaticDirection(RGB8(r: 40, g: 40, b: 200))
        let washed = ChromaticDirection(RGB8(r: 240, g: 150, b: 150))   // red under a specular wash
        t.expect(ChromaticDirection(lit).angle(to: blue) > 60, "red and blue stay far apart")
        t.expect(ChromaticDirection(lit).angle(to: washed) > 15,
                 "and a specular wash is outside the tolerance")
    },

    test("a scaled colour is exactly one direction, whatever the scale") { t in
        // Lambertian shading multiplies linear light by a scalar. Two renderings of one albedo at
        // different illumination must therefore be the same direction to within quantisation.
        let albedo = RGB8(r: 193, g: 46, b: 31).linear
        let reference = ChromaticDirection(albedo)
        for scale in [0.9, 0.6, 0.35, 0.12] {
            let dimmed = RGB8(linear: LinearRGB(r: albedo.r * scale,
                                                g: albedo.g * scale,
                                                b: albedo.b * scale))
            let angle = ChromaticDirection(dimmed).angle(to: reference)
            t.expect(angle < 1.0, "at \(scale)× illumination the angle is \(angle)°")
        }
    },
])

// MARK: - Sampling

let pixelFieldTests = TestSuite(name: "Pixel field and grid sampling", cases: [

    test("a field rejects dimensions that do not match its pixel count") { t in
        t.expect(PixelField(pixels: [RGB8(r: 1, g: 1, b: 1)], width: 2, height: 1) == nil,
                 "short buffer rejected")
        t.expect(PixelField(pixels: [], width: 0, height: 0) == nil, "empty field rejected")
        t.expect(PixelField(pixels: [RGB8(r: 1, g: 1, b: 1)], width: 1, height: 1) != nil,
                 "1×1 accepted")
    },

    test("grid sampling reduces any resolution to the same sample count") { t in
        let estimator = FilamentColorEstimator()
        for size in [48, 96, 240] {
            let field = StrandRenderer(albedo: RGB8(r: 193, g: 46, b: 31), size: size).render()
            t.equal(estimator.samples(from: field).count, 400, "\(size)px field → 20×20 grid")
        }
    },

    test("a field smaller than the grid is used pixel for pixel rather than dropped") { t in
        let estimator = FilamentColorEstimator()
        let field = PixelField(pixels: Array(repeating: RGB8(r: 10, g: 20, b: 30), count: 9),
                               width: 3, height: 3)!
        t.equal(estimator.samples(from: field).count, 9, "3×3 field kept whole")
    },

    test("patch means are taken in linear light") { t in
        // A checkerboard of black and white in one cell must average to 188, not 128.
        var pixels: [RGB8] = []
        for y in 0..<12 {
            for x in 0..<12 {
                pixels.append((x + y).isMultiple(of: 2) ? RGB8(r: 0, g: 0, b: 0)
                                                        : RGB8(r: 255, g: 255, b: 255))
            }
        }
        let field = PixelField(pixels: pixels, width: 12, height: 12)!
        var options = FilamentColorEstimator.Options()
        options.gridSize = 1
        let samples = FilamentColorEstimator(options: options).samples(from: field)
        t.equal(samples.count, 1, "one patch")
        t.equal(samples.first, RGB8(r: 188, g: 188, b: 188), "patch mean")
    },
])

// MARK: - The estimator

let filamentColorEstimatorTests = TestSuite(name: "Filament colour estimator", cases: [

    test("a flat patch is returned unchanged") { t in
        let estimator = FilamentColorEstimator()
        let flat = RGB8(r: 0x0A, g: 0x87, b: 0xBE)
        let field = PixelField(pixels: Array(repeating: flat, count: 140 * 140),
                               width: 140, height: 140)!
        let estimate = t.unwrap(estimator.estimate(from: field), "estimate")
        t.equal(estimate?.color, flat, "flat patch")
        t.equal(estimate?.confidence, .high, "confidence on a perfect target")
        t.equal(estimate?.warnings.isEmpty, true, "no warnings")
    },

    test("shading is rejected: a shadowed wrap still reads as the lit filament") { t in
        // No specular, no contaminant, no noise — just the inter-strand shadow that is unavoidable
        // on any wound spool. This is the core claim.
        let albedo = RGB8(r: 193, g: 46, b: 31)
        let field = StrandRenderer(albedo: albedo).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }

        let error = distance(estimate.color, albedo)
        let meanError = distance(plainMean(field), albedo)
        let medianError = distance(plainMedian(field), albedo)

        // Measured: estimator 1.25, mean 7.57, median 4.09.
        t.expect(error < 2.0, "estimator within ΔE 2 of the true colour (got \(error))")
        t.expect(meanError > 6, "a plain mean lands in the shadow (got \(meanError))")
        t.expect(medianError > 3, "and so does a plain median (got \(medianError))")
        t.expect(error < meanError / 4, "estimator beats the mean by 4× or better")
    },

    test("a clipping specular highlight does not drag the reading toward the lamp") { t in
        let albedo = RGB8(r: 0, g: 135, b: 190)
        let field = StrandRenderer(albedo: albedo, specularStrength: 0.9).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }

        let error = distance(estimate.color, albedo)
        let meanError = distance(plainMean(field), albedo)
        // Measured: estimator 2.87, mean 11.76.
        t.expect(error < 3.5, "estimator within ΔE 3.5 despite blown highlights (got \(error))")
        t.expect(error < meanError / 3, "and three times closer than a plain mean (\(meanError))")

        // Deliberately *no* exposure warning. The highlight is a narrow line on each strand, so it
        // survives patch averaging as a bright patch rather than a clipped one — and the estimator
        // rejected it anyway. A warning here would be telling the user to fix something that was
        // not a problem. The white-filament case below is what a genuinely overexposed shot looks
        // like, and that one does warn.
        t.expect(!estimate.warnings.contains(.tooBright),
                 "a highlight the estimator handles is not reported as a problem")
    },

    test("the spool core showing through a gap is excluded, not averaged in") { t in
        // A quarter of the target is dark grey plastic. A mean cannot survive this; the mode seek
        // is the thing that does.
        let albedo = RGB8(r: 242, g: 195, b: 0)
        let field = StrandRenderer(albedo: albedo,
                                   contaminant: RGB8(r: 40, g: 40, b: 44),
                                   contaminantRows: 35).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }

        let error = distance(estimate.color, albedo)
        let meanError = distance(plainMean(field), albedo)
        // Measured: estimator 1.38, mean 21.10, median 9.73.
        t.expect(error < 2.0, "estimator within ΔE 2 with 25% contamination (got \(error))")
        t.expect(meanError > 16, "a plain mean is wrecked by it (got \(meanError))")
        t.expect(error < meanError / 8, "eight times closer, because the core is excluded not diluted")
        t.expect(estimate.dominance < 0.9, "and the contamination is visible in the diagnostics")
    },

    test("everything at once: shadow, highlight, contamination and sensor noise") { t in
        let albedo = RGB8(r: 193, g: 46, b: 31)
        let field = StrandRenderer(albedo: albedo,
                                   specularStrength: 0.8,
                                   noise: 4,
                                   contaminant: RGB8(r: 35, g: 33, b: 38),
                                   contaminantRows: 26).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }

        let error = distance(estimate.color, albedo)
        let meanError = distance(plainMean(field), albedo)
        let medianError = distance(plainMedian(field), albedo)
        // Measured: estimator 3.66, mean 35.88, median 7.03. ΔE 3.7 is around the point where two
        // patches side by side start to look different, so this is a usable reading off a shot
        // that has everything wrong with it at once.
        t.expect(error < 4.5, "estimator within ΔE 4.5 of the truth (got \(error))")
        t.expect(error < meanError / 6, "well ahead of the mean (\(meanError))")
        t.expect(error < medianError / 1.6, "and ahead of the median (\(medianError))")
    },

    test("white filament clips on every channel and is still read, with a warning") { t in
        // The case that makes exposure filtering conditional. Almost every sample is clipped, so
        // discarding them all would leave nothing; the fallback keeps them and says why.
        let field = StrandRenderer(albedo: RGB8(r: 250, g: 252, b: 250),
                                   ambient: 0.55, key: 0.45, exposure: 1.6).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }
        t.expect(estimate.color.r > 200 && estimate.color.g > 200 && estimate.color.b > 200,
                 "reads as white, not as the mid-grey a mean would give (\(estimate.color.hexString))")
        t.expect(estimate.overexposedFraction > 0.25, "clipping reported")
        t.expect(estimate.warnings.contains(.tooBright), "and surfaced as advice")
    },

    test("black filament is read as black rather than crushed away") { t in
        let albedo = RGB8(r: 60, g: 60, b: 61)
        let field = StrandRenderer(albedo: albedo).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }
        // Measured: 0.81. Black is the case the chromatic angle is *weakest* on — the direction of
        // a short vector is mostly quantisation — so it is worth pinning that it still works when
        // there is enough light. The underexposed case below is where it stops working, and says so.
        t.expect(distance(estimate.color, albedo) < 1.5,
                 "within ΔE 1.5 (got \(distance(estimate.color, albedo)))")
    },

    test("patch averaging absorbs sensor noise entirely") { t in
        // The reason the grid averages rather than point-samples. Four code values of noise on
        // every pixel, and 49 pixels per patch, leaves an answer identical to the noiseless render
        // — while it still moves a plain median.
        let albedo = RGB8(r: 193, g: 46, b: 31)
        let estimator = FilamentColorEstimator()
        let clean = StrandRenderer(albedo: albedo).render()
        let noisy = StrandRenderer(albedo: albedo, noise: 4).render()
        guard let a = t.unwrap(estimator.estimate(from: clean), "clean"),
              let b = t.unwrap(estimator.estimate(from: noisy), "noisy") else { return }
        t.expect(a.lab.deltaE(to: b.lab) < 0.5,
                 "noise moves the estimate by under ΔE 0.5 (got \(a.lab.deltaE(to: b.lab)))")
        t.expect(distance(plainMedian(clean), albedo) != distance(plainMedian(noisy), albedo),
                 "while it does move a plain median")
    },

    test("an underlit target is reported as too dark instead of silently drifting") { t in
        let field = StrandRenderer(albedo: RGB8(r: 193, g: 46, b: 31),
                                   ambient: 0.004, key: 0.016).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        t.expect(estimate?.warnings.contains(.tooDark) == true, "too-dark warning raised")
        t.equal(estimate?.confidence, .low, "and confidence drops")
    },

    test("two colours in the box lowers dominance and warns") { t in
        // Half filament, half something else: the estimator still answers, but says the target is
        // not one colour, which is the only honest thing to report.
        let albedo = RGB8(r: 193, g: 46, b: 31)
        let field = StrandRenderer(albedo: albedo,
                                   contaminant: RGB8(r: 30, g: 90, b: 200),
                                   contaminantRows: 70).render()
        let estimate = t.unwrap(FilamentColorEstimator().estimate(from: field), "estimate")
        guard let estimate else { return }
        t.expect(estimate.dominance < 0.75, "dominance drops (got \(estimate.dominance))")
        t.expect(estimate.warnings.contains(.mixedColours), "mixed-colour warning raised")
    },

    test("an exact tie resolves the same way every time") { t in
        // Two equal populations, exactly one bandwidth apart in chroma. The tie-break is the
        // earliest sample, front to back — the same rule ColorMatcher uses, and for the same
        // reason: a nondeterministic winner would flip the readout with nothing moving.
        let first = RGB8(r: 200, g: 40, b: 40)
        let second = RGB8(r: 40, g: 40, b: 200)
        let samples = Array(repeating: first, count: 32) + Array(repeating: second, count: 32)
        let estimator = FilamentColorEstimator()
        let answers = (0..<8).map { _ in estimator.estimate(from: samples)?.color }
        t.equal(Set(answers.map { $0?.hexString ?? "nil" }).count, 1, "one answer across eight runs")
        t.equal(answers.first ?? nil, first, "and it is the earlier sample")
    },

    test("no samples means no answer") { t in
        t.expect(FilamentColorEstimator().estimate(from: []) == nil, "empty input returns nil")
    },
])

// MARK: - Temporal stability

let filamentColorStabiliserTests = TestSuite(name: "Filament colour stabiliser", cases: [

    test("a window is not steady until it is full") { t in
        var stabiliser = FilamentColorStabiliser(capacity: 6)
        let estimator = FilamentColorEstimator()
        let flat = RGB8(r: 0x0A, g: 0x87, b: 0xBE)
        let samples = Array(repeating: flat, count: 64)
        for index in 1...6 {
            stabiliser.add(estimator.estimate(from: samples)!)
            let reading = t.unwrap(stabiliser.reading, "reading at frame \(index)")
            t.equal(reading?.isSteady, index == 6, "steady only on the sixth frame")
        }
    },

    test("one ruined frame does not move the settled value") { t in
        var stabiliser = FilamentColorStabiliser(capacity: 9)
        let estimator = FilamentColorEstimator()
        let good = Array(repeating: RGB8(r: 193, g: 46, b: 31), count: 64)
        let ruined = Array(repeating: RGB8(r: 20, g: 20, b: 20), count: 64)
        for index in 0..<9 {
            stabiliser.add(estimator.estimate(from: index == 4 ? ruined : good)!)
        }
        let reading = t.unwrap(stabiliser.reading, "reading")
        t.equal(reading?.color, RGB8(r: 193, g: 46, b: 31), "median ignores the outlier")
        t.equal(reading?.isSteady, false, "but the disagreement is still reported")
    },

    test("a split window reports a frame that was measured, not a colour assembled from two") { t in
        // Two reds then two olives. A per-component median took L* and b* from the reds and a*
        // from the olives, and the live swatch showed a brownish grey no frame contained for
        // as long as the transition lasted. The reading must be one of the measured frames —
        // the earliest on an exact tie, so the same window resolves the same way every run.
        var stabiliser = FilamentColorStabiliser(capacity: 4)
        let estimator = FilamentColorEstimator()
        let red = Array(repeating: RGB8(r: 0xC1, g: 0x2E, b: 0x1F), count: 64)
        let olive = Array(repeating: RGB8(r: 0x78, g: 0x6E, b: 0x14), count: 64)
        for index in 0..<4 { stabiliser.add(estimator.estimate(from: index < 2 ? red : olive)!) }
        guard let reading = t.unwrap(stabiliser.reading, "reading"),
              let redFrame = estimator.estimate(from: red) else { return }
        t.expect(reading.lab.deltaE(to: redFrame.lab) < 0.01,
                 "expected the red frame, got L*a*b* \(reading.lab)")
        t.equal(reading.isSteady, false, "a window that straddles two colours is not settled")
    },

    test("the worst confidence in the window is the one reported") { t in
        var stabiliser = FilamentColorStabiliser(capacity: 4)
        let estimator = FilamentColorEstimator()
        let clean = Array(repeating: RGB8(r: 193, g: 46, b: 31), count: 64)
        let mixed = Array(repeating: RGB8(r: 193, g: 46, b: 31), count: 32)
            + Array(repeating: RGB8(r: 30, g: 90, b: 200), count: 32)
        for index in 0..<4 {
            stabiliser.add(estimator.estimate(from: index == 2 ? mixed : clean)!)
        }
        t.equal(stabiliser.reading?.confidence, .low, "one bad frame lowers the reported confidence")
    },

    test("a warning has to hold across the window before it is shown") { t in
        var stabiliser = FilamentColorStabiliser(capacity: 5)
        let estimator = FilamentColorEstimator()
        let clean = Array(repeating: RGB8(r: 193, g: 46, b: 31), count: 64)
        let dark = Array(repeating: RGB8(r: 2, g: 2, b: 2), count: 64)
        for index in 0..<5 {
            stabiliser.add(estimator.estimate(from: index == 0 ? dark : clean)!)
        }
        t.equal(stabiliser.reading?.warnings.isEmpty, true, "a single dark frame does not warn")

        var persistent = FilamentColorStabiliser(capacity: 5)
        for _ in 0..<5 { persistent.add(estimator.estimate(from: dark)!) }
        t.expect(persistent.reading?.warnings.contains(.tooDark) == true,
                 "a dark window does")
    },

    test("reset clears the window") { t in
        var stabiliser = FilamentColorStabiliser(capacity: 3)
        let estimator = FilamentColorEstimator()
        let samples = Array(repeating: RGB8(r: 1, g: 2, b: 3), count: 16)
        for _ in 0..<3 { stabiliser.add(estimator.estimate(from: samples)!) }
        t.expect(stabiliser.reading != nil, "a reading before reset")
        stabiliser.reset()
        t.expect(stabiliser.reading == nil, "and none after")
        t.equal(stabiliser.frameCount, 0, "window emptied")
    },
])

// MARK: - Where the colour is measured

let scanTargetTests = TestSuite(name: "Scan target geometry", cases: [

    test("the target is centred and square whatever the aspect ratio") { t in
        for size in [CGSize(width: 1280, height: 720),
                     CGSize(width: 640, height: 480),
                     CGSize(width: 480, height: 640),
                     CGSize(width: 900, height: 900)] {
            let rect = ScanTarget.rect(inPixelSize: size)
            t.equal(rect.width, rect.height, "square at \(size)")
            t.expect(abs(rect.midX - size.width / 2) <= 0.5, "centred horizontally at \(size)")
            t.expect(abs(rect.midY - size.height / 2) <= 0.5, "centred vertically at \(size)")
            t.equal(rect.width, (min(size.width, size.height) * ScanTarget.fraction).rounded(),
                    "sized off the shorter side at \(size)")
        }
    },

    test("the target always fits inside the frame") { t in
        // A fraction over 0.5 of the shorter side would still fit; the guard that matters is that
        // nothing ever hangs off an edge, because a crop rectangle outside the buffer is either a
        // black band averaged into the answer or a hard failure, depending on the framework.
        for size in [CGSize(width: 1280, height: 720), CGSize(width: 17, height: 4000)] {
            let rect = ScanTarget.rect(inPixelSize: size)
            let frame = CGRect(origin: .zero, size: size)
            t.expect(frame.contains(rect), "\(rect) inside \(size)")
        }
    },

    test("a preview letterboxed inside a larger view still targets the video, not the view") { t in
        // The real case: a 16:9 camera in a 4:3 pane. The video rectangle is inset, and the target
        // has to be centred in *it* — a square centred on the whole view would be measuring the
        // black bars as readily as the picture.
        let video = CGRect(x: 0, y: 60, width: 640, height: 360)
        let rect = ScanTarget.rect(in: video)
        t.expect(video.contains(rect), "target sits inside the video rectangle")
        t.expect(abs(rect.midY - video.midY) <= 0.5, "and is centred on the video, not the view")
        t.equal(rect.width, (360 * ScanTarget.fraction).rounded(), "sized off the video's shorter side")
    },

    test("a degenerate frame yields no target rather than a bad one") { t in
        t.equal(ScanTarget.rect(inPixelSize: CGSize(width: 0, height: 0)), .zero, "empty")
        t.equal(ScanTarget.rect(in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)), .zero,
                "non-finite")
        t.equal(ScanTarget.rect(inPixelSize: CGSize(width: 2, height: 2)), .zero,
                "smaller than one unit of target")
    },
])

// MARK: - The system colour panel

let systemColorPanelTests = TestSuite(name: "System colour panel", cases: [

    test("a picked colour is pinned to sRGB before it becomes a hex") { t in
        // The panel hands back whatever space the user picked in. A Display P3 red is a *different*
        // set of code values from an sRGB red, and the tag stores sRGB — so reading components off
        // the panel's colour without converting would write a different hex for the same visible
        // colour depending on the display. Same defect `Color.rgb8` exists to prevent.
        let p3 = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let hex = t.unwrap(SystemColorPanel.canonicalHex(from: p3), "hex for P3 red")
        t.equal(hex, "FF0000", "P3 red converts to sRGB red rather than being read raw")

        // And a colour already in sRGB is untouched.
        let srgb = NSColor(srgbRed: 193 / 255.0, green: 46 / 255.0, blue: 31 / 255.0, alpha: 1)
        t.equal(SystemColorPanel.canonicalHex(from: srgb), "C12E1F", "sRGB passes through")
    },

    test("the hex is the canonical form the tag stores") { t in
        for (color, expected) in [(NSColor.black, "000000"), (NSColor.white, "FFFFFF")] {
            let hex = t.unwrap(SystemColorPanel.canonicalHex(from: color), "hex")
            t.equal(hex, expected, "\(expected)")
            t.equal(hex?.count, 6, "six digits, no hash")
            t.equal(hex, hex?.uppercased(), "uppercase")
        }
    },

    test("hex to panel and back is exact, so the field and the panel cannot oscillate") { t in
        // The two write to each other: a pick updates the field, and a colour typed or scanned is
        // pushed back into an open panel. That is only safe while the round trip is the identity —
        // if seeding the panel with a hex could produce a *different* hex on read-back, the pair
        // would chase each other. Both ends are 8-bit sRGB, so it is exact; this is what says so.
        for hex in ["C12E1F", "0087BE", "000000", "FFFFFF", "3C3C3D", "DEE4E1", "010203"] {
            guard let color = t.unwrap(Color(tagHex: hex), "colour for \(hex)") else { continue }
            t.equal(SystemColorPanel.canonicalHex(from: NSColor(color)), hex, "round trip of \(hex)")
        }
    },

    test("a colour with no RGB representation yields no hex rather than a wrong one") { t in
        // Pattern colours cannot be converted. Returning nil leaves the field alone; inventing a
        // value would put a colour on a tag that nobody chose.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        t.expect(SystemColorPanel.canonicalHex(from: pattern) == nil, "pattern colour returns nil")
    },
])
