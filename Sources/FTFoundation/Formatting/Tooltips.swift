// Port of apps/desktop/src/renderer/lib/tooltips.ts and the placement of lib/titleTooltips.ts
import Foundation

/// What the toolbar's on/off buttons need to know to say what a click will do, and the text editor
/// Edit names, as the menus do ("Edit in TextEdit").
public struct ToolbarTooltipState: Equatable, Sendable {
    public var foldersFirst: Bool?
    public var hiddenFilesShown: Bool?
    public var folderTreeOpen: Bool?
    public var infoPanelOpen: Bool?
    public var infoRowOpen: Bool?
    public var textEditorName: String?

    public init(
        foldersFirst: Bool? = nil, hiddenFilesShown: Bool? = nil, folderTreeOpen: Bool? = nil,
        infoPanelOpen: Bool? = nil, infoRowOpen: Bool? = nil, textEditorName: String? = nil
    ) {
        self.foldersFirst = foldersFirst
        self.hiddenFilesShown = hiddenFilesShown
        self.folderTreeOpen = folderTreeOpen
        self.infoPanelOpen = infoPanelOpen
        self.infoRowOpen = infoRowOpen
        self.textEditorName = textEditorName
    }
}

/// How tooltips are worded, everywhere in the app:
///
/// - A button says the command it runs, named as the menus name it, then its shortcut in brackets:
///   "Move to Trash (⌘⌫)".
/// - A button that switches something on and off says what the click will do:
///   "Show Hidden Files (⇧⌘.)" while they are hidden, "Hide Hidden Files (⇧⌘.)" while shown.
/// - Text that can be cut short (a name, a path) carries the whole text, and a value shown in short
///   (a relative date, a permission code) carries the exact one.
public enum Tooltips {
    /// `shortcutLabel` is the shortcut already written as symbols ("⌘⌫"); the shortcut table that
    /// writes it is the commands package's.
    public static func format(_ label: String, shortcutLabel: String? = nil) -> String {
        guard let shortcutLabel, !shortcutLabel.isEmpty else { return label }
        return "\(label) (\(shortcutLabel))"
    }

    /// The name of a toolbar item whose wording depends on state, or nil for one whose name is its
    /// definition's (`tooltipLabel ?? label` in the toolbar items table). `itemID` is the toolbar
    /// item's id as the table spells it.
    public static func toolbarItemLabel(itemID: String, state: ToolbarTooltipState = ToolbarTooltipState()) -> String? {
        switch itemID {
        case "foldersFirst":
            return state.foldersFirst == true ? "Mix Files and Folders" : "List Folders First"
        case "hidden":
            return state.hiddenFilesShown == true ? "Hide Hidden Files" : "Show Hidden Files"
        case "folderTree":
            return state.folderTreeOpen == false ? "Show Folder Tree" : "Hide Folder Tree"
        case "infoPanel":
            return state.infoPanelOpen == true ? "Hide Info Panel" : "Show Info Panel"
        case "infoRow":
            return state.infoRowOpen == true ? "Hide Info Row" : "Show Info Row"
        case "editSelection":
            if let name = state.textEditorName, !name.isEmpty {
                return "Edit in \(name)"
            }
            return nil
        default:
            return nil
        }
    }
}

/// Where the app draws the tooltip of an icon-only button (port of `resolveTooltipPlacement`).
public enum TitleTooltips {
    public static let showDelay: TimeInterval = 0.6
    /// Moving straight on to another control shows its tooltip at once.
    public static let warmWindow: TimeInterval = 0.4
    public static let edgeMargin = 6.0
    public static let anchorGap = 6.0

    public struct Anchor: Equatable, Sendable {
        public var left, top, right, bottom, width: Double

        public init(left: Double, top: Double, right: Double, bottom: Double, width: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
            self.width = width
        }
    }

    public struct Size: Equatable, Sendable {
        public var width, height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Placement: Equatable, Sendable {
        public var left, top: Double
    }

    /// Under the control, centred, or above it near the bottom; always inside the viewport.
    public static func placement(anchor: Anchor, bubble: Size, viewport: Size) -> Placement {
        func clampLeft(_ left: Double) -> Double {
            max(edgeMargin, min(left, viewport.width - bubble.width - edgeMargin))
        }
        func clampTop(_ top: Double) -> Double {
            max(edgeMargin, min(top, viewport.height - bubble.height - edgeMargin))
        }
        let below = anchor.bottom + anchorGap
        let fitsBelow = below + bubble.height <= viewport.height - edgeMargin
        return Placement(
            left: clampLeft(anchor.left + anchor.width / 2 - bubble.width / 2),
            top: clampTop(fitsBelow ? below : anchor.top - anchorGap - bubble.height))
    }
}
