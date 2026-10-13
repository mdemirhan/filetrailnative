// Port of destinationPathKey (packages/core/src/fs/copyPasteNames.ts), nameKey (apps/desktop/src/shared/batchRename.ts),
// looseKey (batchRenameExecution.ts), placeKey (undoPlan.ts) and namesMatchIgnoringCase (writeOperations.ts)
import Foundation

/// Keys that make two names or paths compare equal as the disk takes them for one name. Each place in
/// the original has its own, with its own normalization; keys are compared scalar for scalar.
public enum NameKeys {
    /// A key compared scalar for scalar: `String`'s own `==` and hashing take NFC and NFD as equal.
    public struct Exact: Hashable, Sendable {
        let bytes: [UInt8]

        public init(_ text: String) {
            bytes = Array(text.utf8)
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

    /// Rename's self-check: NFC and lowercase. True when the names differ at most in case or encoding.
    public static func namesMatchIgnoringCase(_ left: String, _ right: String) -> Bool {
        let leftKey = JSText.lowercased(nfc(left))
        let rightKey = JSText.lowercased(nfc(right))
        return leftKey.utf8.elementsEqual(rightKey.utf8)
    }
}
