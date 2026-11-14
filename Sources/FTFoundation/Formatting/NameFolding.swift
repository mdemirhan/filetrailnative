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
