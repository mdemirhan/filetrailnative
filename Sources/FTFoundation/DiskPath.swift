import Foundation

/// A path as the disk spells it: equal to another, hashed and ordered by its UTF-8 bytes. Swift's `==` and hashing
/// on `String` take the NFC and NFD spellings of a name as equal, and a disk can keep both as two names, so a path
/// used as a key or compared with another is held in this type. It changes nothing in the text: no slash is taken
/// out and no accent respelled. In JSON it is the bare string. A path comes from a listing or from `realpath`; one
/// that came from a `URL`, was typed or was saved is respelled as its disk has it before it is compared with those.
public struct DiskPath: Hashable, Comparable, Sendable {
    /// The path's text, held as contiguous UTF-8: what a C call and the screen are given.
    public let string: String

    @inlinable
    public init(_ string: String) {
        self.string = ExactBytes.contiguous(string)
    }

    @inlinable
    public static func == (left: DiskPath, right: DiskPath) -> Bool {
        ExactBytes.equal(left.string, right.string)
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        ExactBytes.hash(string, into: &hasher)
    }

    /// Byte order, which is the order of the Unicode scalars: a composed "é" comes after "e" with its accent apart.
    @inlinable
    public static func < (left: DiskPath, right: DiskPath) -> Bool {
        ExactBytes.precedes(left.string, right.string)
    }
}

extension DiskPath: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

extension DiskPath: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    // Disfavored so that `paths.map(DiskPath.init)` means `init(_:)`: both take a `String`.
    @_disfavoredOverload
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension DiskPath: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { string }
    public var debugDescription: String { string.debugDescription }
}

// MARK: Parts

/// A path's parts, by `NodePath`'s rules; the bytes of every part are kept.
extension DiskPath {
    /// The last part: the item's name. "" for "/".
    public var name: String { NodePath.basename(string) }

    /// The folder the path is in. "/" for "/" and for what is at the top of the disk; "." for a name alone.
    public var parent: DiskPath { DiskPath(NodePath.dirname(string)) }

    /// The path of `name` in this folder, joined as `NodePath.join` joins.
    public func appending(_ name: String) -> DiskPath { DiskPath(NodePath.join(string, name)) }

    /// Whether the path is somewhere inside `folder`, part by part: "/a/b" is inside "/a" and "/ab" is not. Every
    /// other absolute path is inside "/"; nothing is inside itself or inside "". The folder is spelled as a listing
    /// spells it, with no slash at its end: "/a/b" is not inside "/a/".
    public func isInside(_ folder: DiskPath) -> Bool {
        var path = string
        var folder = folder.string
        return path.withUTF8 { path in
            folder.withUTF8 { folder in
                let slash = UInt8(ascii: "/")
                guard path.count > folder.count, !folder.isEmpty, path.starts(with: folder) else { return false }
                return path[folder.count] == slash || (folder.count == 1 && folder[0] == slash)
            }
        }
    }

    /// Whether the path is `folder` or somewhere inside it.
    public func isAtOrInside(_ folder: DiskPath) -> Bool {
        self == folder || isInside(folder)
    }
}

// MARK: Exact bytes

/// A string's exact UTF-8, compared and hashed: the one place the two spellings of a name are told apart, for a
/// path (`DiskPath`) and for a name or another text that isn't a path (`NameKeys.Exact`).
@usableFromInline
enum ExactBytes {
    /// The string held as contiguous UTF-8, so its bytes are read with no copy each time: a string that came through
    /// Foundation (`JSONSerialization`, a `URL`) holds UTF-16.
    @inlinable
    static func contiguous(_ text: String) -> String {
        var text = text
        text.makeContiguousUTF8()
        return text
    }

    @inlinable
    static func equal(_ left: String, _ right: String) -> Bool {
        var left = left
        var right = right
        return left.withUTF8 { left in
            right.withUTF8 { right in
                left.count == right.count
                    && (left.isEmpty || memcmp(left.baseAddress, right.baseAddress, left.count) == 0)
            }
        }
    }

    /// Whether `left` comes before `right` byte by byte, a text before any longer one that starts with it.
    @inlinable
    static func precedes(_ left: String, _ right: String) -> Bool {
        var left = left
        var right = right
        return left.withUTF8 { left in
            right.withUTF8 { right in
                let shared = min(left.count, right.count)
                let order = shared == 0 ? 0 : memcmp(left.baseAddress, right.baseAddress, shared)
                return order < 0 || (order == 0 && left.count < right.count)
            }
        }
    }

    /// The bytes, then a byte no UTF-8 holds, so two texts hashed one after the other don't run together.
    @inlinable
    static func hash(_ text: String, into hasher: inout Hasher) {
        var text = text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        hasher.combine(0xFF as UInt8)
    }
}
