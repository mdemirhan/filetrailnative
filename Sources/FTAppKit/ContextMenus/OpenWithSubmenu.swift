// Port of the Open With parts of useExplorerActions.ts (contextMenuOpenWith) and openWith.ts, as NSMenu submenus
import AppKit
import FTFileSystem
import FTFoundation

/// Asks macOS which apps can open the items once the Open With submenu first opens in a menu, not when the menu
/// opens; the submenu fills in when the answer comes (`OpenWithMenu` lists the pinned apps until then). What was
/// asked for belongs to the menu it was asked in.
@MainActor
final class OpenWithLookupModel {
    private let paths: [String]
    private let pinned: [OpenWithApplication]
    private(set) var lookup: OpenWithLookup?
    private var asked = false
    private var submenus: [(menu: NSMenu, always: Bool, delegate: OpenWithSubmenuDelegate)] = []
    /// How the answer is got; tests give their own.
    var ask: @Sendable ([String], [String]) async -> OpenWithLookup = { paths, pinned in
        await SystemActions.openWithApplications(paths: paths, pinnedAppPaths: pinned)
    }

    init(paths: [String], pinned: [OpenWithApplication]) {
        self.paths = paths
        self.pinned = pinned
    }

    func makeSubmenu(always: Bool, session: ContextMenuSession) -> NSMenu {
        let menu = NSMenu(title: always ? "Always Open With" : "Open With")
        let delegate = OpenWithSubmenuDelegate(model: self, always: always, session: session)
        menu.delegate = delegate
        submenus.append((menu, always, delegate))
        fill(menu, always: always, session: session)
        return menu
    }

    /// Called as a submenu is about to show.
    func opened(_ menu: NSMenu, always: Bool, session: ContextMenuSession) {
        fill(menu, always: always, session: session)
        guard !asked else { return }
        asked = true
        let paths = paths
        let pinnedPaths = pinned.map(\.appPath)
        let ask = ask
        Task { @MainActor [weak self, weak session] in
            let answer = await ask(paths, pinnedPaths)
            guard let self, let session else { return }
            self.lookup = answer
            for entry in self.submenus { self.fill(entry.menu, always: entry.always, session: session) }
        }
    }

    /// The rows of the list: the default app, the pinned apps and the rest, then Other….
    func fill(_ menu: NSMenu, always: Bool, session: ContextMenuSession) {
        menu.removeAllItems()
        let alwaysAllowed = always && OpenWithMenu.canAlwaysOpenWith(lookup)
        for item in OpenWithMenu.menuItems(lookup: lookup, pinned: pinned, always: alwaysAllowed) {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                let row = NSMenuItem(
                    title: action.label, action: #selector(OpenWithSubmenuDelegate.choose(_:)), keyEquivalent: "")
                row.target = menu.delegate
                row.representedObject = OpenWithChoice(action: action)
                if case .application(_, _, let appPath, _, _) = action {
                    row.image = Self.icon(forApplication: appPath)
                }
                menu.addItem(row)
            }
        }
    }

    /// An app's own icon at the size of a line icon column (`.context-submenu-item .file-icon`: 16 pt).
    static func icon(forApplication path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// An `OpenWithAction` as a menu item's represented object.
final class OpenWithChoice: NSObject {
    let action: OpenWithAction
    init(action: OpenWithAction) { self.action = action }
}

@MainActor
final class OpenWithSubmenuDelegate: NSObject, NSMenuDelegate {
    private unowned let model: OpenWithLookupModel
    private weak var session: ContextMenuSession?
    private let always: Bool

    init(model: OpenWithLookupModel, always: Bool, session: ContextMenuSession) {
        self.model = model
        self.always = always
        self.session = session
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let session else { return }
        model.opened(menu, always: always, session: session)
    }

    @objc func choose(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? OpenWithChoice else { return }
        session?.chooseOpenWith(choice.action)
    }
}
