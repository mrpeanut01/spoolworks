import Foundation

// Colour spaces used *only* by the camera scanner (``FilamentColorEstimator``).
//
// Nothing on the tag path goes near this file. The tag stores raw 8-bit sRGB code values and
// ``ColorMatcher`` compares them with unweighted integer arithmetic, because that is what the
// Windows and Android apps do and cross-platform parity depends on it (SPEC/05-color.md §2.2).
// That rule governs *naming a colour*, not *measuring one off a camera* — and measuring is the job
// here. The estimator's output is an ``RGB8`` that then goes through the same integer matcher as
// any other colour, so the parity rule is untouched.
//
// Two spaces are needed, each for a specific reason:
//
//   - **Linear RGB**, for averaging. sRGB is gamma-encoded, so the arithmetic mean of two encoded
//     values is not the colour of the light they represent. Averaging a patch of pixels in encoded
//     space biases every result dark, and the bias is largest exactly where a filament photograph
//     has the most contrast: across the boundary between a lit strand and the shadow beside it.
//
//   - **CIELAB**, for clustering, and for telling shading apart from colour. A strand of filament
//     is a 1.75 mm cylinder, so a photograph of a wrap is a field of curved highlights and
//     inter-strand shadow. Shading moves a sample a long way along L* and comparatively little
//     across a*/b*. That anisotropy is the entire basis of the estimator, and it is only visible in
//     a space where lightness is its own axis; in sRGB it is smeared across all three channels.

/// Linear-light sRGB. Components are nominally `0...1` but deliberately unclamped.
///
/// Averaging and interpolation happen here, and clamping intermediates would quietly bias the
/// result. Clamping happens exactly once, in ``RGB8/init(linear:)``.
public struct LinearRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// The sRGB transfer function (IEC 61966-2-1), encoded → linear.
    public static func decode(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// `decode` for all 256 8-bit inputs, precomputed.
    ///
    /// Not an approximation — the input domain really is 256 values, so this is the same function
    /// with the `pow` hoisted out. It matters because the scanner decodes every pixel of every
    /// frame: a 160 px crop at 12 fps is half a million `pow` calls a second otherwise, which is
    /// most of the cost of the whole pipeline for no reason at all.
    static let decodeTable: [Double] = (0...255).map { decode(Double($0) / 255) }

    /// The inverse, linear → encoded. Clamps, because this is the last step before 8 bits.
    public static func encode(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

extension RGB8 {
    /// This colour with the sRGB transfer function removed.
    public var linear: LinearRGB {
        let table = LinearRGB.decodeTable
        return LinearRGB(r: table[Int(r)], g: table[Int(g)], b: table[Int(b)])
    }

    /// Re-encodes linear light as an 8-bit sRGB triple, clamping and rounding once.
    public init(linear: LinearRGB) {
        func channel(_ value: Double) -> UInt8 {
            guard value.isFinite else { return 0 }
            return UInt8(min(max((LinearRGB.encode(value) * 255).rounded(), 0), 255))
        }
        self.init(r: channel(linear.r), g: channel(linear.g), b: channel(linear.b))
    }

    /// The mean of a set of colours, computed in linear light.
    ///
    /// Returns nil for an empty input rather than black, which is a real colour and would be
    /// indistinguishable from a genuine measurement.
    public static func mean<S: Sequence>(ofLinear colors: S) -> RGB8? where S.Element == RGB8 {
        var sum = LinearRGB(r: 0, g: 0, b: 0)
        var count = 0
        for color in colors {
            let linear = color.linear
            sum.r += linear.r
            sum.g += linear.g
            sum.b += linear.b
            count += 1
        }
        guard count > 0 else { return nil }
        let n = Double(count)
        return RGB8(linear: LinearRGB(r: sum.r / n, g: sum.g / n, b: sum.b / n))
    }
}

/// CIELAB under a D65 white point — the space the scanner clusters and averages in.
public struct LabColor: Equatable, Sendable {
    /// Perceptual lightness: `0` is black, `100` is diffuse white.
    public var l: Double
    /// Green ↔ red.
    public var a: Double
    /// Blue ↔ yellow.
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    // D65. sRGB's primaries are already defined against D65, so no chromatic adaptation is
    // involved and the matrix below is the standard sRGB one.
    private static let whiteX = 0.95047
    private static let whiteY = 1.00000
    private static let whiteZ = 1.08883

    // (6/29)³ and 3·(6/29)², the knee of the CIE lightness function, in their exact rational form.
    private static let epsilon = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    public init(_ rgb: RGB8) {
        self.init(linear: rgb.linear)
    }

    public init(linear: LinearRGB) {
        let x = 0.4124564 * linear.r + 0.3575761 * linear.g + 0.1804375 * linear.b
        let y = 0.2126729 * linear.r + 0.7151522 * linear.g + 0.0721750 * linear.b
        let z = 0.0193339 * linear.r + 0.1191920 * linear.g + 0.9503041 * linear.b

        func f(_ t: Double) -> Double {
            t > Self.epsilon ? cbrt(t) : (Self.kappa * t + 16) / 116
        }

        let fx = f(x / Self.whiteX)
        let fy = f(y / Self.whiteY)
        let fz = f(z / Self.whiteZ)

        self.l = 116 * fy - 16
        self.a = 500 * (fx - fy)
        self.b = 200 * (fy - fz)
    }

    /// Back to linear light. May land outside the sRGB gamut; ``RGB8/init(linear:)`` clamps.
    public var linear: LinearRGB {
        let fy = (l + 16) / 116
        let fx = fy + a / 500
        let fz = fy - b / 200

        func inverse(_ t: Double) -> Double {
            let cubed = t * t * t
            return cubed > Self.epsilon ? cubed : (116 * t - 16) / Self.kappa
        }

        let x = inverse(fx) * Self.whiteX
        let y = (l > Self.kappa * Self.epsilon ? pow(fy, 3) : l / Self.kappa) * Self.whiteY
        let z = inverse(fz) * Self.whiteZ

        return LinearRGB(r:  3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
                         g: -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
                         b:  0.0556434 * x - 0.2040259 * y + 1.0572252 * z)
    }

    /// The nearest in-gamut 8-bit sRGB triple.
    public var rgb8: RGB8 { RGB8(linear: linear) }

    /// Chroma — distance from the neutral axis. Near zero for black, white and grey.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// Distance in the a*/b* plane alone: what shading mostly *preserves*.
    public func chromaDistance(to other: LabColor) -> Double {
        let da = a - other.a
        let db = b - other.b
        return (da * da + db * db).squareRoot()
    }

    /// CIE76 ΔE*ab. Used for reporting spread and in tests — never to pick a name. Names come from
    /// ``ColorMatcher``'s integer sRGB metric, which must not change.
    public func deltaE(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Component-wise mean. Nil for an empty input, for the same reason as ``RGB8/mean(ofLinear:)``.
    public static func mean<S: Sequence>(of colors: S) -> LabColor? where S.Element == LabColor {
        var sum = LabColor(l: 0, a: 0, b: 0)
        var count = 0
        for color in colors {
            sum.l += color.l
            sum.a += color.a
            sum.b += color.b
            count += 1
        }
        guard count > 0 else { return nil }
        let n = Double(count)
        return LabColor(l: sum.l / n, a: sum.a / n, b: sum.b / n)
    }
}
