import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct CommandPaletteMenuTests {
    private func build(_ options: ApplicationMenuOptions = .init()) -> (BuiltApplicationMenu, MenuCommandRouter) {
        _ = NSApplication.shared
        let router = MenuCommandRouter()
        return (ApplicationMenuBuilder.build(target: router, options: options), router)
    }

    /// Every item of `menu` and its submenus that does something: no separators, and no items that only hold a submenu.
    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu { return item.title == "Services" ? [item] : items(submenu) }
            return item.isSeparatorItem ? [] : [item]
        }
    }

    // Every item the menu bar has is a command of the palette, or left out of it by name, so a menu item added later
    // can't be forgotten (docs/working/commands.md).
    @Test func everyMenuItemIsInThePaletteOrLeftOutByName() {
        let workspaces = [WorkspaceMenuEntry(id: "w1", name: "Photos"), WorkspaceMenuEntry(id: "w2", name: "Work")]
        let (built, _) = build(ApplicationMenuOptions(workspaces: workspaces))
        let entries = CommandPalette.entries(
            bindings: ShortcutCommands.defaultBindings, states: [:],
            workspaces: workspaces.map { CommandPaletteWorkspace(id: $0.id, name: $0.name) })
        let runs = Set(entries.map(\.run))
        let systemTitles = Set(entries.filter { if case .system = $0.run { true } else { false } }.map(\.title))
        for item in items(built.menu) {
            // AppKit names a standard item by its action; the app's own items have ids of their own.
            if item.action == #selector(MenuCommandRouter.chooseMenuItem(_:)), let id = item.identifier?.rawValue {
                #expect(
                    runs.contains(.menuItem(id)) || id == ApplicationMenuBuilder.commandPaletteItemID
                        || CommandPalette.excludedMenuItems.contains(id), "\(id)")
            } else {
                #expect(
                    systemTitles.contains(item.title) || CommandPalette.excludedMenuItems.contains(item.title),
                    "\(item.title)")
            }
        }
    }

    // View ▸ Command Palette… has ⇧⌘P, or the key Settings gives it, and opens the palette through the menu's own
    // handler.
    @Test func theViewMenuOpensThePaletteWithItsKey() {
        let (built, router) = build()
        let item = built.itemsByID[ApplicationMenuBuilder.commandPaletteItemID]
        #expect(item?.title == "Command Palette…")
        #expect(item?.menu?.title == "View")
        #expect(item?.keyEquivalent == "p")
        #expect(item?.keyEquivalentModifierMask == [.shift, .command])
        var opened = 0
        router.onShowCommandPalette = { opened += 1 }
        router.choose(itemID: ApplicationMenuBuilder.commandPaletteItemID)
        #expect(opened == 1)

        var bindings = ShortcutCommands.defaultBindings
        bindings[.showCommandPalette] = ["Ctrl+Cmd+K"]
        let (changed, _) = build(ApplicationMenuOptions(shortcuts: bindings))
        let moved = changed.itemsByID[ApplicationMenuBuilder.commandPaletteItemID]
        #expect(moved?.keyEquivalent == "k")
        #expect(moved?.keyEquivalentModifierMask == [.control, .command])
    }
}
