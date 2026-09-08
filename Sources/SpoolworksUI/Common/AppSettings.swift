import Foundation
import SwiftUI
import Combine

/// The two persistent switches the app still has, backed by `UserDefaults`.
///
/// Key names are prefixed so they never collide with the Windows registry values under
/// `HKCU\CFS RFID\Settings` (`SPEC/03-ui.md` §2 and §8.4).
///
/// **There is no preferences window.** Both switches are rendered next to what they affect —
/// `advancedTagOperations` on the Auto-Write card and in the write confirmation sheet,
/// `showKeyMaterial` on the Reader screen — and the `Settings` scene has been removed. See
/// ``ReaderPane`` for the reasoning.
///
/// ## The Windows `AutoRead` / `AutoWrite` pair
///
/// Windows has two mutually exclusive switches, each forcing the other off
/// (`MainForm.cs:958-974`), both defaulting to off. Neither is a *preference* here:
///
/// * **`AutoRead`.** Read mode reads a tag the moment it arrives, unconditionally. A preference
///   for it could only turn the Read screen's entire purpose off, and its Windows default (off) is
///   precisely the behaviour users reported as broken — a tag on the reader, its UID on screen,
///   and "not read yet" underneath.
/// * **`AutoWrite`.** Windows writes the moment a tag lands (`MainForm.cs:276-279`), and so does
///   this app now, at the tool owner's explicit instruction — see
///   ``TagViewModel/autoWriteEnabled``, which is where that switch lives. It is on the Write
///   screen rather than here on purpose: it changes what happens when you touch the reader, which
///   is not something to discover in a preferences pane.
@MainActor
final class AppSettings: ObservableObject {

    private let defaults: UserDefaults

    /// Permits the one irreversible operation this app can perform: rewriting a sector trailer,
    /// which is what programming a blank tag requires.
    ///
    /// **Off by default, and it stays off unless the user turns it on.** Nothing writes a sector
    /// key while it is off — not the confirmation sheet, whose Write button stays disabled, and
    /// not auto-write, which raises the sheet instead of programming a blank tag. Even with it on,
    /// the sheet still asks for a separate per-write acknowledgement.
    @Published var advancedTagOperations: Bool {
        didSet { defaults.set(advancedTagOperations, forKey: Keys.advancedTagOperations) }
    }

    /// Show sector trailers and key bytes on the tag screen and in the memory inspector.
    /// Display only; it changes nothing that is written.
    @Published var showKeyMaterial: Bool {
        didSet { defaults.set(showKeyMaterial, forKey: Keys.showKeyMaterial) }
    }

    /// After a verified write, add the spool to stock.
    ///
    /// On by default, which is what the design shows and what the action implies: programming a
    /// tag for a spool is the moment you take ownership of it, and a spool you have just tagged
    /// and not logged is exactly the gap the inventory exists to close. Off is for re-tagging a
    /// spool that is already in stock — replacing a damaged tag — where a second record would be
    /// a duplicate.
    @Published var addWrittenSpoolsToInventory: Bool {
        didSet { defaults.set(addWrittenSpoolsToInventory, forKey: Keys.addWrittenSpoolsToInventory) }
    }

    enum Keys {
        static let advancedTagOperations = "K2AdvancedTagOperations"
        static let showKeyMaterial = "K2ShowKeyMaterial"
        static let addWrittenSpoolsToInventory = "SpoolworksAddWrittenSpoolsToInventory"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        advancedTagOperations = defaults.bool(forKey: Keys.advancedTagOperations)
        showKeyMaterial = defaults.bool(forKey: Keys.showKeyMaterial)
        // `bool(forKey:)` is false for an absent key, so the default-on preference is read
        // through `object(forKey:)` — otherwise "never set" is indistinguishable from "turned off".
        addWrittenSpoolsToInventory =
            (defaults.object(forKey: Keys.addWrittenSpoolsToInventory) as? Bool) ?? true
    }
}
