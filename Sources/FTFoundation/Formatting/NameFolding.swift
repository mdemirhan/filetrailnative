// Names as typed text is compared with them: case aside, and an accented letter the same however it is stored
import Foundation

/// A name compared with what is typed: lowercased, with each accented letter as one character. Disks and apps store
/// some names as a letter followed by its accent, and the keyboard types the composed letter; Swift's `==` takes them
/// as equal, but a search through the text's units does not. Only the comparison uses this: a stored name is never
/// changed.
public enum NameFolding {
    /// `text` lowercased, each accented letter composed.
    public static func folded(_ text: String) -> String {
        let lowered = JSString.lowercased(text)
        return isASCII(lowered) ? lowered : lowered.precomposedStringWithCanonicalMapping
    }

    private static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 0x80 }
    }
}

/// A name as stored, told apart from others by its bytes: what is worked out for a name's units as stored (the letters
/// to mark) is kept by this. Swift's `==` takes "e\u{301}mile.txt" and "\u{E9}mile.txt" as one name, though the same
/// letters fall on other units in each.
public struct StoredName: Hashable, Sendable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public static func == (left: StoredName, right: StoredName) -> Bool {
        left.text.utf8.elementsEqual(right.text.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        var text = text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
