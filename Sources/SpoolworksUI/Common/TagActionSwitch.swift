import SwiftUI

/// Which mode the tag screen is in.
///
/// This is a **mode**, not an action. Selecting a side changes what the whole screen shows; it
/// never touches the tag. Reading is performed by Read mode's primary button (and ⌘R); writing by
/// Write mode's primary button (and ⇧⌘W), which always goes through the confirmation sheet.
enum TagMode: String, CaseIterable, Identifiable, Hashable {
    case read
    case write

    var id: String { rawValue }
    var title: String { self == .read ? "Read" : "Write" }
    var symbol: String { self == .read ? "tray.and.arrow.down" : "tray.and.arrow.up" }

    var help: String {
        self == .read
            ? "Show what is on the tag that is on the reader"
            : "Compose the values to write to a tag"
    }
}
