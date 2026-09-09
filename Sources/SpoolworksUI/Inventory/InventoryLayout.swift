import SwiftUI
import Combine

/// The Inventory table's column widths and the detail rail's width, dragged by the user and
/// remembered.
///
/// The table is hand-built from stacks rather than SwiftUI's `Table` — `Table` brings AppKit header
/// chrome, alternating fills and rounded selection that the Modernist system forbids — and the
/// stated cost of that choice was that resizing has to be written by hand if it were ever wanted.
/// This is that.
///
/// ## Which column a handle resizes
///
/// One column, `Filament`, is flexible and every other is fixed; the flexible one absorbs whatever
/// the fixed ones leave. So a handle sets the width of the fixed column **to its left**, and
/// `Filament` grows or shrinks to compensate. Dragging right always makes the thing left of the
/// handle wider, which is the behaviour every table in every other app has.
///
/// `Filament` itself has no handle, and needs none: it is whatever is left. Giving it one would
/// mean pinning it, and then nothing would absorb the slack and the row would stop filling the pane.
///
/// ## Why the values are clamped rather than validated
///
/// A width is a drag, not an entry, so there is no wrong value to reject — only values that would
/// make the table unusable. Each column has a floor wide enough for its own header, and the rail has
/// both a floor and a ceiling so neither it nor the list can be dragged out of existence. Clamping
/// on read as well as on write is deliberate: a `UserDefaults` plist edited by hand, or written by a
/// future version with different limits, must not be able to produce a window with no table in it.
@MainActor
final class InventoryLayout: ObservableObject {

    /// A resizable column. `Filament` is absent on purpose — see the type's note.
    enum Column: String, CaseIterable {
        case type, location, remaining, tag

        /// Narrow enough to be useful, wide enough that the header still reads.
        var minimum: CGFloat {
            switch self {
            case .type: return 52
            case .location: return 70
            case .remaining: return 68
            case .tag: return 64
            }
        }

        var maximum: CGFloat { 420 }

        var defaultWidth: CGFloat {
            switch self {
            case .type: return 70
            case .location: return 118
            case .remaining: return 86
            case .tag: return 118
            }
        }

        fileprivate var storageKey: String { "SpoolworksInventoryColumn_\(rawValue)" }
    }

    /// Not resizable: it holds a fixed-size swatch, so there is nothing for a wider column to show.
    static let swatchWidth: CGFloat = 34

    static let railMinimum: CGFloat = 300
    static let railMaximum: CGFloat = 720
    static let railDefault: CGFloat = 400

    private static let railStorageKey = "SpoolworksInventoryRailWidth"

    @Published private(set) var columns: [Column: CGFloat]
    @Published private(set) var railWidth: CGFloat

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [Column: CGFloat] = [:]
        for column in Column.allCases {
            let stored = defaults.object(forKey: column.storageKey) as? Double
            loaded[column] = Self.clamp(stored.map { CGFloat($0) } ?? column.defaultWidth,
                                        min: column.minimum, max: column.maximum)
        }
        columns = loaded
        let storedRail = defaults.object(forKey: Self.railStorageKey) as? Double
        railWidth = Self.clamp(storedRail.map { CGFloat($0) } ?? Self.railDefault,
                               min: Self.railMinimum, max: Self.railMaximum)
    }

    func width(_ column: Column) -> CGFloat {
        columns[column] ?? column.defaultWidth
    }

    /// Applies a drag to one column. `proposed` is the width the gesture asks for, before limits.
    func setWidth(_ proposed: CGFloat, for column: Column) {
        let value = Self.clamp(proposed, min: column.minimum, max: column.maximum)
        guard columns[column] != value else { return }
        columns[column] = value
        defaults.set(Double(value), forKey: column.storageKey)
    }

    /// Applies a drag to the rail.
    ///
    /// The ceiling is a constant rather than a fraction of the window because the drag is reported
    /// in the rail's own coordinates and the window width is not to hand here; 720 is wide enough
    /// for the widest thing the rail holds and still leaves a usable table on a 1080 pt window,
    /// which is this app's declared minimum.
    func setRailWidth(_ proposed: CGFloat) {
        let value = Self.clamp(proposed, min: Self.railMinimum, max: Self.railMaximum)
        guard railWidth != value else { return }
        railWidth = value
        defaults.set(Double(value), forKey: Self.railStorageKey)
    }

    /// Puts everything back, for a layout dragged into a corner.
    func reset() {
        for column in Column.allCases {
            columns[column] = column.defaultWidth
            defaults.removeObject(forKey: column.storageKey)
        }
        railWidth = Self.railDefault
        defaults.removeObject(forKey: Self.railStorageKey)
    }

    /// Non-finite values are replaced rather than clamped: `NaN` compares false against everything,
    /// so `min`/`max` would pass it straight through into a frame and break layout for the session.
    ///
    /// `nonisolated` because it is pure arithmetic; the rest of this type is main-actor bound only
    /// because it drives view state.
    nonisolated static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }
}
