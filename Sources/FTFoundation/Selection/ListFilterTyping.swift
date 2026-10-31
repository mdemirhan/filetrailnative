// Port of the list-filter state of apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts (:579-683)
import Foundation

/// Typing in the file list narrows it: the text typed so far, and when the last character went in (Space is part of the
/// text for a moment after each one, and Quick Look otherwise).
public struct ListFilterTyping: Equatable, Sendable {
    public private(set) var query = ""
    /// When the last character was typed, erased or the text set; nil for a filter restored with a tab, whose Space is
    /// Quick Look at once (B-SEL-085).
    public private(set) var lastInputAt: TimeInterval?

    public init() {}

    public init(restoring query: String) {
        self.query = query
    }

    public var isActive: Bool { !query.isEmpty }

    /// `typeIntoListFilter`.
    public mutating func type(_ text: String, at now: TimeInterval) {
        lastInputAt = now
        query += text
    }

    /// `eraseListFilterCharacter`: Backspace takes the last character (a UTF-16 unit, as `slice(0, -1)` does) back.
    public mutating func eraseCharacter(at now: TimeInterval) {
        lastInputAt = now
        var units = Array(query.utf16)
        if !units.isEmpty { units.removeLast() }
        query = JSString.string(units)
    }

    /// `setListFilter`: the filter field of the search results sets the whole text at once.
    public mutating func set(_ text: String, at now: TimeInterval) {
        lastInputAt = now
        query = text
    }

    /// `clearListFilter`: Esc, the ✕, or leaving the folder.
    public mutating func clear() {
        query = ""
    }

    /// `listFilterTakesSpace`: Space is part of the text while typing is under way ("my doc"); after a pause it is Quick
    /// Look again.
    public func takesSpace(at now: TimeInterval) -> Bool {
        guard !query.isEmpty, let lastInputAt else { return false }
        return now - lastInputAt < ListFilter.spaceWindow
    }
}

/// What a key does in the file list while a filter is, or can be, typed (the `listFilterEdit` and `typeahead` raw
/// shortcuts of `useExplorerShortcuts.ts`).
public enum ListFilterKey: Equatable, Sendable {
    case type(String)
    case erase
    case clear

    /// The key as the file list reads it, or nil when it is none of the filter's: `key` is a DOM key name ("Backspace",
    /// "Escape", " ", or the character typed). No ⌘, ⌃ or ⌥ may be held.
    public static func from(key: String, filter: ListFilterTyping, now: TimeInterval) -> ListFilterKey? {
        if filter.isActive {
            if key == "Backspace" { return .erase }
            if key == "Escape" { return .clear }
            if key == " ", filter.takesSpace(at: now) { return .type(" ") }
        }
        if Typeahead.isCharacterKey(key) { return .type(key) }
        return nil
    }
}
