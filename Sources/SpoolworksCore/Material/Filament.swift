import Foundation

// MARK: - JSONValue

/// A loss-free stand-in for any JSON value, used to carry keys this port does not model.
///
/// Newtonsoft's `JObject` (what the Windows app parses into) is order-preserving and loss-free, so
/// the C# code can round-trip a printer-generated file it does not understand. `Codable` cannot:
/// any key absent from a `struct` is silently dropped on re-encode. `JSONValue` is how the models
/// below keep that guarantee — every unmodelled key is captured here and re-emitted verbatim.
///
/// `int` and `double` are separate cases so that `0` does not come back as `0.0`.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        // Int before Double: `0` must not become `0.0`.
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    /// The value as a `String`, whether it arrived quoted or not. `nil` for containers and null.
    public var stringValue: String? {
        switch self {
        case let .string(v): return v
        case let .int(v): return String(v)
        case let .double(v): return String(v)
        case let .bool(v): return v ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// The value as a `Double`, whether it arrived quoted or not.
    public var doubleValue: Double? {
        switch self {
        case let .double(v): return v
        case let .int(v): return Double(v)
        case let .string(v): return Double(v)
        default: return nil
        }
    }

    /// The value as an `Int`, whether it arrived quoted or not. Truncates a fractional double.
    public var intValue: Int? {
        switch self {
        case let .int(v): return v
        // Int(Double) TRAPS when the value does not fit; a database carrying 1e300 would abort
        // the process rather than fail to decode. Int(exactly:) after truncation returns nil.
        case let .double(v): return v.isFinite ? Int(exactly: v.rounded(.towardZero)) : nil
        case let .string(v):
            if let direct = Int(v) { return direct }
            guard let d = Double(v), d.isFinite else { return nil }
            return Int(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }

    /// The value as a `Bool`. Accepts JSON booleans and the `"0"`/`"1"` spelling used in `kvParam`.
    public var boolValue: Bool? {
        switch self {
        case let .bool(v): return v
        case let .int(v): return v != 0
        case let .string(v):
            switch v.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

/// Coding key that carries any string, so unmodelled keys can be enumerated and re-emitted.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(_ key: some CodingKey) { self.stringValue = key.stringValue }
}

// MARK: - MaterialBase

/// The `base` object of a material record — the actual filament description.
///
/// All 18 keys are present in all 133 shipped records across `db/k1.json`, `db/k2.json` and
/// `db/hi.json`, with consistent JSON types. They are nevertheless decoded defensively: only the
/// four identity strings are required, everything else falls back to a documented default, so a
/// record that is merely *sparse* still loads.
///
/// ## Sparse records are re-encoded sparse
///
/// A fallback is a reading convenience, never a fact about the printer. `minTemp` absent means
/// "this record does not say", and the decoder's `0` is a placeholder — but ``encode(to:)`` used
/// to write all 18 keys unconditionally, so a record that arrived without `minTemp`/`maxTemp`/
/// `density` was written back as `minTemp: 0, maxTemp: 0, density: 0, colors: []` and *that* is
/// what got uploaded to a printer as real settings. ``presentKeys`` records which keys the source
/// actually carried; `encode` re-emits only those, plus any the caller has since assigned.
///
/// Traps this type exists to get right (SPEC/02-material-db.md §9.2):
/// - `diameter` is a **String** (`"1.75"`) while `density` is a **number** (`1.24`). Easy to swap.
///   Both are decoded leniently — either spelling is accepted — and re-encoded in the wire form the
///   printer sends.
/// - `id` is **not** always numeric (`"E1001"`, `"P1001"`) and is zero-padded (`"00001"`). Never Int.
/// - `meterialType` is misspelled on the wire and must stay misspelled, or the printer rejects the
///   file. The Swift property is spelled correctly; ``CodingKeys`` bridges the two.
public struct MaterialBase: Codable, Hashable, Sendable {
    /// `base.id` — 5 characters, zero-padded, not necessarily numeric.
    public var id: String
    /// `base.brand`, e.g. `Creality`, `Generic`, `eSUN`, `Polymaker`.
    public var brand: String
    /// `base.name`, the marketing name, e.g. `Hyper PLA`.
    public var name: String
    /// `base.meterialType` (sic) — the polymer family, e.g. `PLA`, `PETG-CF`.
    public var materialType: String
    /// Hex RGB strings with a `#` prefix, lower-case. Always exactly one element in shipped data.
    public var colors: [String] { didSet { markPresent(.colors) } }
    /// g/cm³. A JSON **number**.
    public var density: Double { didSet { markPresent(.density) } }
    /// mm. A JSON **string** — always `"1.75"` in shipped data.
    public var diameter: String { didSet { markPresent(.diameter) } }
    public var costPerMeter: Int { didSet { markPresent(.costPerMeter) } }
    public var weightPerMeter: Int { didSet { markPresent(.weightPerMeter) } }
    /// UI sort weight, descending. Not unique — `4910` is duplicated in all three shipped files.
    public var rank: Int { didSet { markPresent(.rank) } }
    /// °C nozzle minimum.
    public var minTemp: Int { didSet { markPresent(.minTemp) } }
    /// °C nozzle maximum.
    public var maxTemp: Int { didSet { markPresent(.maxTemp) } }
    public var isSoluble: Bool { didSet { markPresent(.isSoluble) } }
    public var isSupport: Bool { didSet { markPresent(.isSupport) } }
    /// Units unresolved — only `0` and `40` observed and no code reads it (SPEC/02 OPEN QUESTION 1).
    public var shrinkageRate: Int { didSet { markPresent(.shrinkageRate) } }
    /// °C glass transition.
    public var softeningTemp: Int { didSet { markPresent(.softeningTemp) } }
    public var dryingTemp: Int { didSet { markPresent(.dryingTemp) } }
    /// Hours.
    public var dryingTime: Int { didSet { markPresent(.dryingTime) } }

    /// Keys present in the source JSON that this struct does not model, preserved verbatim so a
    /// decode/encode cycle is loss-free. Printer captures carry `createTime`, `status` and
    /// `userInfo` here (the Windows cloud path strips them, `Utils.cs:867`).
    public var additionalFields: [String: JSONValue]

    /// Which of the 18 modelled keys ``encode(to:)`` will write.
    ///
    /// Seeded from the source JSON on decode (so a sparse record stays sparse — see the type
    /// doc) and to *all* keys for a record built in memory (a hand-built record has no absent
    /// keys, only values). Property observers add a key the moment it is assigned, so editing
    /// `minTemp` on a record that lacked it does write it out. The four identity keys are
    /// always present: the decoder requires them.
    public private(set) var presentKeys: Set<String>

    /// Modelled keys the source carried as an explicit `null`. They are in ``presentKeys`` —
    /// the record did say something about them — but what it said was "no value", and that is
    /// what goes back out. Without this a `"minTemp": null` decoded to the fallback `0` and was
    /// re-emitted as a concrete `0`: the fabricated printer setting ``presentKeys`` exists to
    /// prevent, through a different door. Assigning the property clears it, via ``markPresent``.
    private var nullKeys: Set<String> = []

    /// Every modelled key. The default ``presentKeys`` for an in-memory record.
    public static let allModelledKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    /// The four identity keys the decoder requires and the encoder therefore always writes.
    public static let requiredKeys: Set<String> = Set(
        [CodingKeys.id, .brand, .name, .materialType].map(\.rawValue))

    private mutating func markPresent(_ key: CodingKeys) {
        presentKeys.insert(key.rawValue)
        nullKeys.remove(key.rawValue)
    }

    public init(id: String, brand: String, name: String, materialType: String,
                colors: [String] = ["#ffffff"], density: Double = 1.24, diameter: String = "1.75",
                costPerMeter: Int = 0, weightPerMeter: Int = 0, rank: Int = 0,
                minTemp: Int = 190, maxTemp: Int = 240,
                isSoluble: Bool = false, isSupport: Bool = false,
                shrinkageRate: Int = 0, softeningTemp: Int = 0,
                dryingTemp: Int = 0, dryingTime: Int = 0,
                additionalFields: [String: JSONValue] = [:],
                presentKeys: Set<String> = MaterialBase.allModelledKeys) {
        // Assigned last, below: property observers must not widen an explicitly narrowed set.
        self.presentKeys = []
        self.id = id
        self.brand = brand
        self.name = name
        self.materialType = materialType
        self.colors = colors
        self.density = density
        self.diameter = diameter
        self.costPerMeter = costPerMeter
        self.weightPerMeter = weightPerMeter
        self.rank = rank
        self.minTemp = minTemp
        self.maxTemp = maxTemp
        self.isSoluble = isSoluble
        self.isSupport = isSupport
        self.shrinkageRate = shrinkageRate
        self.softeningTemp = softeningTemp
        self.dryingTemp = dryingTemp
        self.dryingTime = dryingTime
        self.additionalFields = additionalFields
        self.presentKeys = presentKeys.intersection(MaterialBase.allModelledKeys)
            .union(MaterialBase.requiredKeys)
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id, brand, name
        /// The wire key keeps Creality's misspelling; the Swift property does not.
        case materialType = "meterialType"
        case colors, density, diameter, costPerMeter, weightPerMeter, rank
        case minTemp, maxTemp, isSoluble, isSupport
        case shrinkageRate, softeningTemp, dryingTemp, dryingTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }
        // A key counts as present when the source object carries it at all — including
        // explicitly as `null`, which `decodeIfPresent` reports as nil. `allKeys` is the honest
        // source of truth for "what did this record actually say". Applied at the very end of
        // this initializer, so the assignments in between cannot widen it.
        let sourceKeys = Set(c.allKeys.map(\.stringValue))
        presentKeys = []
        nullKeys = Set(try c.allKeys.filter { k in
            guard MaterialBase.allModelledKeys.contains(k.stringValue) else { return false }
            return try c.decodeNil(forKey: k)
        }.map(\.stringValue))

        func raw(_ k: CodingKeys) throws -> JSONValue? { try c.decodeIfPresent(JSONValue.self, forKey: key(k)) }
        func string(_ k: CodingKeys) throws -> String? { try raw(k)?.stringValue }
        func int(_ k: CodingKeys, _ fallback: Int) throws -> Int { try raw(k)?.intValue ?? fallback }
        func bool(_ k: CodingKeys, _ fallback: Bool) throws -> Bool { try raw(k)?.boolValue ?? fallback }

        // Identity fields are required: a record without them cannot be looked up, edited or
        // written to a tag, so accepting it would only defer the failure to somewhere less obvious.
        func required(_ k: CodingKeys) throws -> String {
            guard let v = try string(k) else {
                throw DecodingError.keyNotFound(key(k), .init(
                    codingPath: c.codingPath,
                    debugDescription: "material base is missing required key '\(k.rawValue)'"))
            }
            return v
        }

        id = try required(.id)
        brand = try required(.brand)
        name = try required(.name)
        materialType = try required(.materialType)
        colors = try c.decodeIfPresent([String].self, forKey: key(.colors)) ?? []
        // density is a number and diameter a string on the wire; both are read leniently so a
        // quoted density or an unquoted diameter still lands in the right place.
        density = try raw(.density)?.doubleValue ?? 0
        diameter = try string(.diameter) ?? "1.75"
        costPerMeter = try int(.costPerMeter, 0)
        weightPerMeter = try int(.weightPerMeter, 0)
        rank = try int(.rank, 0)
        minTemp = try int(.minTemp, 0)
        maxTemp = try int(.maxTemp, 0)
        isSoluble = try bool(.isSoluble, false)
        isSupport = try bool(.isSupport, false)
        shrinkageRate = try int(.shrinkageRate, 0)
        softeningTemp = try int(.softeningTemp, 0)
        dryingTemp = try int(.dryingTemp, 0)
        dryingTime = try int(.dryingTime, 0)

        let modelled = MaterialBase.allModelledKeys
        var extras: [String: JSONValue] = [:]
        for k in c.allKeys where !modelled.contains(k.stringValue) {
            extras[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        additionalFields = extras

        presentKeys = modelled.intersection(sourceKeys).union(MaterialBase.requiredKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }
        /// Writes `value` only if the source carried this key, or the caller has since set it.
        /// See ``presentKeys`` — emitting a fallback would fabricate a printer setting.
        func emit<T: Encodable>(_ value: T, _ k: CodingKeys) throws {
            guard presentKeys.contains(k.rawValue) else { return }
            if nullKeys.contains(k.rawValue) {
                try c.encodeNil(forKey: key(k))
            } else {
                try c.encode(value, forKey: key(k))
            }
        }
        // The four identity keys are required on decode and so are always in `presentKeys`;
        // they go through the same gate purely so there is one rule, not two.
        try emit(id, .id)
        try emit(brand, .brand)
        try emit(name, .name)
        try emit(materialType, .materialType)
        try emit(colors, .colors)
        try emit(density, .density)
        try emit(diameter, .diameter)
        try emit(costPerMeter, .costPerMeter)
        try emit(weightPerMeter, .weightPerMeter)
        try emit(rank, .rank)
        try emit(minTemp, .minTemp)
        try emit(maxTemp, .maxTemp)
        try emit(isSoluble, .isSoluble)
        try emit(isSupport, .isSupport)
        try emit(shrinkageRate, .shrinkageRate)
        try emit(softeningTemp, .softeningTemp)
        try emit(dryingTemp, .dryingTemp)
        try emit(dryingTime, .dryingTime)

        // Unmodelled keys last, and never allowed to shadow a modelled one.
        for (k, v) in additionalFields where !MaterialBase.allModelledKeys.contains(k) {
            try c.encode(v, forKey: AnyCodingKey(stringValue: k))
        }
    }
}

// MARK: - Filament

/// One element of `result.list` — a complete filament record.
///
/// ## Why this replaces the C# `Filament`
///
/// `Windows/CFS-RFID/Filament.cs` is five strings, the fifth (`FilamentParam`) being the entire
/// list element re-serialised as an opaque JSON string; the other four are a denormalised cache of
/// `base.name`, `base.id`, `base.brand` and `base.meterialType`. That design forces every write to
/// update two representations and keep them in sync by hand — which the C# then fails to do
/// (`UpdateForm.cs:156` replaces the blob while leaving the four cached fields stale, so a renamed
/// material shows its old name until the next full reload).
///
/// This port models the record once. `id`/`name`/`vendor`/`materialType` are *computed* views onto
/// ``base``, so the cache cannot drift because there is no cache. Nothing is stored as a JSON
/// string, which removes an entire class of re-parse failures.
///
/// Round-trip fidelity is preserved instead by ``additionalFields`` here and in ``MaterialBase``.
public struct Filament: Codable, Hashable, Identifiable, Sendable {
    /// Always `"3.0.0"` in shipped data.
    public var engineVersion: String
    /// Internal printer model code — see ``PrinterType/printerIntName``.
    public var printerIntName: String
    /// mm, as strings. Always `["0.4"]` in shipped data (hard-coded at every Windows call site).
    public var nozzleDiameter: [String]

    /// The slicer profile: a flat `String → String` map.
    ///
    /// Kept as a dictionary and never a struct, deliberately: key *sets* vary per record — 90 keys
    /// (71 records), 91 (31), 92 (19), 93 (11) and 100 (1, `k1.json` id `01002`). Values are always
    /// JSON strings even when logically numeric or boolean (`"190"`, `"1.24"`, `"0"`, `"1"`), and
    /// the literal `"nil"` means "unset / inherit" — it must round-trip as that string and must not
    /// be mapped to Swift `nil`.
    ///
    /// `[String: String]` loses key order. The shipped files are alphabetically ordered, and
    /// ``MaterialDatabase`` encodes with `.sortedKeys`, so the order is reproduced on write.
    public var kvParam: [String: String]

    /// The material description proper.
    public var base: MaterialBase

    /// Keys at the record level that this struct does not model, preserved verbatim.
    public var additionalFields: [String: JSONValue]

    // Convenience views onto `base`, matching the four C# cached properties. Read/write.
    /// `base.id`. `Identifiable` conformance, so lists and pickers work directly.
    public var id: String {
        get { base.id }
        set { base.id = newValue }
    }
    /// `base.name`.
    public var name: String {
        get { base.name }
        set { base.name = newValue }
    }
    /// `base.brand`.
    public var vendor: String {
        get { base.brand }
        set { base.brand = newValue }
    }
    /// `base.meterialType`.
    public var materialType: String {
        get { base.materialType }
        set { base.materialType = newValue }
    }

    public init(engineVersion: String = "3.0.0",
                printerIntName: String,
                nozzleDiameter: [String] = ["0.4"],
                kvParam: [String: String] = [:],
                base: MaterialBase,
                additionalFields: [String: JSONValue] = [:]) {
        self.engineVersion = engineVersion
        self.printerIntName = printerIntName
        self.nozzleDiameter = nozzleDiameter
        self.kvParam = kvParam
        self.base = base
        self.additionalFields = additionalFields
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case engineVersion, printerIntName, nozzleDiameter, kvParam, base
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }

        engineVersion = try c.decodeIfPresent(String.self, forKey: key(.engineVersion)) ?? ""
        printerIntName = try c.decodeIfPresent(String.self, forKey: key(.printerIntName)) ?? ""
        nozzleDiameter = try c.decodeIfPresent([String].self, forKey: key(.nozzleDiameter)) ?? []
        // Strict `[String: String]`: every one of the 12 082 values in the shipped databases is a
        // JSON string, so a non-string here means the file is not what we think it is. Reporting it
        // beats coercing it and losing the distinction between `"190"` and `190` on the way out.
        // This strictness is deliberate and stays. What changed is its blast radius:
        // `MaterialDatabaseFile.Result` decodes `list` element-wise, so a throw here costs the
        // caller this one record — reported in `result.recordFailures` — rather than the whole
        // catalogue. Same for `nozzleDiameter`, `colors`, and the four required identity strings.
        kvParam = try c.decodeIfPresent([String: String].self, forKey: key(.kvParam)) ?? [:]
        base = try c.decode(MaterialBase.self, forKey: key(.base))

        let modelled = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        for k in c.allKeys where !modelled.contains(k.stringValue) {
            extras[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        additionalFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }
        try c.encode(engineVersion, forKey: key(.engineVersion))
        try c.encode(printerIntName, forKey: key(.printerIntName))
        try c.encode(nozzleDiameter, forKey: key(.nozzleDiameter))
        try c.encode(kvParam, forKey: key(.kvParam))
        try c.encode(base, forKey: key(.base))

        let modelled = Set(CodingKeys.allCases.map(\.rawValue))
        for (k, v) in additionalFields where !modelled.contains(k) {
            try c.encode(v, forKey: AnyCodingKey(stringValue: k))
        }
    }
}

public extension Filament {
    /// Re-derives the two `kvParam` keys the Windows add-form treats as derived from the material
    /// identity (`FilamentForm.cs:279-286`). Call after changing ``vendor`` or ``materialType`` if
    /// the slicer profile should follow.
    mutating func syncDerivedKVParams() {
        kvParam["filament_vendor"] = vendor
        kvParam["filament_type"] = materialType
    }
}
