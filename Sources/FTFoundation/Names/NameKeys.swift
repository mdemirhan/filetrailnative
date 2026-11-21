import Foundation

/// Keys that make two names or paths compare equal as the disk takes them for one name. Each place has
/// its own, with its own normalization; keys are compared scalar for scalar.
public enum NameKeys {
    /// A key compared byte for byte: `String`'s own `==` and hashing take NFC and NFD as equal. For a name, and for
    /// a text made to be compared (`exactDestinationKey`); a whole path as the disk spells it is a `DiskPath`, which
    /// is compared the same way and is another type, so the two are never taken for each other.
    public struct Exact: Hashable, Sendable {
        let text: String

        public init(_ text: String) {
            self.text = ExactBytes.contiguous(text)
        }

        /// The text the key was made of, to be read, never compared with `==`.
        public var string: String { text }

        public static func == (left: Exact, right: Exact) -> Bool {
            ExactBytes.equal(left.text, right.text)
        }

        public func hash(into hasher: inout Hasher) {
            ExactBytes.hash(text, into: &hasher)
        }
    }

    /// `destinationPathKey` as an `Exact`, for the sets of names a paste has claimed.
    public static func exactDestinationKey(_ path: String, caseSensitive: Bool = false) -> Exact {
        Exact(destinationPathKey(path, caseSensitive: caseSensitive))
    }

    private static func nfd(_ text: String) -> String {
        text.decomposedStringWithCanonicalMapping
    }

    private static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Copy: NFD, lowercased unless the volume is case-sensitive.
    public static func destinationPathKey(_ path: String, caseSensitive: Bool = false) -> String {
        let normalized = nfd(path)
        return caseSensitive ? normalized : JSText.lowercased(normalized)
    }

    /// Batch rename's plan: the same as `destinationPathKey`, for a name.
    public static func nameKey(_ name: String, caseSensitive: Bool) -> String {
        destinationPathKey(name, caseSensitive: caseSensitive)
    }

    /// Batch rename's execution: NFD and lowercase, whatever the volume.
    public static func looseKey(_ name: String) -> String {
        JSText.lowercased(nfd(name))
    }

    /// Undo: NFD and lowercase, whatever the volume.
    public static func placeKey(_ path: String) -> String {
        JSText.lowercased(nfd(path))
    }

    /// The folder on screen against the folder its rows, or what a write made, are in: NFD, case as it is. True when
    /// the paths differ at most in how accents are encoded, which the Mac's disks take for one name. A pane knows its
    /// folder as its listing spells it, which is the rows' spelling; a path that came through a `URL` is decomposed
    /// whatever the disk keeps, and a folder not listed yet is known by the spelling it was given.
    public static func pathsMatchIgnoringEncoding(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8) || nfd(left).utf8.elementsEqual(nfd(right).utf8)
    }

    /// Rename's self-check: NFC and lowercase. True when the names differ at most in case or encoding.
    public static func namesMatchIgnoringCase(_ left: String, _ right: String) -> Bool {
        let leftKey = JSText.lowercased(nfc(left))
        let rightKey = JSText.lowercased(nfc(right))
        return leftKey.utf8.elementsEqual(rightKey.utf8)
    }
}
