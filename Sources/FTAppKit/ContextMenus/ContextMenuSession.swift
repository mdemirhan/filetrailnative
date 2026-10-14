// Port of ItemContextMenu.tsx and SubmenuItemList.tsx (apps/desktop/src/renderer/components), built as an NSMenu
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
    var ejectLabel: String?
    var pinnedApps: [OpenWithApplication]
    var viewMode: ExplorerViewMode
    var sortBy: SortByPreference
}

/// What a chosen item does: the window carries these out.
@MainActor
protocol ContextMenuResponder: AnyObject {
    func contextMenu(perform action: ContextMenuActionID, subject: ContextMenuSubject)
    /// An app of Open With was chosen (`always`: Always Open With). `other` asks which app.
    func contextMenu(open paths: [String], with choice: OpenWithAction, kind: OpenWithKind?)
    func contextMenu(setViewMode mode: ExplorerViewMode)
    func contextMenu(sortBy field: SortByPreference)
    /// An item with a submenu was chosen: the menu only opens it. (A capture scenario chooses it to look at the
    /// submenu, which a native menu can't show in a capture.)
    func contextMenu(openedSubmenu id: ContextMenuActionID)
    func contextMenuDidOpen()
    func contextMenuDidClose()
}

/// One right-click menu: builds the `NSMenu` from the original's item lists and rules, and carries out what is
/// chosen. It stays alive as long as its menu does.
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
            subject, request.world, textEditorName: request.textEditorName, ejectLabel: request.ejectLabel)
        let hidden = ContextMenuRules.hiddenActions(subject, request.world)
        disabled = ContextMenuRules.disabledActions(request.world)
        menu = NSMenu(title: "")
        menu.delegate = self
        menu.autoenablesItems = true
        menu.minimumWidth = DesignTokens.menu.minWidth
        let palette = ThemePalette.palette(for: NSApp.effectiveAppearance.isDark ? .dark : .light)
        for item in ContextMenuItems.visibleItems(surface: subject.surface, options: options, hidden: hidden) {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let id, let label, let icon, let destructive, let hasSubmenu):
                let entry = NSMenuItem(title: label, action: #selector(choose(_:)), keyEquivalent: "")
                entry.target = self
                entry.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
                entry.image = ContextMenuGlyph.image(icon)
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
                    menu.addItem(alwaysOpenWithAlternate(after: entry))
                }
            }
        }
    }

    /// Option turns Open With into Always Open With: offered for files only, and the answer of macOS decides whether
    /// the kinds allow it.
    private var offersAlwaysOpenWith: Bool {
        let entries = request.subject.entries
        return !entries.isEmpty && entries.allSatisfy { !$0.kind.isDirectoryLike && $0.kind != .bundle }
    }

    private func alwaysOpenWithAlternate(after parent: NSMenuItem) -> NSMenuItem {
        let item = NSMenuItem(title: "Always Open With", action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(ContextMenuActionID.openWith.rawValue + ":always")
        item.image = parent.image
        item.isAlternate = true
        item.keyEquivalentModifierMask = .option
        item.submenu = openWith.makeSubmenu(always: true, session: self)
        return item
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
                submenu.addItem(item)
            }
            entry.submenu = submenu
        case .sortBy:
            let submenu = NSMenu(title: entry.title)
            for field in SortByPreference.menuOrder {
                let item = NSMenuItem(
                    title: Self.sortLabel(field), action: #selector(chooseSort(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = field.rawValue
                item.state = request.sortBy == field ? .on : .off
                submenu.addItem(item)
            }
            entry.submenu = submenu
        default:
            break
        }
    }

    static func sortLabel(_ field: SortByPreference) -> String {
        switch field {
        case .name: "Name"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .size: "Size"
        }
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
        // The item with a submenu opens it (a capture scenario "chooses" it to see the submenu); the alternate is the
        // same item.
        if id.isSubmenu {
            responder?.contextMenu(openedSubmenu: id)
            return
        }
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
        responder?.contextMenuDidClose()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
