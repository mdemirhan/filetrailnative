// Port of the file list's keys in apps/desktop/src/renderer/hooks/useExplorerShortcuts.ts (contentArrowNavigation, the page
// moves, listFilterEdit, typeahead, contentEnter) and handlePagedMove of hooks/useExplorerNavigationController.ts (:437-573)
import AppKit
import FTFoundation

/// What a view of the folder tells the keyboard about its layout: how arrows and pages move through it. The List
/// implements it here; the Icon view and the Compact List (P5-04) implement it the same way and hand their key events to
/// `ContentKeyboard`.
@MainActor
protocol LayoutNavigation: AnyObject {
    /// The view's mode: arrows move differently in each (`getNextSelectionIndex`).
    var navigationViewMode: ExplorerViewMode { get }
    /// Items on a line: icons per row (Icons), rows per column (Compact List), 1 for the List. Arrows and pages use it.
    var itemsPerLine: Int { get }
    /// What a page is made of: the extent of the viewport along the scrolling axis (the Compact List's is the width less
    /// its padding, plus the gap after its last column) and the extent of one line (a row, or a column and its gap).
    var pageGeometry: (viewportSize: Double, lineExtent: Double) { get }
    /// Whether the item at `index` shows whole as the view is scrolled now.
    func isWhollyInView(index: Int) -> Bool
    /// Scrolls along the view's axis by `delta` points, stopping at either end; whether it scrolled.
    @discardableResult
    func scroll(by delta: Double) -> Bool
}

/// The keys of a view of the folder, shared by all three.
@MainActor
final class ContentKeyboard {
    private weak var host: (any ContentPaneHost)?
    private weak var navigation: (any LayoutNavigation)?

    init(host: any ContentPaneHost, navigation: any LayoutNavigation) {
        self.host = host
        self.navigation = navigation
    }

    /// `KeyboardEvent.code` of the keys whose character ⇧ or ⌥ changes (⌘⇧] types "}"): the shortcut goes by the key.
    private static let positionCodes: [UInt16: String] = [
        29: "Digit0", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5", 22: "Digit6", 26: "Digit7",
        28: "Digit8", 25: "Digit9", 27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight", 42: "Backslash",
        41: "Semicolon", 39: "Quote", 43: "Comma", 47: "Period", 44: "Slash", 50: "Backquote",
    ]

    /// The key as the original's window key handler sees it.
    static func shortcutEvent(_ event: NSEvent) -> ShortcutKeyEvent {
        let flags = event.modifierFlags
        let named = flags.intersection([.command, .control, .option]).isEmpty ? event.characters : nil
        var key = named ?? event.charactersIgnoringModifiers ?? ""
        var code = ""
        switch event.keyCode {
        case 126: (key, code) = ("ArrowUp", "ArrowUp")
        case 125: (key, code) = ("ArrowDown", "ArrowDown")
        case 123: (key, code) = ("ArrowLeft", "ArrowLeft")
        case 124: (key, code) = ("ArrowRight", "ArrowRight")
        case 115: (key, code) = ("Home", "Home")
        case 119: (key, code) = ("End", "End")
        case 116: (key, code) = ("PageUp", "PageUp")
        case 121: (key, code) = ("PageDown", "PageDown")
        case 117: (key, code) = ("Delete", "Delete")
        case 36, 76: (key, code) = ("Enter", "Enter")
        case 48: (key, code) = ("Tab", "Tab")
        case 53: (key, code) = ("Escape", "Escape")
        case 49: (key, code) = (" ", "Space")
        case 51: (key, code) = ("Backspace", "Backspace")
        case 122: (key, code) = ("F1", "F1")
        case 120: (key, code) = ("F2", "F2")
        case 99: (key, code) = ("F3", "F3")
        case 118: (key, code) = ("F4", "F4")
        case 96: (key, code) = ("F5", "F5")
        case 97: (key, code) = ("F6", "F6")
        case 98: (key, code) = ("F7", "F7")
        case 100: (key, code) = ("F8", "F8")
        case 101: (key, code) = ("F9", "F9")
        case 109: (key, code) = ("F10", "F10")
        case 103: (key, code) = ("F11", "F11")
        case 111: (key, code) = ("F12", "F12")
        case 105: (key, code) = ("F13", "F13")
        case 107: (key, code) = ("F14", "F14")
        case 113: (key, code) = ("F15", "F15")
        case 106: (key, code) = ("F16", "F16")
        case 64: (key, code) = ("F17", "F17")
        case 79: (key, code) = ("F18", "F18")
        case 80: (key, code) = ("F19", "F19")
        case 90: (key, code) = ("F20", "F20")
        default:
            if let position = positionCodes[event.keyCode] {
                code = position
            } else if key.utf16.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII,
                scalar.properties.isAlphabetic
            {
                code = "Key" + key.uppercased()
            }
        }
        return ShortcutKeyEvent(
            key: key, code: code, metaKey: flags.contains(.command), ctrlKey: flags.contains(.control),
            altKey: flags.contains(.option), shiftKey: flags.contains(.shift))
    }

    /// Handles the key press if the list takes it; whether it did.
    func keyDown(_ event: NSEvent) -> Bool {
        guard let host, let navigation else { return false }
        let paths = host.entryPaths
        guard
            let action = ContentKeys.action(
                for: Self.shortcutEvent(event), shortcuts: host.shortcuts, filter: host.listFilter,
                now: ProcessInfo.processInfo.systemUptime, hasEntries: !paths.isEmpty,
                hasSelection: !host.selection.isEmpty)
        else { return false }
        switch action {
        case .filter(let key):
            host.applyFilterKey(key)
            return true
        case .page(let forward, let size, let extend):
            return pagedMove(forward: forward, size: size, extend: extend, host: host, navigation: navigation)
        case .move(let key, let extend):
            return move(key, extend: extend, host: host, navigation: navigation)
        case .enter:
            host.pressedReturn()
            return true
        case .tab:
            host.switchPane()
            return true
        case .command(let command):
            // A held key repeats no shortcut that starts a write (B-SEL-114): the repeat is taken and dropped.
            if !WriteStartingShortcuts.runs(command.rawValue, isRepeat: event.isARepeat) { return true }
            return host.runCommand(command)
        }
    }

    // MARK: Arrows

    private func move(
        _ key: SelectionKey, extend: Bool, host: any ContentPaneHost, navigation: any LayoutNavigation
    ) -> Bool {
        let paths = host.entryPaths
        guard !paths.isEmpty else { return false }
        let current = host.position(of: host.selection.leadPath) ?? -1
        let next = SelectionNavigation.nextIndex(
            itemCount: paths.count, currentIndex: current, key: key,
            columns: navigation.navigationViewMode == .details ? 1 : navigation.itemsPerLine,
            viewMode: navigation.navigationViewMode, gapIndex: host.selection.gapIndex)
        guard paths.indices.contains(next) else { return true }
        // The lead is brought into view by the pane when the selection reports a new one (B-SEL-046).
        select(index: next, extend: extend, host: host)
        return true
    }

    private func select(index: Int, extend: Bool, host: any ContentPaneHost) {
        let paths = host.entryPaths
        let path = paths[index]
        host.selectionChanged(extend ? host.selection.extended(entryPaths: paths, to: path) : .single(path))
    }

    // MARK: Pages

    /// Moves the selection by half a page or a page. Where it lands is on screen, the view stays still; otherwise it
    /// scrolls as far as the selection moved, so the selection keeps its place on screen. ⇧ extends the selection
    /// instead. Whether it moved (a key that cannot move is not taken, so the native scroll can happen).
    func pagedMove(
        forward: Bool, size: SelectionNavigation.PageSize, extend: Bool, host: any ContentPaneHost,
        navigation: any LayoutNavigation
    ) -> Bool {
        let paths = host.entryPaths
        guard !paths.isEmpty else { return false }
        let geometry = navigation.pageGeometry
        let current = host.position(of: host.selection.leadPath) ?? -1
        let move = SelectionNavigation.pagedLineMove(
            itemCount: paths.count, currentIndex: current,
            lines: SelectionNavigation.pageStepLineCount(
                viewportSize: geometry.viewportSize, lineExtent: geometry.lineExtent, size: size),
            itemsPerLine: max(1, navigation.itemsPerLine), direction: forward ? .forward : .backward)
        // Nothing selected: the first item, or the one next to where a removed one stood, as the arrow keys start.
        let next =
            current < 0
            ? SelectionNavigation.nextIndex(
                itemCount: paths.count, currentIndex: current, key: forward ? .down : .up, columns: 1,
                viewMode: .details, gapIndex: host.selection.gapIndex)
            : move.index
        guard paths.indices.contains(next), !(next == current && host.selection.paths.count == 1) else { return false }
        if current >= 0, !navigation.isWhollyInView(index: next) {
            navigation.scroll(by: Double(move.movedLines) * geometry.lineExtent)
        }
        select(index: next, extend: extend, host: host)
        return true
    }
}
