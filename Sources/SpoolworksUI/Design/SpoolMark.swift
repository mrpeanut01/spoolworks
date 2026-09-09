import SwiftUI

/// The Spoolworks mark: a spool seen side-on, two flanges with the filament wound between them.
///
/// The same three rectangles as the app icon (`Tools/make-icon.swift`), at the same proportions, so
/// the thing beside the wordmark and the thing in the Dock are one mark rather than two that happen
/// to share a colour. Before this the header carried a plain accent square — which in dark mode is
/// indistinguishable from a red dot, and says nothing about what the app is.
///
/// ## It does not follow the theme, on purpose
///
/// Every other colour in this app is a `Theme` token that resolves per appearance. These four are
/// fixed sRGB literals, because a logo that inverts is not the same logo: the flanges are light and
/// the ground is ink in both appearances, which is what lets the mark carry its own contrast onto a
/// light sidebar and a dark one alike. It is also what the icon does, for the harder version of the
/// same problem — a mark drawn in the *theme's* ink vanished entirely once macOS 26 derived a dark
/// variant of it, which is the bug that produced "the logo is a red dot" in the first place.
struct SpoolMark: View {

    var size: CGFloat = 20

    // The icon's palette, matched literally. Deliberately not `Theme.accent` and friends — see
    // the note above.
    private static let ground = Color(.sRGB, red: 0xF3 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    private static let ink = Color(.sRGB, red: 0x20 / 255, green: 0x1E / 255, blue: 0x1D / 255)
    private static let accent = Color(.sRGB, red: 0xEC / 255, green: 0x30 / 255, blue: 0x13 / 255)

    var body: some View {
        // Fractions of the side, exactly as `make-icon.swift` computes them, so the mark keeps its
        // proportions at any size and cannot drift from the icon by being tweaked here.
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            func fill(_ rect: CGRect, _ colour: Color) {
                context.fill(Path(rect), with: .color(colour))
            }

            fill(CGRect(x: 0, y: 0, width: s, height: s), Self.ink)

            let border = max(1, (s * 0.055).rounded())
            fill(CGRect(x: 0, y: 0, width: s, height: border), Self.ground)
            fill(CGRect(x: 0, y: s - border, width: s, height: border), Self.ground)
            fill(CGRect(x: 0, y: 0, width: border, height: s), Self.ground)
            fill(CGRect(x: s - border, y: 0, width: border, height: s), Self.ground)

            let flangeWidth = (s * 0.155).rounded()
            let flangeTop = (s * 0.215).rounded()
            let flangeHeight = s - flangeTop * 2
            let leftX = (s * 0.205).rounded()
            let rightX = s - leftX - flangeWidth
            fill(CGRect(x: leftX, y: flangeTop, width: flangeWidth, height: flangeHeight), Self.ground)
            fill(CGRect(x: rightX, y: flangeTop, width: flangeWidth, height: flangeHeight), Self.ground)

            let coreInset = (s * 0.055).rounded()
            fill(CGRect(x: leftX + flangeWidth,
                        y: flangeTop + coreInset,
                        width: rightX - (leftX + flangeWidth),
                        height: flangeHeight - coreInset * 2), Self.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
