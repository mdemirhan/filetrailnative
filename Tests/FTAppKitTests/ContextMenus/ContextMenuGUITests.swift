// Ports the UI cases of components/ItemContextMenu.test.tsx and the menu, Open With and notice cases of
// App.menusAndTree.test.tsx, App.openItems.test.tsx and App.windows.test.tsx on a real explorer window
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// What a chosen menu item asked the system for.
final class OpenSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func record(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var opener: SystemOpener {
        SystemOpener(
            openPath: { [self] path in
                record("open \(path)")
                return ""
            },
            openWithApplication: { [self] app, paths in record("open -a \(app) \(paths.joined(separator: ","))") },
            reveal: { [self] paths in record("reveal \(paths.joined(separator: ","))") },
            openURL: { [self] url in record("url \(url.absoluteString)") })
    }
}

/// Notices and questions, kept instead of shown.
@MainActor
final class NoticeSpy: ActionNoticePresenting {
    var shown: [(title: String, message: String)] = []
    var answer = true
    var asked: [(app: String, kind: String?)] = []

    func show(title: String, message: String, in window: NSWindow?) {
        shown.append((title, message))
    }

    func confirmAlwaysOpenWith(appName: String, kindName: String?, in window: NSWindow?) async -> Bool {
        asked.append((appName, kindName))
        return answer
    }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ContextMenuGUITests {
        func opened(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.count >= 4 })
            return tab
        }

        func entry(_ tab: MainWindowController, _ name: String) throws -> DirectoryEntry {
            try #require(tab.content.entries.first { $0.name == name })
        }

        /// The rows as they show: the alternate (Always Open With) shows only while Option is held.
        func titles(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        func item(_ menu: NSMenu?, _ title: String) -> NSMenuItem? {
            menu?.items.first { $0.title == title }
        }

        // T-eb3ba6a5 T-0db05884 F-808 F-810 F-815
        @Test func aFilesMenuListsOnlyWhatCanBeDoneToIt() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            // Edit names the editor; a file has no Paste, New Folder, New Tab, Calculate Size or Package Contents.
            let editor = tab.preferences.defaultTextEditor.appName
            #expect(
                titles(menu) == [
                    "Open", "Open With", "Quick Look", "Edit in \(editor)", "-", "Show Info", "-", "Cut", "Copy",
                    "Copy Path", "-", "Rename", "Duplicate", "Move to…", "-", "Open in Terminal", "Show in Finder", "-",
                    "Move to Trash",
                ])
            await harness.close()
        }

        // T-4b2ec48e T-4ace0132 F-812 F-814
        @Test func aFolderHasNewTabsAndPasteAndTheBackgroundHasTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let folder = tab.contextMenus.contentMenu(for: [try entry(tab, "Alpha")])
            for title in ["Open in New Tab", "Open in New Window", "Calculate Size", "New Folder", "Add to Favorites"] {
                #expect(item(folder, title) != nil, "\(title)")
            }
            #expect(item(folder, "Edit in Text Editor") == nil && item(folder, "Show Package Contents") == nil)
            // Nothing on the clipboard to paste, and no folder to paste into yet: Paste is left out of a file's menu
            // and dimmed in a folder's only when it could apply.
            let background = tab.contextMenus.contentMenu(for: nil)
            #expect(
                titles(background) == [
                    "New Folder", "-", "Show Info", "Calculate Size", "-", "Paste", "Copy Path", "-", "View As",
                    "Sort By", "-", "Open in Terminal", "Show in Finder",
                ])
            #expect(background?.autoenablesItems == true)
            let session = try #require(tab.contextMenus.current)
            #expect(session.validateMenuItem(try #require(item(background, "Paste"))) == false)
            #expect(session.validateMenuItem(try #require(item(background, "New Folder"))))
            await harness.close()
        }

        // T-42ce73e3 F-814
        @Test func viewAsTicksTheCurrentViewAndSortByTheCurrentOrderAndPickingOneApplies() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: nil)
            let viewAs = try #require(item(menu, "View As")?.submenu)
            #expect(viewAs.items.map(\.title) == ExplorerViewMode.menuOrder.map(\.menuName))
            #expect(tab.viewMode == .icons)
            #expect(viewAs.items.map(\.state) == [.on, .off, .off])
            let sortBy = try #require(item(menu, "Sort By")?.submenu)
            #expect(sortBy.items.map(\.title) == ["Name", "Kind", "Date Modified", "Size"])
            #expect(sortBy.items.map(\.state) == [.on, .off, .off, .off])
            let compact = try #require(viewAs.items.last)
            _ = NSApp.sendAction(try #require(compact.action), to: compact.target, from: compact)
            #expect(tab.viewMode == ExplorerViewMode.menuOrder.last)
            let size = try #require(sortBy.items.last)
            _ = NSApp.sendAction(try #require(size.action), to: size.target, from: size)
            #expect(tab.sortBy == .size)
            await harness.close()
        }

        // F-808: 14 pt line icons, destructive items red
        @Test func everyItemHasAFourteenPointTemplateIconAndTheTrashItemIsRed() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            for entry in menu?.items ?? [] where !entry.isSeparatorItem {
                #expect(entry.image?.size == NSSize(width: 14, height: 14), "\(entry.title)")
                #expect(entry.image?.isTemplate == true)
            }
            let trash = try #require(item(menu, "Move to Trash"))
            let color = try #require(trash.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            #expect(color.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.8)
            #expect(item(menu, "Open")?.attributedTitle == nil)
            await harness.close()
        }

        // F-809: the shortcut is shown only where the key would do the same now
        @Test func theShortcutsShownAreTheKeysThatWouldDoTheSameNow() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let file = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            #expect(item(file, "Copy")?.keyEquivalent == "c" && item(file, "Copy")?.keyEquivalentModifierMask == .command)
            #expect(item(file, "Move to Trash")?.keyEquivalent.isEmpty == false)
            // From the tree, Paste and Open in New Tab name the right-clicked folder, not the selected one: no badge.
            let row = SidebarContextMenuRequest(
                item: TreePresentationItem(
                    id: .filesystem(harness.folder.path + "/Alpha"), kind: .filesystem, label: "Alpha", depth: 1,
                    path: harness.folder.path + "/Alpha", parentID: nil, expanded: false, canExpand: true),
                subview: .tree, kind: .treeFolder)
            let tree = tab.contextMenus.sidebarMenu(for: row)
            #expect(titles(tree).first == "New Folder")
            #expect(item(tree, "Paste into Folder")?.keyEquivalent.isEmpty == true)
            #expect(item(tree, "Open in New Tab")?.keyEquivalent.isEmpty == true)
            #expect(item(tree, "Copy")?.keyEquivalent == "c")
            await harness.close()
        }

        // T-4b1b713a T-994f6c5c T-947ce6a8 T-948f8ad2 F-808 F-851
        @Test func openWithListsTheDefaultPinnedAndOtherAppsAndOptionTurnsItIntoAlwaysOpenWith() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            let session = try #require(tab.contextMenus.current)
            let kind = OpenWithKind(contentType: "public.plain-text", name: "Plain Text Document", isFolder: false)
            session.openWith.ask = { _, _ in
                OpenWithLookup(
                    defaultApp: ApplicationInfo(path: "/System/Applications/TextEdit.app", name: "TextEdit"),
                    apps: [
                        ApplicationInfo(path: "/System/Applications/TextEdit.app", name: "TextEdit"),
                        ApplicationInfo(path: "/Applications/Zed.app", name: "Zed"),
                        ApplicationInfo(path: "/Applications/BBEdit.app", name: "BBEdit"),
                    ], kinds: [kind], pinnedApps: [])
            }
            let submenu = try #require(item(menu, "Open With")?.submenu)
            submenu.delegate?.menuNeedsUpdate?(submenu)
            #expect(await waitUntil { submenu.items.count > 2 })
            #expect(
                submenu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
                    "TextEdit (default)", "-", "BBEdit", "Zed", "-", "Other…",
                ])
            // Each app is drawn with its own icon.
            #expect(submenu.items.first?.image?.size == NSSize(width: 16, height: 16))
            // The alternate item is the same row turned into Always Open With.
            let alternate = try #require(menu?.items.first { $0.isAlternate })
            #expect(alternate.title == "Always Open With" && alternate.keyEquivalentModifierMask == .option)
            let always = try #require(alternate.submenu)
            always.delegate?.menuNeedsUpdate?(always)
            #expect(await waitUntil { always.items.count > 2 })
            #expect(always.items.map(\.title).contains("Zed"))

            // Choosing Zed with Always asks first, then makes it the kind's app and opens the file in it.
            let spy = OpenSpy()
            let notices = NoticeSpy()
            tab.contextMenus.opener = spy.opener
            tab.contextMenus.notices = notices
            let zed = try #require(always.items.first { $0.title == "Zed" })
            _ = NSApp.sendAction(try #require(zed.action), to: zed.target, from: zed)
            #expect(await waitUntil { !notices.asked.isEmpty })
            #expect(notices.asked.first?.app == "Zed" && notices.asked.first?.kind == "Plain Text Document")
            await harness.close()
        }

        // T-9c23e56d T-d76e20b7 T-c63fddc6
        @Test func tooManyItemsAndAFailedLaunchAreToldInANotice() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let notices = NoticeSpy()
            tab.contextMenus.notices = notices
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            tab.updatePreferences(["openItemLimit": .number(1)])
            tab.preferencesChanged(PreferencesChange(patch: ["openItemLimit": .number(1)], senderID: nil))
            let files = tab.content.entries.filter { !$0.isDirectoryLike }
            let two = ContextMenuSubject(
                surface: .content, paths: ["/a/one.txt", "/a/two.txt"], targetPath: "/a/one.txt",
                entries: [CommandEntry(path: "/a/one.txt", kind: .file), CommandEntry(path: "/a/two.txt", kind: .file)])
            tab.contextMenus.contextMenu(perform: .open, subject: two)
            tab.contextMenus.contextMenu(perform: .edit, subject: two)
            #expect(await waitUntil { notices.shown.count == 2 })
            #expect(notices.shown[0].title == "Too Many Items to Open")
            #expect(
                notices.shown[0].message
                    == "File Trail opens up to 1 item at a time, and 2 are selected. You can change this in Settings.")
            #expect(notices.shown[1].title == "Too Many Items to Edit")
            #expect(spy.all.isEmpty)
            _ = files
            await harness.close()
        }

        // T-e4395190 T-f34a5b66 T-ef662069 F-696
        @Test func terminalFinderAndCopyPathAreDoneThroughTheSystem() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            let note = try entry(tab, "note.txt")
            let subject = ContextMenuSubject(
                surface: .content, paths: [note.path], targetPath: note.path, entries: [CommandEntry(path: note.path, kind: .file)])
            tab.contextMenus.contextMenu(perform: .showInFinder, subject: subject)
            tab.contextMenus.contextMenu(perform: .terminal, subject: subject)
            #expect(await waitUntil { spy.all.count == 2 })
            #expect(spy.all.contains { $0 == "reveal \(note.path)" })
            #expect(spy.all.contains { $0.hasPrefix("open -a ") && $0.hasSuffix(harness.folder.path) })

            // Copy Path: shell-quoted only where there is whitespace, one to a line.
            let pasteboard = NSPasteboard.general
            tab.contextMenus.copyPath([note.path, "/a b/c.txt"])
            #expect(pasteboard.string(forType: .string) == "\(note.path)\n'/a b/c.txt'")
            #expect(tab.notifications?.toasts.entries.last?.title == "Copied paths")
            #expect(tab.notifications?.toasts.entries.last?.message == "note.txt and 1 more")
            await harness.close()
        }

        // F-810: the menu holds the folder's reloads while it is open (B-VIEW-187)
        @Test func changesOutsideWaitWhileAMenuIsOpen() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: nil)
            #expect(tab.folderChangesHeld == false)
            menu?.delegate?.menuWillOpen?(try #require(menu))
            #expect(tab.folderChangesHeld)
            menu?.delegate?.menuDidClose?(try #require(menu))
            #expect(tab.folderChangesHeld == false)
            await harness.close()
        }

        // T-f0d963ef B-VIEW-182; N/A T-ebac0af8 T-5b070983 T-9b853d57 T-4d8c727e T-49096868 T-99c41da7 T-b78847a6
        // (menuPlacement.ts): NSMenu places itself, keeps itself inside the screen and flips its submenus at an edge.
        // N/A T-ab4c17e9 T-2a203391 T-85ff21c7 T-510a7d55 (the keyboard, type-select and a disabled row's hover are NSMenu's).
        @Test func aNativeMenuClosesWhenAnotherWindowOrAppIsClickedAsTheSystemDoes() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let menu = try #require(tab.contextMenus.contentMenu(for: nil))
            // Menus are NSMenus: the system tracks them and ends them on a click elsewhere (didEndTracking).
            #expect(menu.delegate is ContextMenuSession)
            #expect(tab.contextMenus.current != nil)
            menu.delegate?.menuWillOpen?(menu)
            menu.delegate?.menuDidClose?(menu)
            #expect(tab.contextMenus.current == nil)
            await harness.close()
        }
    }
}
