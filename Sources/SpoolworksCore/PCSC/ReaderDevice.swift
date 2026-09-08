import Foundation

/// A physical reader, which may expose more than one PC/SC slot.
///
/// PC/SC enumerates *slots*, not devices. A single ACS ACR1552 reports two:
/// `ACS ACR1552 1S CL Reader(1)` and `ACS ACR1552 1S CL Reader(2)`. Presenting those as two
/// readers is simply wrong — the user owns one device, and in practice a card only ever appears
/// on the first slot.
///
/// The Windows app sidesteps this by monitoring every slot at once and never showing a count
/// (`MainForm.cs:333`). We do the same, but also group slots so the UI can name the device once.
public struct ReaderDevice: Equatable, Hashable, Identifiable {
    /// Device name with the slot suffix removed, e.g. `ACS ACR1552 1S CL Reader`.
    public let displayName: String
    /// Every PC/SC slot belonging to this device, in enumeration order.
    public let slotNames: [String]

    public var id: String { displayName }
    /// True when the device exposes more than one slot — worth a subtitle, never a reader count.
    public var hasMultipleSlots: Bool { slotNames.count > 1 }

    public init(displayName: String, slotNames: [String]) {
        self.displayName = displayName
        self.slotNames = slotNames
    }

    /// Strips a trailing slot index: `"ACS ACR1552 1S CL Reader(1)"` → `"ACS ACR1552 1S CL Reader"`.
    ///
    /// Returns the name unchanged when there is no suffix, so a reader that does not use the
    /// convention still groups correctly (as a device of one slot).
    static func baseName(of slotName: String) -> String {
        guard slotName.hasSuffix(")"),
              let open = slotName.lastIndex(of: "(") else { return slotName }
        let inside = slotName[slotName.index(after: open)..<slotName.index(before: slotName.endIndex)]
        // Only strip when the parenthesised part is purely a number, so a reader legitimately
        // named "... (Contactless)" keeps its name.
        guard !inside.isEmpty, inside.allSatisfy(\.isNumber) else { return slotName }
        return String(slotName[slotName.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Groups raw PC/SC slot names into devices, preserving enumeration order.
    ///
    /// Note the ambiguity this cannot resolve: two physically identical readers also enumerate as
    /// `Name(1)`, `Name(2)`, and PC/SC gives us nothing else to tell them apart. Grouping is
    /// therefore the right default for the common case (one multi-slot device) and merely
    /// cosmetic in the rare one — card detection polls every slot either way, so nothing breaks.
    public static func group(slotNames: [String]) -> [ReaderDevice] {
        var order: [String] = []
        var slotsByDevice: [String: [String]] = [:]
        for slot in slotNames {
            let base = baseName(of: slot)
            if slotsByDevice[base] == nil {
                slotsByDevice[base] = []
                order.append(base)
            }
            slotsByDevice[base]?.append(slot)
        }
        return order.map { ReaderDevice(displayName: $0, slotNames: slotsByDevice[$0] ?? []) }
    }
}

public extension PCSCContext {
    /// Connected readers as physical devices rather than raw PC/SC slots.
    ///
    /// This is what a UI should display. Card polling still uses `readerNames()` so every slot is
    /// checked, so a multi-slot reader still detects a card on any of its slots.
    func readerDevices() throws -> [ReaderDevice] {
        ReaderDevice.group(slotNames: try readerNames())
    }
}
