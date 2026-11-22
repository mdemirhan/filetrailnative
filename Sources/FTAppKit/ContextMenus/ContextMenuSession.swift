import AppKit
import FTFileSystem
import FTFoundation
import ObjectiveC

/// What the window gives for one menu.
struct ContextMenuRequest {
    var subject: ContextMenuSubject
    var world: ContextMenuWorld
    var shortcutContext: ShortcutContext
    var shortcuts: ShortcutDisplay
    var textEditorName: String
    var pinnedApps: [OpenWithApplication]
    var viewMode: ExplorerViewMode
    var sortBy: SortByPreference
    /// What the Other Pane submenu offers, while the tab shows two panes.
    var otherPane: [OtherPaneMenuItem] = []
    /// What the Folder View submenu offers, on the folder's background: View ▸ Folder View's items.
    var folderView: [OtherPaneMenuItem] = []
    /// What the Group By submenu offers, on the folder's background: View ▸ Group By's items.
    var groupBy: [OtherPaneMenuItem] = []
    /// Sort By's items under search results, which have fields of their own; empty over a folder (`sortBy`).
    var resultsSortBy: [OtherPaneMenuItem] = []
    /// The files of the Templates folder the New File submenu lists, by name in order.
    var templates: [String] = []
}

/// A New File choice as a menu item carries it.
final class NewFileChoiceBox: NSObject {
    let choice: NewFileChoice
    init(_ choice: NewFileChoice) { self.choice = choice }
}

/// One item of a submenu of commands (Other Pane, Folder View): the command it runs, whether it can now, and its key.
/// A command of nil is a line between groups.
struct OtherPaneMenuItem {
    var title: String
    var command: AppCommand?
    var enabled: Bool
    var key: MenuKeyEquivalent?
    var checked = false

    init(title: String, command: AppCommand?, enabled: Bool, key: MenuKeyEquivalent?, checked: Bool = false) {
        self.title = title
        self.command = command
        self.enabled = enabled
        self.key = key
        self.checked = checked
    }

    static let separator = OtherPaneMenuItem(title: "", command: nil, enabled: false, key: nil)
}

/// An item of the background's New File submenu.
enum NewFileChoice: Equatable {
    case textFile
    case template(String)
    case openTemplatesFolder
}

/// What a chosen item does: the window carries these out.
@MainActor
protocol ContextMenuResponder: AnyObject {
    func contextMenu(perform action: ContextMenuActionID, subject: ContextMenuSubject)
    /// An app of Open With was chosen (`always`: Always Open With). `other` asks which app.
    func contextMenu(open paths: [String], with choice: OpenWithAction, kind: OpenWithKind?)
    /// A color of the row of Finder tags was chosen.
    func contextMenu(toggleTag color: FinderTagColor, paths: [String])
    func contextMenu(setViewMode mode: ExplorerViewMode)
    func contextMenu(sortBy field: SortByPreference)
    /// An item of the Other Pane submenu was chosen, for the items the menu is for.
    func contextMenu(otherPane command: AppCommand, subject: ContextMenuSubject)
    /// An item of the New File submenu was chosen: Text File (nil), a template by its name, or the Templates folder.
    func contextMenu(newFile choice: NewFileChoice)
    func contextMenuDidOpen()
    func contextMenuDidClose()
}

/// One right-click menu: builds the `NSMenu` from the item lists and rules, and carries out what is chosen. It stays
/// alive as long as its menu does.
@MainActor
final class ContextMenuSession: NSObject, NSMenuDelegate, NSMenuItemValidation {
    let request: ContextMenuRequest
    private weak var responder: (any ContextMenuResponder)?
    private(set) var menu = NSMenu()
    private var disabled: Set<ContextMenuActionID> = []
    let openWith: OpenWithLookupModel
    private(set) var isOpen = false

    private static var sessionKey = 0

    init(request: ContextMenuRequest, responder: any ContextMenuResponder) {
        self.request = request
        self.responder = responder
        openWith = OpenWithLookupModel(paths: request.subject.paths, pinned: request.pinnedApps)
        super.init()
        build()
        // The menu is the only thing that holds the session: it ends with the menu.
        objc_setAssociatedObject(menu, &Self.sessionKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: Building

    private func build() {
        let subject = request.subject
        let options = ContextMenuRules.options(
            subject, request.world, textEditorName: request.textEditorName)
        let hidden = ContextMenuRules.hiddenActions(subject, request.world)
        disabled = ContextMenuRules.disabledActions(request.world)
        menu = NSMenu(title: "")
        menu.delegate = self
        menu.autoenablesItems = true
        menu.minimumWidth = DesignTokens.menu.minWidth
        let palette = ThemePalette.palette(for: NSApp.effectiveAppearance.isDark ? .dark : .light)
        let items = ContextMenuItems.visibleItems(surface: subject.surface, options: options, hidden: hidden)
        // The colors come after everything that changes the items: after Compress and its group, or after Rename's
        // when nothing of that group is offered and its line has gone with it.
        let tagColorsSeparator =
            items.contains(.separator(key: "separator-organize")) ? "separator-organize" : "separator-rename"
        let offersTagColors = subject.surface == .content || subject.surface == .search
        for item in items {
            switch item {
            case .separator(let key):
                menu.addItem(.separator())
                if key == tagColorsSeparator, offersTagColors {
                    addTagColors()
                    menu.addItem(.separator())
                }
            case .action(let id, let label, let icon, let destructive, let hasSubmenu):
                let entry = NSMenuItem(title: label, action: #selector(choose(_:)), keyEquivalent: "")
                entry.target = self
                entry.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
                entry.showImage(icon.image)
                if destructive {
                    entry.attributedTitle = NSAttributedString(
                        string: label,
                        attributes: [.foregroundColor: ChromeColors.color(palette.contextMenuDestructive)])
                }
                if hasSubmenu {
                    attachSubmenu(id, to: entry)
                } else {
                    applyShortcut(id, to: entry)
                }
                menu.addItem(entry)
                if id == .openWith, offersAlwaysOpenWith {
                    let alternate = alwaysOpenWithAlternate(after: entry)
                    alwaysOpenWith = alternate
                    menu.addItem(alternate)
                }
            }
        }
        // While a file operation runs, Rename's group and Compress's are both left out, and their lines with them:
        // the colors, which start no operation, close the menu then.
        if offersTagColors, tagColors == nil, !subject.entries.isEmpty {
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            addTagColors()
        }
    }

    /// Finder's row of colors. Which of them the items have is read behind the menu and marked as it comes, so a large
    /// selection or a slow disk doesn't hold it up; beyond a limit it isn't asked, and choosing still looks at the items.
    private func addTagColors() {
        let paths = request.subject.paths
        let row = TagColorsMenuRow { [weak self] color in
            self?.responder?.contextMenu(toggleTag: color, paths: paths)
        }
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("tagColors")
        item.view = row
        menu.addItem(item)
        tagColors = row
        guard paths.count <= Self.tagStateLimit else { return }
        Task { @MainActor [weak row] in
            let states = await BlockingWork.run { FinderTags.states(of: paths) }
            row?.show(states)
        }
    }

    private static let tagStateLimit = 1000
    private(set) weak var tagColors: TagColorsMenuRow?

    /// Option turns Open With into Always Open With: offered for files only, and only for one kind. The
    /// names decide before the menu opens whether it has the row at all: a hidden alternate, or one that appears under
    /// the pointer while Option is held, doesn't open its submenu. Its apps can't be chosen until macOS has answered.
    private var offersAlwaysOpenWith: Bool {
        let entries = request.subject.entries
        return !entries.isEmpty && entries.allSatisfy { !$0.kind.isDirectoryLike && $0.kind != .bundle }
            && OpenWithMenu.looksLikeOneKind(paths: request.subject.paths)
    }

    private func alwaysOpenWithAlternate(after parent: NSMenuItem) -> NSMenuItem {
        let item = NSMenuItem(title: "Always Open With", action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(ContextMenuActionID.openWith.rawValue + ":always")
        item.showImage(parent.image)
        item.isAlternate = true
        item.keyEquivalentModifierMask = .option
        item.submenu = openWith.makeSubmenu(always: true, session: self)
        return item
    }

    private weak var alwaysOpenWith: NSMenuItem?

    /// The names were wrong (the rows have already been made plain): the row says so and stays in the menu,
    /// so a pointer on it keeps its submenu.
    func openWithAnswered(_ lookup: OpenWithLookup) {
        guard !OpenWithMenu.canAlwaysOpenWith(lookup) else { return }
        alwaysOpenWith?.title = "Open With"
    }

    /// Reaching the row is what asks macOS, so Option can work before its submenu opens.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item, item === alwaysOpenWith || item.identifier?.rawValue == ContextMenuActionID.openWith.rawValue
        else { return }
        openWith.askOnce(session: self)
    }

    private func attachSubmenu(_ id: ContextMenuActionID, to entry: NSMenuItem) {
        switch id {
        case .openWith:
            entry.submenu = openWith.makeSubmenu(always: false, session: self)
        case .viewAs:
            let submenu = NSMenu(title: entry.title)
            for mode in ExplorerViewMode.menuOrder {
                let item = NSMenuItem(title: mode.menuName, action: #selector(chooseViewMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = request.viewMode == mode ? .on : .off
                // ⌘1 to ⌘4, as View has them.
                showKey(
                    of: AppCommand(
                        rawValue: "viewAs" + mode.rawValue.prefix(1).uppercased() + mode.rawValue.dropFirst()), on: item
                )
                submenu.addItem(item)
            }
            entry.submenu = submenu
        case .sortBy where !request.resultsSortBy.isEmpty:
            entry.submenu = choicesMenu(entry.title, request.resultsSortBy)
        case .sortBy:
            let submenu = NSMenu(title: entry.title)
            for field in SortByPreference.menuOrder {
                let item = NSMenuItem(
                    title: field.title, action: #selector(chooseSort(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = field.rawValue
                item.state = request.sortBy == field ? .on : .off
                showKey(of: ExplorerToolbar.sortCommand(field), on: item)
                submenu.addItem(item)
            }
            entry.submenu = submenu
        case .newFile:
            // As File ▸ New File.
            let submenu = NSMenu(title: entry.title)
            func add(_ title: String, _ choice: NewFileChoice) {
                let item = NSMenuItem(title: title, action: #selector(chooseNewFile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NewFileChoiceBox(choice)
                submenu.addItem(item)
            }
            add("Text File", .textFile)
            if !request.templates.isEmpty { submenu.addItem(.separator()) }
            for name in request.templates { add(MenuName.shortened(name), .template(name)) }
            submenu.addItem(.separator())
            add("Open Templates Folder", .openTemplatesFolder)
            entry.submenu = submenu
        case .otherPane, .folderView, .groupBy:
            let choices =
                switch id {
                case .otherPane: request.otherPane
                case .groupBy: request.groupBy
                default: request.folderView
                }
            entry.submenu = choicesMenu(entry.title, choices)
        default:
            break
        }
    }

    /// A submenu of commands, each run as it is chosen.
    private func choicesMenu(_ title: String, _ choices: [OtherPaneMenuItem]) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for choice in choices {
            guard let command = choice.command else {
                submenu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: choice.title, action: #selector(chooseOtherPane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.isEnabled = choice.enabled
            item.state = choice.checked ? .on : .off
            if let key = choice.key {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.modifiers
            }
            submenu.addItem(item)
        }
        return submenu
    }

    /// The command's key beside a submenu's item, as the menu bar shows it.
    private func showKey(of command: AppCommand?, on item: NSMenuItem) {
        guard let command, let id = ShortcutCommandID(rawValue: command.rawValue),
            let written = request.shortcuts.written(id), let key = MenuKeyEquivalent.parse(written)
        else { return }
        item.keyEquivalent = key.key
        item.keyEquivalentModifierMask = key.modifiers
    }

    @objc private func chooseNewFile(_ item: NSMenuItem) {
        guard let box = item.representedObject as? NewFileChoiceBox else { return }
        responder?.contextMenu(newFile: box.choice)
    }

    @objc private func chooseOtherPane(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let command = AppCommand(rawValue: raw) else { return }
        responder?.contextMenu(otherPane: command, subject: request.subject)
    }

    /// The shortcut beside an item, only where pressing the key would do the same now (`ShortcutPolicy`).
    private func applyShortcut(_ id: ContextMenuActionID, to entry: NSMenuItem) {
        guard
            ShortcutPolicy.contextMenuShortcutLabel(
                actionID: id.rawValue, context: request.shortcutContext, shortcuts: request.shortcuts) != nil,
            let command = ShortcutPolicy.contextMenuShortcutCommands[id.rawValue],
            let written = request.shortcuts.written(command), let key = MenuKeyEquivalent.parse(written)
        else { return }
        entry.keyEquivalent = key.key
        entry.keyEquivalentModifierMask = key.modifiers
    }

    // MARK: Choosing

    @objc private func choose(_ item: NSMenuItem) {
        guard let raw = item.identifier?.rawValue else { return }
        guard let id = ContextMenuActionID(rawValue: raw) else { return }
        // The item with a submenu only opens it; the alternate is the same item.
        if id.isSubmenu { return }
        responder?.contextMenu(perform: id, subject: request.subject)
    }

    @objc private func chooseViewMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = ExplorerViewMode(rawValue: raw) else { return }
        responder?.contextMenu(setViewMode: mode)
    }

    @objc private func chooseSort(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let field = SortByPreference(rawValue: raw) else { return }
        responder?.contextMenu(sortBy: field)
    }

    func chooseOpenWith(_ choice: OpenWithAction) {
        responder?.contextMenu(
            open: request.subject.paths, with: choice, kind: openWith.lookup?.kinds.first)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.identifier?.rawValue, let id = ContextMenuActionID(rawValue: raw) else { return true }
        return !disabled.contains(id)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, !isOpen else { return }
        isOpen = true
        responder?.contextMenuDidOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu, isOpen else { return }
        isOpen = false
        // The session and its menu hold each other: the menu lets go of it once the chosen item's action has been
        // sent, which comes after the menu closes.
        let menu = self.menu
        Task { @MainActor [self] in
            withExtendedLifetime(self) {
                objc_setAssociatedObject(menu, &Self.sessionKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        responder?.contextMenuDidClose()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
