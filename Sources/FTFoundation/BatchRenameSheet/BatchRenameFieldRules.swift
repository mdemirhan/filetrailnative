// Port of NumberField, TextField's maxLength and FormatOptions' insertToken of
// apps/desktop/src/renderer/components/BatchRenameSheet.tsx
import Foundation

/// A number field of the sheet (Start numbers at, Step): what is typed is kept as typed (it may be empty for a moment);
/// the setting takes the nearest whole number allowed.
public struct BatchRenameNumberDraft: Equatable, Sendable {
    /// The most digits a number field keeps.
    public static let maxDigits = 9

    public private(set) var draft: String

    public init(value: Int) {
        draft = String(value)
    }

    /// Only the digits typed (`/[^\d]/gu` dropped), at most nine.
    public static func digits(_ typed: String) -> String {
        String(String(typed.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init)).prefix(maxDigits))
    }

    /// Something was typed: the draft keeps its digits, and the setting it gives (never less than `least`), or nil
    /// while the field is empty.
    public mutating func typed(_ text: String, least: Int) -> Int? {
        draft = Self.digits(text)
        guard let number = Int(draft) else { return nil }
        return max(least, number)
    }

    /// What the field shows: the draft while it says the setting (or is being emptied to type another); the setting
    /// when the draft is below the least allowed, or the setting was changed some other way (a preset loaded).
    public func shown(value: Int) -> String {
        if draft.isEmpty || Int(draft) == value { return draft }
        return String(value)
    }

    /// The field lost the keyboard: it shows the setting again.
    public mutating func blurred(value: Int) {
        draft = String(value)
    }
}

/// The text fields' rules.
public enum BatchRenameTextRules {
    /// `maxLength={255}`: the text settings are cut to 255 UTF-16 units.
    public static let maxLength = 255

    /// What a field keeps of `text`: its first `limit` UTF-16 units, never half a character.
    public static func limited(_ text: String, to limit: Int = maxLength) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > limit { break }
            result.append(character)
            units += length
        }
        return result
    }

    /// `insertToken`: a date token put in place of the pattern's selection (UTF-16 offsets, as the field gives them),
    /// the caret after it.
    public static func insert(_ token: String, into pattern: String, selection: Range<Int>?) -> (
        text: String, caret: Int
    ) {
        let units = Array(pattern.utf16)
        let start = min(max(0, selection?.lowerBound ?? units.count), units.count)
        let end = min(max(start, selection?.upperBound ?? start), units.count)
        let inserted = Array(token.utf16)
        let text = JSString.string(units[..<start] + inserted + units[end...])
        return (text, start + inserted.count)
    }
}
