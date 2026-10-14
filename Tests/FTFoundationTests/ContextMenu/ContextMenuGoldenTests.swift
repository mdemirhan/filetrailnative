// Checks the port against goldens recorded from the reference: tools/parity/golden/context-menu.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ContextMenuGoldenTests {
    static func string(_ node: JSONNode?) -> String? {
        if case .string(let text) = node { return text }
        return nil
    }

    static func flag(_ node: JSONNode?) -> Bool {
        if case .bool(let value) = node { return value }
        return false
    }

    /// The item list as the reference writes it: separators by key, actions with `destructive` and `hasSubmenu` only
    /// when they are on.
    static func node(_ items: [ContextMenuItem]) -> JSONNode {
        .array(
            items.map { item in
                switch item {
                case .separator(let key):
                    return .object(["type": .string("separator"), "key": .string(key)])
                case .action(let id, let label, let icon, let destructive, let hasSubmenu):
                    var members: [String: JSONNode] = [
                        "id": .string(id.rawValue), "label": .string(label), "icon": .string(icon.rawValue),
                    ]
                    if destructive { members["destructive"] = .bool(true) }
                    if hasSubmenu { members["hasSubmenu"] = .bool(true) }
                    return .object(members)
                }
            })
    }

    static func options(_ node: JSONNode?) -> ContextMenuOptions {
        guard case .object(let members) = node else { return ContextMenuOptions() }
        return ContextMenuOptions(
            favoriteToggleLabel: string(members["favoriteToggleLabel"]),
            textEditorName: string(members["textEditorName"]), targetsFolder: flag(members["targetsFolder"]),
            renameLabel: string(members["renameLabel"]), ejectLabel: string(members["ejectLabel"]))
    }

    static func context(_ node: JSONNode?) -> ShortcutContext {
        guard case .object(let members) = node else { return ShortcutContext() }
        return ShortcutContext(
            actionNoticeOpen: flag(members["actionNoticeOpen"]),
            copyPasteModalOpen: flag(members["copyPasteModalOpen"]),
            focusedPane: string(members["focusedPane"]).flatMap { FocusedPane(rawValue: $0) },
            locationSheetOpen: flag(members["locationSheetOpen"]),
            mainView: string(members["mainView"]).flatMap { MainView(rawValue: $0) } ?? .explorer,
            selectedTreeTargetKind: string(members["selectedTreeTargetKind"]).flatMap {
                SelectedTreeTargetKind(rawValue: $0)
            })
    }

    // F-808 F-810 F-811 F-812 F-813 F-814 F-809
    @Test func everyMenuListsTheItemsOfTheOriginalInItsOrder() throws {
        let cases: [GoldenCase<JSONNode, JSONNode>] = try Golden.load(suite: "context-menu")
        #expect(cases.count > 100)
        Golden.expectMatches(cases) { input in
            guard case .object(let members) = input, let kind = Self.string(members["kind"]) else { return .null }
            switch kind {
            case "items":
                guard let surface = Self.string(members["surface"]).flatMap({ ContextMenuSurface(rawValue: $0) })
                else { return .null }
                return Self.node(
                    ContextMenuItems.items(surface: surface, options: Self.options(members["options"])))
            default:
                guard let action = Self.string(members["action"]) else { return .null }
                let label = ShortcutPolicy.contextMenuShortcutLabel(
                    actionID: action, context: Self.context(members["context"]))
                return label.map { .string($0) } ?? .null
            }
        }
    }
}
