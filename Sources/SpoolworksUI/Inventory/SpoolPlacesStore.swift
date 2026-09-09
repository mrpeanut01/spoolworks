import Foundation
import SpoolworksCore

/// Where the user's place names are kept between launches.
///
/// `UserDefaults`, like every other persistent preference in this app — the key is prefixed so it
/// cannot collide with the Windows original's registry values, exactly as ``AppSettings`` explains.
/// The inventory file is deliberately *not* the home for this: `inventory.json` is a record of
/// spools, it is rewritten on every reconcile, and a list of names the user typed has no business
/// riding along with data the printer owns.
///
/// It is a free function pair rather than another `ObservableObject` because the list already has
/// an owner — ``InventoryViewModel``, which is the app's single writer of spool state and the only
/// object that can keep the list and the spools that reference it in step. A second observable
/// holding the same names would be a second source of truth. The same reasoning put
/// ``PrinterSettings`` in this shape.
enum SpoolPlacesStore {

    static let key = "SpoolworksSpoolPlaces"
    static let unloadKey = "SpoolworksUnloadDestination"

    /// The stored list, or the seeded one on a first run.
    ///
    /// Absence and emptiness are distinguished on purpose. `stringArray(forKey:)` cannot tell "the
    /// key was never written" from "the user deleted every place", and those need opposite
    /// answers: the first must seed `Unplaced, Shelf, CFS, Ext…`, the second must be honoured and
    /// leave the list at just `Unplaced`. `object(forKey:)` is the only read that can tell them
    /// apart — the same trap a default-on `Bool` preference has, where `bool(forKey:)`
    /// cannot tell "never written" from "turned off".
    static func load(from defaults: UserDefaults = .standard) -> SpoolPlaces {
        let destination = defaults.string(forKey: unloadKey) ?? SpoolPlaces.unplaced
        guard let stored = defaults.object(forKey: key) as? [String] else {
            return SpoolPlaces(unloadDestination: destination)
        }
        // `SpoolPlaces.init` re-normalises, so a hand-edited or truncated array cannot produce a
        // list with duplicates, blanks, no `Unplaced`, or a destination naming a place the list
        // does not contain.
        return SpoolPlaces(names: stored, unloadDestination: destination)
    }

    static func save(_ places: SpoolPlaces, to defaults: UserDefaults = .standard) {
        defaults.set(places.names, forKey: key)
        defaults.set(places.unloadDestination, forKey: unloadKey)
    }
}
