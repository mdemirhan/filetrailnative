import Foundation

/// What a key pressed with the file list focused does (the raw shortcut bindings that belong to the list).
public enum ContentKeyAction: Equatable, Sendable {
    /// Typing narrows the list, Backspace edits the text and Esc brings the list back.
    case filter(ListFilterKey)
    /// With the filter pinned, a typed character selects the first name that starts with the letters typed so far; nil
    /// (Esc) lets go of them.
    case typeToSelect(String?)
    /// Page Up/Down, ⌃U/⌃D; with ⇧ the selection extends.
    case page(forward: Bool, size: SelectionNavigation.PageSize, extend: Bool)
    /// Arrows, Home and End; with ⇧ the selection extends.
    case move(SelectionKey, extend: Bool)
    /// Return: Open or Rename, as the Return key setting says.
    case enter
    /// Tab: the keyboard goes to the other pane.
    case tab
    /// A command the window runs itself, as it does from the menu (a key the menu does not listen for).
    case command(ShortcutCommandID)
}

public enum ContentKeys {
    /// The page moves, by the command that has their keys.
    private static func pageMove(_ command: ShortcutCommandID?) -> (forward: Bool, size: SelectionNavigation.PageSize)?
    {
        switch command {
        case .pageUp: (false, .full)
        case .pageDown: (true, .full)
        case .halfPageUp: (false, .half)
        case .halfPageDown: (true, .half)
        default: nil
        }
    }

    /// A page move with ⇧, when ⇧ and the key are not a command's keys of their own.
    private static func shiftedPageMove(_ pressed: String?, _ resolved: ResolvedShortcuts)
        -> (forward: Bool, size: SelectionNavigation.PageSize)?
    {
        guard let pressed, let unshifted = Shortcuts.withoutShift(pressed), resolved.command(pressed: pressed) == nil
        else { return nil }
        return pageMove(resolved.commandByShortcut[unshifted])
    }

    private static func arrow(_ key: String) -> SelectionKey? {
        SelectionKey(rawValue: key)
    }

    /// The action for a key pressed with the file list focused, or nil when the list leaves the key alone.
    ///
    /// - Parameters:
    ///   - event: the key (`key` is the character it types, or a name such as "ArrowDown").
    ///   - hasEntries: the list on screen has items (arrows do nothing, and are not taken, without).
    ///   - hasSelection: an item is selected (Return does nothing, and is not taken, without).
    ///   - pinned: the list's filter is pinned: typing selects names and leaves the filter as it is.
    public static func action(
        for event: ShortcutKeyEvent, shortcuts: ResolvedShortcuts, filter: ListFilterTyping, now: TimeInterval,
        hasEntries: Bool, hasSelection: Bool, pinned: Bool = false
    ) -> ContentKeyAction? {
        let pressed = Shortcuts.fromKeyboardEvent(event)
        let command = pressed.flatMap { shortcuts.command(pressed: $0) }
        // ? opens Help from anywhere.
        if command == .openHelp { return .command(.openHelp) }
        if let move = pageMove(command) { return .page(forward: move.forward, size: move.size, extend: false) }
        // Space never starts a filter. While one is typed it is the filter's for a moment after each key, and then Quick
        // Look's; taken off Quick Look in Settings (no other command can have it), it is always the filter's.
        if event.key == " ", !event.metaKey, !event.ctrlKey, !event.altKey, !event.shiftKey, filter.isActive,
            command == nil || filter.takesSpace(at: now)
        {
            return .filter(.type(" "))
        }
        // Quick Look is the last of the raw bindings, so a filter's keys come before it.
        if let command, command != .selectAll, command != .quickLookSelection {
            return .command(command)
        }
        let plain = !event.metaKey && !event.ctrlKey && !event.altKey
        if let move = shiftedPageMove(pressed, shortcuts) {
            return .page(forward: move.forward, size: move.size, extend: true)
        }
        if event.key == "Tab", plain { return .tab }
        if event.key == "Backspace", event.altKey, !event.metaKey, !event.ctrlKey, filter.isActive {
            return .filter(.eraseWord)
        }
        if pinned, plain, Typeahead.isCharacterKey(event.key) { return .typeToSelect(event.key) }
        if plain, let key = ListFilterKey.from(key: event.key, filter: filter, now: now) { return .filter(key) }
        if pinned, plain, event.key == "Escape" { return .typeToSelect(nil) }
        if plain, hasEntries, let key = arrow(event.key) { return .move(key, extend: event.shiftKey) }
        if command == .quickLookSelection, hasSelection { return .command(.quickLookSelection) }
        if event.key == "Enter", !event.metaKey, hasSelection { return .enter }
        return nil
    }
}
