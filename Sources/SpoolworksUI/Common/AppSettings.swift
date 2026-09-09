import Foundation
import SwiftUI
import Combine

/// The persistent switches the app still has, backed by `UserDefaults`.
///
/// Key names are prefixed so they never collide with the Windows registry values under
/// `HKCU\CFS RFID\Settings` (`SPEC/03-ui.md` §2 and §8.4).
///
/// **There is no preferences window.** Each switch is rendered next to what it affects —
/// `showKeyMaterial` on the Reader screen —
/// and the `Settings` scene has been removed. See ``ReaderPane`` for the reasoning.
///
/// There was a third, `advancedTagOperations`, which had to be turned on before a blank tag could
/// be programmed. Programming a blank tag is what tagging a new spool *is*, and the tag has
/// nothing on it to lose, so the opt-in only ever stood between the user and the app's most
/// ordinary operation. The authorisation now comes from the write plan's own reading of the tag
/// (``WritePlan/isBlankTagProgramming``), which `TagService` re-checks against the card in front
/// of it — a claim that can be verified, rather than a preference that could only be trusted.
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

    /// Show sector trailers and key bytes on the tag screen and in the memory inspector.
    /// Display only; it changes nothing that is written.
    @Published var showKeyMaterial: Bool {
        didSet { defaults.set(showKeyMaterial, forKey: Keys.showKeyMaterial) }
    }


    enum Keys {
        static let showKeyMaterial = "K2ShowKeyMaterial"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showKeyMaterial = defaults.bool(forKey: Keys.showKeyMaterial)
        // `bool(forKey:)` is false for an absent key, so the default-on preference is read
        // through `object(forKey:)` — otherwise "never set" is indistinguishable from "turned off".
    }
}
