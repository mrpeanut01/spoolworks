import AppKit
import SwiftUI

/// The macOS colour panel, wired to a single hex value.
///
/// `NSColorPanel` is an application-wide singleton, which is the entire difficulty: it has one
/// target and one action, so two screens that both wire themselves to it silently fight, and a
/// screen that wires itself and then goes away leaves the panel driving a dead binding. Everything
/// awkward in this file is about that one fact.
///
/// The alternative was SwiftUI's `ColorPicker`, which manages the panel for you. It is rejected on
/// appearance, not on function: it draws its own rounded system well, and every swatch in this app
/// is a square `Swatch` with a 1 pt border. Using it here would put the one rounded control in the
/// app directly beside the square one it replaces.
///
/// ## Ownership
///
/// One owner at a time, identified by a token. ``present(hex:owner:onPick:)`` takes ownership;
/// ``relinquish(owner:)`` gives it up and is safe to call when someone else has since taken it,
/// which is what makes it correct to call unconditionally from `onDisappear`.
@MainActor
final class SystemColorPanel: NSObject {

    static let shared = SystemColorPanel()

    private var owner: AnyHashable?
    private var onPick: ((String) -> Void)?

    /// True while *we* are writing the panel's colour, so the change we caused is not read back as
    /// a change the user made. Without it, seeding the panel from the field immediately re-emits
    /// that value — harmless until the field held something the panel cannot represent exactly,
    /// at which point the two ping-pong.
    private var isSeeding = false

    /// The panel's mode is only forced once per launch.
    ///
    /// The mode is a user-visible choice that `NSColorPanel` remembers, so "open on the solid
    /// colours" has to mean *default to*, not *revert to*. Someone who switches to the wheel to
    /// dial in an exact value and comes back to find crayons again would rightly read that as the
    /// app overriding them.
    private var hasSetInitialMode = false

    // MARK: - Ownership

    /// Shows the panel, seeded with `hex`, and routes its changes to `onPick`.
    ///
    /// `onPick` receives the canonical uppercase `RRGGBB` form — the same form the tag stores — so
    /// a caller can assign it straight to a hex field.
    func present(hex: String, owner: AnyHashable, onPick: @escaping (String) -> Void) {
        self.owner = owner
        self.onPick = onPick

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if !hasSetInitialMode {
            // Crayons: the flat grid of named solid colours. The wheel is a better instrument for
            // matching a specific colour and a worse one for picking a filament, which is what this
            // field is for — every other tab is still one click away.
            panel.mode = .crayon
            hasSetInitialMode = true
        }
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged))

        seed(hex: hex)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Pushes a colour that changed *elsewhere* — typed into the field, or scanned — into an open
    /// panel.
    ///
    /// Without this the panel keeps showing the colour it last set, so the next click on it would
    /// quietly undo whatever was typed or scanned in the meantime. The rule the user asked for is
    /// that the newest input wins, and the panel is one of the inputs.
    func update(hex: String, owner: AnyHashable) {
        guard self.owner == owner, NSColorPanel.sharedColorPanelExists,
              NSColorPanel.shared.isVisible else { return }
        seed(hex: hex)
    }

    /// Gives up ownership, if this owner still has it. Safe to call unconditionally.
    func relinquish(owner: AnyHashable) {
        guard self.owner == owner else { return }
        self.owner = nil
        self.onPick = nil
        // `NSColorPanel` exposes no readable target, but it does not need one: this class is the
        // only thing in the app that ever sets it, so the target is always `self` and the routing
        // that actually matters is `onPick`, cleared above.
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        // Deliberately left open. It is the user's panel, they may have moved it somewhere they
        // want it, and closing a floating window because a screen changed is not this app's call.
    }

    // MARK: - Wiring

    private func seed(hex: String) {
        guard let color = Color(tagHex: hex).map(NSColor.init) else { return }
        isSeeding = true
        NSColorPanel.shared.color = color
        isSeeding = false
    }

    @objc private func panelColorChanged() {
        guard !isSeeding, let onPick,
              let hex = Self.canonicalHex(from: NSColorPanel.shared.color) else { return }
        onPick(hex)
    }

    /// `RRGGBB`, uppercase, pinned to sRGB.
    ///
    /// The pinning is not cosmetic. The tag stores raw sRGB code values and `ColorMatcher` compares
    /// them as integers, while the colour panel hands back whatever space the user picked in — a
    /// Display P3 red on a P3 Mac. Reading its components without converting first would write a
    /// different hex for the same visible colour depending on the display, which is the same defect
    /// `Color.rgb8` exists to prevent.
    ///
    /// Nil only for a colour with no RGB representation at all, such as a pattern.
    ///
    /// `nonisolated` because it is a pure conversion that touches nothing shared — the rest of this
    /// class is main-actor bound because `NSColorPanel` is, and this is not.
    nonisolated static func canonicalHex(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        return RGB8Components(r: channel(srgb.redComponent),
                              g: channel(srgb.greenComponent),
                              b: channel(srgb.blueComponent)).hexString
    }
}
