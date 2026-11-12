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
    /// `shortcutLabel` is the shortcut already written as symbols ("⌘⌫").
    public static func format(_ label: String, shortcutLabel: String? = nil) -> String {
        guard let shortcutLabel, !shortcutLabel.isEmpty else { return label }
        return "\(label) (\(shortcutLabel))"
    }

    /// The shortcut is written as in the app's data ("Cmd+Backspace") and shown as symbols.
    public static func format(_ label: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else { return label }
        return format(label, shortcutLabel: ShortcutLabels.format(shortcut))
    }

    /// The status bar's size slider: what it sets, then the keys of Make Bigger, Make Smaller and Default Size, each
    /// with what it does ("Icon Size (⌘+ bigger, ⌘- smaller, ⌘0 default)"). A command with no key is left out.
    public static func sizeSliderTooltip(_ mode: ExplorerViewMode, shortcuts: ShortcutDisplay = .defaults) -> String? {
        let label: String
        let bigger: String
        let smaller: String
        switch mode {
        case .icons: (label, bigger, smaller) = ("Icon Size", "bigger", "smaller")
        case .list: (label, bigger, smaller) = ("Column Width", "wider", "narrower")
        case .details: return nil
        }
        let keys = [(ShortcutCommandID.increaseSize, bigger), (.decreaseSize, smaller), (.resetSize, "default")]
            .compactMap { id, effect in shortcuts.label(id).map { "\($0) \(effect)" } }
        return format(label, shortcutLabel: keys.joined(separator: ", "))
    }

    /// The item's name where it is listed or pointed at: its tooltip, and the » menu.
    public static func toolbarItemLabel(itemID: ToolbarItemID, state: ToolbarTooltipState = ToolbarTooltipState())
        -> String
    {
        switch itemID {
        case .foldersFirst:
            return state.foldersFirst == true ? "Mix Files and Folders" : "List Folders First"
        case .hidden:
            return state.hiddenFilesShown == true ? "Hide Hidden Files" : "Show Hidden Files"
        case .folderTree:
            return state.folderTreeOpen == false ? "Show Folder Tree" : "Hide Folder Tree"
        case .infoPanel:
            return state.infoPanelOpen == true ? "Hide Info Panel" : "Show Info Panel"
        case .infoRow:
            return state.infoRowOpen == true ? "Hide Info Row" : "Show Info Row"
        case .editSelection:
            if let name = state.textEditorName, !name.isEmpty {
                return "Edit in \(name)"
            }
        default:
            break
        }
        let definition = ToolbarItems.definition(itemID)
        return definition.tooltipLabel ?? definition.label
    }

    /// The item's name, then the key it has now.
    public static func toolbarItemTooltip(
        itemID: ToolbarItemID, state: ToolbarTooltipState = ToolbarTooltipState(),
        shortcuts: ShortcutDisplay = .defaults
    ) -> String {
        let command = ToolbarItems.definition(itemID).shortcutCommand
        return format(
            toolbarItemLabel(itemID: itemID, state: state), shortcut: command.flatMap { shortcuts.written($0) })
    }
}
