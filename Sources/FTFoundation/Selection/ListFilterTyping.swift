import Foundation

/// Typing in the file list narrows it: the text typed so far. While there is any, Space is part of it ("my doc"),
/// and Quick Look is ⌘Y until Esc ends the filter.
public struct ListFilterTyping: Equatable, Sendable {
    public private(set) var query = ""

    public init() {}

    public var isActive: Bool { !query.isEmpty }

    public mutating func type(_ text: String) {
        query += text
    }

    /// Backspace takes the last character back, the whole of it: an emoji is never left half there.
    public mutating func eraseCharacter() {
        if !query.isEmpty { query.removeLast() }
    }

    /// ⌥⌫ takes the last word back: what ends the text that is no letter or digit, then the letters and digits
    /// before it.
    public mutating func eraseWord() {
        while let last = query.last, !last.isLetter, !last.isNumber { query.removeLast() }
        while let last = query.last, last.isLetter || last.isNumber { query.removeLast() }
    }

    /// The filter field of the search results sets the whole text at once.
    public mutating func set(_ text: String) {
        query = text
    }

    /// Esc, the ✕, or leaving the folder.
    public mutating func clear() {
        query = ""
    }
}

/// Typing in a list whose filter is pinned: the letters typed in quick succession pick the first name that starts with
/// them, as the sidebar's type-to-select does. Nothing of them shows; a pause starts over.
public struct ListTypeToSelect: Equatable, Sendable {
    /// A pause this long after a key starts the next one afresh.
    public static let resetAfter: TimeInterval = 1

    public private(set) var query = ""
    private var lastInputAt: TimeInterval?

    public init() {}

    /// Adds `text` to the letters typed so far, or starts again after a pause; returns the letters to look for.
    public mutating func type(_ text: String, at now: TimeInterval) -> String {
        if let lastInputAt, now - lastInputAt >= Self.resetAfter { query = "" }
        lastInputAt = now
        query += text
        return query
    }

    /// Esc, or the list changed under the letters.
    public mutating func clear() {
        query = ""
        lastInputAt = nil
    }

    /// The first of `entries` whose name starts with `query`, ignoring case and accents; names beyond ASCII are folded
    /// through `cache` when one is given.
    public static func match<T: ListFilterEntry>(in entries: [T], query: String, cache: FoldedNameCache? = nil) -> T? {
        guard let matcher = NameMatcher(JSString.trimmed(query), mode: .contains) else { return nil }
        return entries.first { matcher.isPrefix(of: $0.name, cache: cache) }
    }
}

/// What a key does in the file list while a filter is, or can be, typed.
public enum ListFilterKey: Equatable, Sendable {
    case type(String)
    case erase
    /// ⌥⌫: the last word.
    case eraseWord
    case clear

    /// The key as the file list reads it, or nil when it is none of the filter's: `key` is the key's name
    /// ("Backspace", "Escape") or the character it types (" " for Space). No ⌘, ⌃ or ⌥ may be held.
    public static func from(key: String, filter: ListFilterTyping) -> ListFilterKey? {
        if filter.isActive {
            if key == "Backspace" { return .erase }
            if key == "Escape" { return .clear }
            if key == " " { return .type(" ") }
        }
        if Typeahead.isCharacterKey(key) { return .type(key) }
        return nil
    }
}
