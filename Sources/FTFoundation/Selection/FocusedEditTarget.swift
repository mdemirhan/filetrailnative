// Port of apps/desktop/src/renderer/lib/focusedEditTarget.ts
import Foundation

/// What the element that has the keyboard does with typing.
public enum FocusedEditTarget: String, Sendable, Codable {
    case editableText = "editable-text"
    case readonlyText = "readonly-text"
    case nonText = "non-text"
}

/// A focused element as the rules look at it: the original reads it from the page, the native app from the responder
/// (`FocusedEditTargets` in FTAppKit).
public struct FocusedElement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case textarea
        /// An input of the given `type` ("text", "search", "checkbox"…).
        case input(type: String)
        case select
        case other
    }

    public enum Marker: String, Equatable, Sendable {
        case editable = "true"
        case readonly
        /// Any other value of `data-native-text-edit`: it decides nothing.
        case unknown
    }

    public var kind: Kind
    public var isDisabled: Bool
    public var isReadOnly: Bool
    /// The element or one above it is content-editable.
    public var isContentEditable: Bool
    /// The nearest `data-native-text-edit` marker at or above the element.
    public var marker: Marker?
    /// The element is the inline rename field, or inside it.
    public var isInlineRenameField: Bool

    public init(
        kind: Kind = .other, isDisabled: Bool = false, isReadOnly: Bool = false, isContentEditable: Bool = false,
        marker: Marker? = nil, isInlineRenameField: Bool = false
    ) {
        self.kind = kind
        self.isDisabled = isDisabled
        self.isReadOnly = isReadOnly
        self.isContentEditable = isContentEditable
        self.marker = marker
        self.isInlineRenameField = isInlineRenameField
    }
}

public enum FocusedEditTargets {
    private static let nonTextInputTypes: Set<String> = [
        "button", "checkbox", "color", "date", "datetime-local", "file", "hidden", "image", "month", "number", "radio",
        "range", "reset", "submit", "time", "week",
    ]

    /// `resolveFocusedEditTarget`.
    public static func resolve(_ element: FocusedElement?) -> FocusedEditTarget {
        guard let element else { return .nonText }
        switch element.marker {
        case .readonly?: return .readonlyText
        case .editable?: return .editableText
        default: break
        }
        switch element.kind {
        case .textarea:
            if element.isDisabled { return .nonText }
            return element.isReadOnly ? .readonlyText : .editableText
        case .input(let type):
            if element.isDisabled { return .nonText }
            if nonTextInputTypes.contains(JSString.lowercased(JSString.trimmed(type))) { return .nonText }
            return element.isReadOnly ? .readonlyText : .editableText
        case .select, .other:
            return element.isContentEditable ? .editableText : .nonText
        }
    }

    /// `focusGivesPaneTheKeyboard`: whether focus landing on the element gives a pane the keyboard. A text field inside
    /// the pane (the path bar's field, the search results' filter) takes it away instead, as the search field does:
    /// commands for the selected items (⌘D, ⌘⌫, ⇧⌘N, ⌘O…) must not act on files while someone is typing. The inline
    /// rename field is the exception: it stands in for the item it renames, and keeps its own keys.
    public static func focusGivesPaneTheKeyboard(_ element: FocusedElement?) -> Bool {
        guard let element else { return true }
        if element.isInlineRenameField { return true }
        return resolve(element) != .editableText
    }

    /// `isKeyboardOwnedFormControl`: a text field, or an enabled select, keeps the keys typed into it.
    public static func isKeyboardOwnedFormControl(_ element: FocusedElement?) -> Bool {
        guard let element else { return false }
        if resolve(element) != .nonText { return true }
        if case .select = element.kind { return !element.isDisabled }
        return false
    }
}
