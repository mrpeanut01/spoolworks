import Foundation

// MARK: - material_box_info.json

/// The printer's live view of its filament: what is in every CFS slot, what is on the external
/// holder, and which slots the firmware considers interchangeable.
///
/// Read from `/mnt/UDISK/creality/userdata/box/material_box_info.json` (K1-class printers use
/// `/usr/data/...`; see ``PrinterType``). It is the **only** source of a remaining-filament figure
/// that is not a guess — the CFS measures it — which is why the inventory treats a poll as
/// authoritative over its own arithmetic.
///
/// ## Decoding is deliberately lenient
///
/// Every field below has a default and is decoded with `decodeIfPresent`. That is not laziness: an
/// empty CFS slot omits or blanks most of its keys, and a strict decoder would throw on the whole
/// document because one of four slots has no spool in it. The failure mode of strictness here is
/// "the Printer screen is empty and the app cannot say why", which is worse than a slot rendering
/// as unknown. The one field that must be present is ``CFSBox/boxID``, because a box with no
/// identifier cannot be matched to anything.
public struct MaterialBoxInfo: Codable, Hashable, Sendable {

    /// The spool on the external holder, if the printer reports one. Absent on printers with no
    /// holder configured.
    public var rackMaterial: RackMaterial?
    /// The CFS section. Capitalised in the file, which is why the coding key is spelled out.
    public var material: MaterialSection

    private enum CodingKeys: String, CodingKey {
        case rackMaterial
        case material = "Material"
    }

    public init(rackMaterial: RackMaterial? = nil, material: MaterialSection = .init()) {
        self.rackMaterial = rackMaterial
        self.material = material
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rackMaterial = try c.decodeIfPresent(RackMaterial.self, forKey: .rackMaterial)
        material = try c.decodeIfPresent(MaterialSection.self, forKey: .material) ?? .init()
    }

    /// Parses a document straight off the printer.
    public static func decode(from data: Data) throws -> MaterialBoxInfo {
        try JSONDecoder().decode(MaterialBoxInfo.self, from: data)
    }

    // MARK: Derived

    public var boxes: [CFSBox] { material.info }

    /// Total slots across every attached box — `4 × boxes`.
    public var slotCount: Int { boxes.reduce(0) { $0 + $1.list.count } }

    /// Slots with a spool actually in them.
    public var loadedSlotCount: Int { boxes.reduce(0) { $0 + $1.list.filter(\.isLoaded).count } }

    /// True when the printer is running from the external holder with no CFS attached.
    public var hasNoCFS: Bool { boxes.isEmpty }

    /// Every loaded slot, flattened, each paired with the box it sits in.
    public var loadedSlots: [(box: CFSBox, slot: CFSSlot)] {
        boxes.flatMap { box in box.list.filter(\.isLoaded).map { (box, $0) } }
    }
}

// MARK: - The external holder

/// `rackMaterial` — the spool on the printer's own holder rather than in a CFS.
///
/// Carries no `remainLen`: the holder has no sensor. Anything shown for it is the inventory's own
/// last figure, which is why the design labels this path *"estimated from gcode consumption"*.
public struct RackMaterial: Codable, Hashable, Sendable {

    public var attach: Bool
    public var selected: Bool
    public var rfid: Int
    public var editStatus: Int
    public var filamentId: String
    /// `"#0C12E1F"` — a `#`, the tag's unknown leading nibble, then `RRGGBB`.
    public var color: String
    public var brand: String
    public var name: String
    public var materialType: String
    public var minTemp: Int
    public var maxTemp: Int
    /// Absent on the K2 Plus dump this was modelled from; present on some firmware.
    public var venderId: String?
    public var serialNum: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attach = try c.decodeIfPresent(Bool.self, forKey: .attach) ?? false
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        rfid = try c.decodeIfPresent(Int.self, forKey: .rfid) ?? 0
        editStatus = try c.decodeIfPresent(Int.self, forKey: .editStatus) ?? 0
        filamentId = try c.decodeIfPresent(String.self, forKey: .filamentId) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        brand = try c.decodeIfPresent(String.self, forKey: .brand) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        materialType = try c.decodeIfPresent(String.self, forKey: .materialType) ?? ""
        minTemp = try c.decodeIfPresent(Int.self, forKey: .minTemp) ?? 0
        maxTemp = try c.decodeIfPresent(Int.self, forKey: .maxTemp) ?? 0
        venderId = try c.decodeIfPresent(String.self, forKey: .venderId)
        serialNum = try c.decodeIfPresent(String.self, forKey: .serialNum)
    }

    /// `RRGGBB`, having dropped the `#` and the unknown leading nibble.
    public var rgbHex: String { Spool.normaliseHex(color) }

    /// `"190–240 °C"`, or nil when the profile carries no range.
    public var temperatureLabel: String? {
        (minTemp == 0 && maxTemp == 0) ? nil : "\(minTemp)–\(maxTemp) °C"
    }

    /// The identity of the mounted spool, when the firmware reports enough to form one.
    public var identity: SpoolIdentity? {
        guard let venderId, let serialNum, !filamentId.isEmpty else { return nil }
        return SpoolIdentity(vendorId: venderId, filamentId: filamentId,
                             colorHex: rgbHex, serialNumber: serialNum)
    }
}

// MARK: - The CFS section

public struct MaterialSection: Codable, Hashable, Sendable {

    /// `"connect"` when at least one box is talking.
    public var state: String
    public var filament: Int
    /// 1 when the firmware may draw from a partner slot as one runs out.
    public var autoRefill: Int
    /// Slots the firmware considers interchangeable, grouped by filament ID **and** colour.
    public var sameMaterial: [SameMaterialGroup]
    public var enable: Int
    public var info: [CFSBox]

    private enum CodingKeys: String, CodingKey {
        case state, filament, enable, info
        case autoRefill = "auto_refill"
        case sameMaterial = "same_material"
    }

    public init(state: String = "",
                filament: Int = 0,
                autoRefill: Int = 0,
                sameMaterial: [SameMaterialGroup] = [],
                enable: Int = 0,
                info: [CFSBox] = []) {
        self.state = state
        self.filament = filament
        self.autoRefill = autoRefill
        self.sameMaterial = sameMaterial
        self.enable = enable
        self.info = info
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        filament = try c.decodeIfPresent(Int.self, forKey: .filament) ?? 0
        autoRefill = try c.decodeIfPresent(Int.self, forKey: .autoRefill) ?? 0
        sameMaterial = try c.decodeIfPresent([SameMaterialGroup].self, forKey: .sameMaterial) ?? []
        enable = try c.decodeIfPresent(Int.self, forKey: .enable) ?? 0
        info = try c.decodeIfPresent([CFSBox].self, forKey: .info) ?? []
    }

    public var isAutoRefillEnabled: Bool { autoRefill == 1 }
}

// MARK: - Grouped-as-identical

/// One `same_material` entry: the slots the firmware will treat as one filament.
///
/// On the wire this is a **heterogeneous JSON array**, not an object:
/// `["101001", "0C12E1F", ["T1B", "T1D"], "PLA"]` — filament ID, colour, slot labels, material
/// type, positionally. Hence the hand-written unkeyed decoding; there are no keys to map.
public struct SameMaterialGroup: Codable, Hashable, Sendable {

    public let filamentId: String
    /// The tag's 7-character colour field, without a `#`.
    public let color: String
    /// Slot labels such as `"T1B"`.
    public let slots: [String]
    public let materialType: String

    public init(filamentId: String, color: String, slots: [String], materialType: String) {
        self.filamentId = filamentId
        self.color = color
        self.slots = slots
        self.materialType = materialType
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        filamentId = try c.decodeIfPresent(String.self) ?? ""
        color = try c.decodeIfPresent(String.self) ?? ""
        slots = try c.decodeIfPresent([String].self) ?? []
        materialType = try c.decodeIfPresent(String.self) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(filamentId)
        try c.encode(color)
        try c.encode(slots)
        try c.encode(materialType)
    }

    /// `"101001 · 0C12E1F"` — how the design labels the group.
    public var label: String { "\(filamentId) · \(color)" }
    /// `"T1B, T1D"`.
    public var slotsLabel: String { slots.joined(separator: ", ") }
    /// A group of one is not a group: the firmware lists every filament here, partnered or not.
    public var isPartnered: Bool { slots.count > 1 }
}

// MARK: - A box

/// One CFS unit. Four slots, its own temperature and humidity sensors, its own firmware.
public struct CFSBox: Codable, Hashable, Sendable, Identifiable {

    /// `"T1"`. The only field with no default — a box that cannot be named cannot be matched.
    public var boxID: String
    public var state: String
    public var filament: String
    /// Degrees Celsius, as a string, without a unit.
    public var temperature: String
    /// Relative humidity percent, as a string, without a unit. Spelled `dry_and_humidity` on the
    /// wire.
    public var humidity: String
    public var version: String
    public var sn: String
    public var list: [CFSSlot]

    public var id: String { boxID }

    private enum CodingKeys: String, CodingKey {
        case boxID, state, filament, temperature, version, sn, list
        case humidity = "dry_and_humidity"
    }

    public init(boxID: String,
                state: String = "",
                filament: String = "",
                temperature: String = "",
                humidity: String = "",
                version: String = "",
                sn: String = "",
                list: [CFSSlot] = []) {
        self.boxID = boxID
        self.state = state
        self.filament = filament
        self.temperature = temperature
        self.humidity = humidity
        self.version = version
        self.sn = sn
        self.list = list
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boxID = try c.decode(String.self, forKey: .boxID)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        filament = try c.decodeIfPresent(String.self, forKey: .filament) ?? ""
        temperature = try c.decodeIfPresent(String.self, forKey: .temperature) ?? ""
        humidity = try c.decodeIfPresent(String.self, forKey: .humidity) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        sn = try c.decodeIfPresent(String.self, forKey: .sn) ?? ""
        list = try c.decodeIfPresent([CFSSlot].self, forKey: .list) ?? []
    }

    /// `"27 °C"`, or an em dash when the box reports nothing.
    public var temperatureLabel: String { temperature.isEmpty ? "—" : "\(temperature) °C" }
    /// `"39 %RH"`.
    public var humidityLabel: String { humidity.isEmpty ? "—" : "\(humidity) %RH" }
    public var isConnected: Bool { state == "connect" }
}

// MARK: - A slot

/// One of a box's four slots.
///
/// Carries every field of the tag record — `venderId`, `filamentId`, `color`, `filamentLen`,
/// `serialNum`, `reserve` — which is what lets a slot reading resolve to the same inventory row as
/// a tag read, with no UID and no second lookup.
public struct CFSSlot: Codable, Hashable, Sendable, Identifiable {

    /// `"A"`…`"D"`.
    public var materialId: String
    public var state: Int
    /// Percent remaining, as a string. `"54"` means 54 %. Empty in an unoccupied slot.
    public var remainLen: String
    public var filamentId: String
    public var brand: String
    public var name: String
    public var materialType: String
    public var density: Double
    public var diameter: String
    public var minTemp: Int
    public var maxTemp: Int
    public var venderId: String
    /// `"#0FFFFFF"`.
    public var color: String
    /// The tag's 4-digit length code, e.g. `"0165"` for 1 kg.
    public var filamentLen: String
    public var serialNum: String
    public var reserve: String
    /// 2 when a tag was read successfully.
    public var rfid: Int
    public var editStatus: Int

    public var id: String { materialId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        materialId = try c.decodeIfPresent(String.self, forKey: .materialId) ?? ""
        state = try c.decodeIfPresent(Int.self, forKey: .state) ?? 0
        remainLen = try c.decodeIfPresent(String.self, forKey: .remainLen) ?? ""
        filamentId = try c.decodeIfPresent(String.self, forKey: .filamentId) ?? ""
        brand = try c.decodeIfPresent(String.self, forKey: .brand) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        materialType = try c.decodeIfPresent(String.self, forKey: .materialType) ?? ""
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 0
        diameter = try c.decodeIfPresent(String.self, forKey: .diameter) ?? ""
        minTemp = try c.decodeIfPresent(Int.self, forKey: .minTemp) ?? 0
        maxTemp = try c.decodeIfPresent(Int.self, forKey: .maxTemp) ?? 0
        venderId = try c.decodeIfPresent(String.self, forKey: .venderId) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        filamentLen = try c.decodeIfPresent(String.self, forKey: .filamentLen) ?? ""
        serialNum = try c.decodeIfPresent(String.self, forKey: .serialNum) ?? ""
        reserve = try c.decodeIfPresent(String.self, forKey: .reserve) ?? ""
        rfid = try c.decodeIfPresent(Int.self, forKey: .rfid) ?? 0
        editStatus = try c.decodeIfPresent(Int.self, forKey: .editStatus) ?? 0
    }

    public init(materialId: String,
                remainLen: String = "",
                filamentId: String = "",
                brand: String = "",
                name: String = "",
                materialType: String = "",
                venderId: String = "",
                color: String = "",
                filamentLen: String = "",
                serialNum: String = "",
                minTemp: Int = 0,
                maxTemp: Int = 0,
                density: Double = 0,
                diameter: String = "",
                state: Int = 0,
                rfid: Int = 0,
                editStatus: Int = 0,
                reserve: String = "") {
        self.materialId = materialId
        self.state = state
        self.remainLen = remainLen
        self.filamentId = filamentId
        self.brand = brand
        self.name = name
        self.materialType = materialType
        self.density = density
        self.diameter = diameter
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.venderId = venderId
        self.color = color
        self.filamentLen = filamentLen
        self.serialNum = serialNum
        self.reserve = reserve
        self.rfid = rfid
        self.editStatus = editStatus
    }

    // MARK: Derived

    /// A slot is loaded when it names a filament. An empty slot blanks `filamentId`, whatever else
    /// the firmware leaves behind in the other fields.
    public var isLoaded: Bool { !filamentId.isEmpty }

    /// True when the slot read an RFID tag rather than being configured by hand.
    public var hasTag: Bool { rfid == 2 }
    public var tagLabel: String { hasTag ? "RFID OK" : "No tag" }

    /// `RRGGBB`.
    public var rgbHex: String { Spool.normaliseHex(color) }

    /// Percent remaining, or nil when the slot reports none.
    public var remainingPercent: Double? {
        guard let value = Double(remainLen) else { return nil }
        return Spool.clamp(value)
    }

    /// The nominal spool weight the length code stands for, defaulting to 1 kg exactly as
    /// `GetMaterialWeight` does.
    public var netWeightGrams: Int {
        FilamentLength(rawValue: filamentLen)?.grams ?? 1000
    }

    /// The identity this slot resolves to, when it carries a tag's worth of fields.
    ///
    /// Colour is part of it: every slot of the K2 Plus dump reports `serialNum 000001`, so without
    /// colour all four collapse to one identity. See ``SpoolIdentity``.
    public var identity: SpoolIdentity? {
        guard !filamentId.isEmpty, !venderId.isEmpty, !serialNum.isEmpty else { return nil }
        return SpoolIdentity(vendorId: venderId, filamentId: filamentId,
                             colorHex: rgbHex, serialNumber: serialNum)
    }

    /// `"190–240 °C"`, or nil.
    public var temperatureLabel: String? {
        (minTemp == 0 && maxTemp == 0) ? nil : "\(minTemp)–\(maxTemp) °C"
    }

    /// `"T1A"` — the label the firmware uses in `same_material`.
    public func label(in box: CFSBox) -> String { box.boxID + materialId }

    private enum CodingKeys: String, CodingKey {
        case materialId, state, remainLen, filamentId, brand, name, materialType, density
        case diameter, minTemp, maxTemp, venderId, color, filamentLen, serialNum, reserve
        case rfid, editStatus
    }
}
