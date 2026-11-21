import Foundation

/// A folder's path in a saved model (a favorite, a folder's view, a visit): text to the code that reads and sets it,
/// and held as a `DiskPath`, so two models are equal only when their paths are the same byte for byte. Swift's `==`
/// on the text takes a path with an accent decomposed and the same path as the disk spells it for one path: two
/// folders a disk keeps apart would be one favorite, and a saved path respelled would count as no change and never
/// be written. In JSON it is the bare string, as the text alone is.
@propertyWrapper
public struct SavedPath: Codable, Equatable, Sendable {
    private var path: DiskPath

    public var wrappedValue: String {
        get { path.string }
        set { path = DiskPath(newValue) }
    }

    public init(wrappedValue: String) {
        path = DiskPath(wrappedValue)
    }

    public init(from decoder: any Decoder) throws {
        path = try DiskPath(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try path.encode(to: encoder)
    }
}

/// `SavedPath` for a model that may have none, which is written as JSON `null` (as `NullEncoded` writes it).
@propertyWrapper
public struct NullEncodedPath: Codable, Equatable, Sendable {
    private var path: DiskPath?

    public var wrappedValue: String? {
        get { path?.string }
        set { path = newValue.map { DiskPath($0) } }
    }

    public init(wrappedValue: String?) {
        path = wrappedValue.map { DiskPath($0) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        path = container.decodeNil() ? nil : try container.decode(DiskPath.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let path {
            try container.encode(path)
        } else {
            try container.encodeNil()
        }
    }
}

/// `SavedPath` for a model that may have none, whose key is then left out of the JSON, as a plain optional's is.
@propertyWrapper
public struct SavedPathIfAny: Equatable, Sendable {
    fileprivate var path: DiskPath?

    public var wrappedValue: String? {
        get { path?.string }
        set { path = newValue.map { DiskPath($0) } }
    }

    public init(wrappedValue: String?) {
        path = wrappedValue.map { DiskPath($0) }
    }
}

extension SavedPathIfAny: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        path = container.decodeNil() ? nil : try container.decode(DiskPath.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let path {
            try container.encode(path)
        } else {
            try container.encodeNil()
        }
    }
}

// What a model's synthesized `Codable` calls for a `SavedPathIfAny` field: these stand in for the `encodeIfPresent`
// and `decodeIfPresent` it would call for a plain optional, so the key is left out, and may be missing.
extension KeyedEncodingContainer {
    public mutating func encode(_ value: SavedPathIfAny, forKey key: Key) throws {
        try encodeIfPresent(value.path, forKey: key)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: SavedPathIfAny.Type, forKey key: Key) throws -> SavedPathIfAny {
        var value = SavedPathIfAny(wrappedValue: nil)
        value.path = try decodeIfPresent(DiskPath.self, forKey: key)
        return value
    }
}
