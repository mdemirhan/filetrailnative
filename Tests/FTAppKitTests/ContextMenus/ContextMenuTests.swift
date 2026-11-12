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

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ContextMenuTests {
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

        @Test func aFolderHasNewTabsAndPasteAndTheBackgroundHasTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
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

        @Test func theRowOfColorsIsOfferedForItemsAndChoosingOneTagsThemAndDrawsTheDots() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let target = try entry(tab, "Alpha")
            defer { try? FinderTags.write([], to: target.path) }
            #expect(tab.contextMenus.contentMenu(for: nil)?.items.contains { $0.view is TagColorsMenuRow } == false)
            let menu = try #require(tab.contextMenus.contentMenu(for: [target]))
            let row = try #require(menu.items.compactMap { $0.view as? TagColorsMenuRow }.first)
            #expect(row.buttons.map(\.color) == FinderTagColor.menuOrder)
            let red = try #require(row.buttons.first { $0.color == .red })
            #expect(red.accessibilityPerformPress())
            #expect(await waitUntil { FinderTags.colors(target.path) == [.red] })
            #expect(await waitUntil { listedTags(tab, target.path) == [.red] })
            // A menu opened now marks the color the item has.
            let again = try #require(tab.contextMenus.contentMenu(for: [target]))
            let marked = try #require(again.items.compactMap { $0.view as? TagColorsMenuRow }.first)
            #expect(await waitUntil { marked.buttons.first { $0.color == .red }?.state == .all })
            await harness.close()
        }

        /// The tag colors the views draw for the item as it is listed now.
        private func listedTags(_ tab: MainWindowController, _ path: String) -> [FinderTagColor]? {
            tab.content.listedEntry(at: path).map(tab.content.tagColors(for:))
        }

        /// What the folder watch does on a change: the listing kept of it goes, and the window hears.
        private func changed(_ harness: ExplorerHarness, _ tab: MainWindowController, _ paths: [String]) {
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: paths))
        }

        @Test func aTagChangedDuringAReadOfItIsReadAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let path = try entry(tab, "Gamma").path
            defer { try? FinderTags.write([], to: path) }
            let real = tab.content.loaders.tagColors
            var held: CheckedContinuation<Void, Never>?
            tab.content.loaders.tagColors = { paths in
                let colors = await real(paths)
                if paths.contains(path), held == nil {
                    await withCheckedContinuation { held = $0 }
                }
                return colors
            }
            tab.content.tagsChanged([path])
            #expect(await waitUntil { held != nil })
            try FinderTags.write([FinderTag(name: "Red", color: .red)], to: path)
            tab.content.tagsChanged([path])
            held?.resume()
            #expect(await waitUntil { listedTags(tab, path) == [.red] })
            await harness.close()
        }

        @Test func aTagChangedOutsideTheAppIsReadWhenTheWatchTellsOfIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let target = try entry(tab, "Alpha")
            defer { try? FinderTags.write([], to: target.path) }
            try FinderTags.write([FinderTag(name: "Red", color: .red)], to: target.path)
            tab.content.tagsChanged([target.path])
            #expect(await waitUntil { listedTags(tab, target.path) == [.red] })
            // As Finder or another app would write it.
            try (URL(fileURLWithPath: target.path) as NSURL).setResourceValue(["Orange"], forKey: .tagNamesKey)
            changed(harness, tab, [target.path])
            #expect(await waitUntil { listedTags(tab, target.path) == [.orange] })
            await harness.close()
        }

        @Test func aTaggedItemsColorsComeWithItsListingBeforeTheRowsOnScreenAreRead() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let target = try entry(tab, "Alpha")
            defer { try? FinderTags.write([], to: target.path) }
            #expect(await waitUntil { listedTags(tab, target.path) == [] })
            // The read of the rows on screen never answers: what shows is what the listing read.
            tab.content.loaders.tagColors = { _ in await withCheckedContinuation { _ in } }
            try (URL(fileURLWithPath: target.path) as NSURL).setResourceValue(
                ["Green", "Orange"], forKey: .tagNamesKey)
            changed(harness, tab, [target.path])
            #expect(await waitUntil { listedTags(tab, target.path) == [.green, .orange] })
            await harness.close()
        }

        /// What Finder writes for Customize Folder, read from folders it customized.
        private func customizeFolder(_ path: String, _ configuration: String) {
            let data = Data(configuration.utf8)
            _ = data.withUnsafeBytes { setxattr(path, "com.apple.icon.folder#S", $0.baseAddress, data.count, 0, 0) }
            var finderInfo = [UInt8](repeating: 0, count: 32)
            finderInfo[8] = 0x04
            setxattr(path, "com.apple.FinderInfo", &finderInfo, 32, 0, 0)
        }

        @Test func aFolderCustomizedInFinderGetsItsOwnIconAndAChangeDrawsItAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let path = try entry(tab, "Alpha").path
            defer {
                removexattr(path, "com.apple.icon.folder#S", 0)
                removexattr(path, "com.apple.FinderInfo", 0)
            }
            let store = try #require(tab.content.iconStore)
            customizeFolder(path, #"{"sym":"bird.fill"}"#)
            changed(harness, tab, [path])
            #expect(await waitUntil { (try? entry(tab, "Alpha"))?.hasCustomIcon == true })
            let request = IconRequest(entry: try entry(tab, "Alpha").iconEntry)
            #expect(request.cacheKey == "path:\(path)")
            #expect(request.generic == nil)
            let plain = NSWorkspace.shared.icon(forFile: try entry(tab, "Beta").path).tiffRepresentation
            #expect(NSWorkspace.shared.icon(forFile: path).tiffRepresentation != plain)
            let first = await withCheckedContinuation { done in store.load(request) { done.resume(returning: $0) } }
            #expect(first != nil)
            // The symbol changes and nothing else does: the icon kept is let go.
            customizeFolder(path, #"{"emoji":"😀"}"#)
            changed(harness, tab, [path])
            #expect(
                await waitUntil {
                    if case .image(let image) = store.lookup(request) { return image !== first }
                    return true
                })
            await harness.close()
        }

        @Test func viewAsTicksTheCurrentViewAndSortByTheCurrentOrderAndPickingOneApplies() async throws {
            let harness = try ExplorerHarness.windowless()
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

        // System symbols, destructive items red
        @Test func everyItemHasATemplateIconAndTheTrashItemIsRed() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let menu = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            for entry in menu?.items ?? [] where !entry.isSeparatorItem && entry.view == nil {
                #expect(entry.image?.isValid == true, "\(entry.title)")
                #expect(entry.image?.isTemplate == true)
                // From macOS 27 the system hides a menu item's image unless it is asked to show it.
                if #available(macOS 27, *) { #expect(entry.preferredImageVisibility == .visible, "\(entry.title)") }
            }
            let trash = try #require(item(menu, "Move to Trash"))
            let color = try #require(
                trash.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            #expect(color.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.8)
            #expect(item(menu, "Open")?.attributedTitle == nil)
            await harness.close()
        }

        // The shortcut is shown only where the key would do the same now
        @Test func theShortcutsShownAreTheKeysThatWouldDoTheSameNow() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let file = tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")])
            #expect(
                item(file, "Copy")?.keyEquivalent == "c" && item(file, "Copy")?.keyEquivalentModifierMask == .command)
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

        @Test func openWithListsTheDefaultPinnedAndOtherAppsAndOptionTurnsItIntoAlwaysOpenWith() async throws {
            let harness = try ExplorerHarness.windowless()
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
            // The row is there before the menu opens: one that appears under the pointer with Option held never opens
            // its submenu. Its apps can't be chosen until macOS has named the kind.
            let waiting = try #require(menu?.items.first { $0.isAlternate }?.submenu)
            #expect(!waiting.items.isEmpty && waiting.items.allSatisfy { $0.action == nil })
            let submenu = try #require(item(menu, "Open With")?.submenu)
            submenu.delegate?.menuNeedsUpdate?(submenu)
            #expect(await waitUntil { submenu.items.count > 2 })
            #expect(
                submenu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
                    "TextEdit (default)", "-", "BBEdit", "Zed", "-", "Other…",
                ])
            // Each app is drawn with its own icon.
            #expect(submenu.items.first?.image?.size == NSSize(width: 16, height: 16))
            // From macOS 27 the system hides a menu item's image unless it is told to show it.
            if #available(macOS 27, *) { #expect(submenu.items.first?.preferredImageVisibility == .visible) }
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
            // Never the system's: it would change what plain text opens in on this Mac.
            var changed: [String] = []
            tab.contextMenus.setDefaultApplication = { appPath, contentType in
                changed.append("\(appPath) \(contentType)")
                return .success
            }
            let zed = try #require(always.items.first { $0.title == "Zed" })
            _ = NSApp.sendAction(try #require(zed.action), to: zed.target, from: zed)
            #expect(await waitUntil { !spy.all.isEmpty })
            #expect(notices.asked.first?.app == "Zed" && notices.asked.first?.kind == "Plain Text Document")
            #expect(changed == ["/Applications/Zed.app public.plain-text"])
            await harness.close()
        }

        // Files whose names show different kinds have no one app to always open with: there is no row for
        // Option to turn it into, so nothing can stand in the way of Open With's submenu.
        @Test func filesNamedAsDifferentKindsHaveNoAlwaysOpenWithRow() async throws {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("photo.png"), atomically: true, encoding: .utf8)
            let tab = try await opened(harness)
            let menu = try #require(
                tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt"), try entry(tab, "photo.png")]))
            #expect(!menu.items.contains { $0.isAlternate })
            #expect(item(menu, "Open With")?.submenu != nil)
            await harness.close()
        }

        // When macOS says the kinds differ after all, the row stays where the pointer may be and says Open
        // With. The answer is asked for when the row is reached, not only when its submenu opens.
        @Test func optionLeavesOpenWithAsItIsForFilesOfDifferentKinds() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let menu = try #require(tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")]))
            let session = try #require(tab.contextMenus.current)
            session.openWith.ask = { _, _ in
                OpenWithLookup(
                    defaultApp: nil, apps: [],
                    kinds: [
                        OpenWithKind(contentType: "public.plain-text", name: "Plain Text Document", isFolder: false),
                        OpenWithKind(contentType: "public.png", name: "PNG Image", isFolder: false),
                    ], pinnedApps: [])
            }
            let row = try #require(item(menu, "Open With"))
            session.menu(menu, willHighlight: row)
            #expect(await waitUntil { session.openWith.lookup != nil })
            let alternate = try #require(menu.items.first { $0.isAlternate })
            #expect(alternate.title == "Open With" && !alternate.isHidden)
            let rows = try #require(alternate.submenu).items.compactMap { $0.representedObject as? OpenWithChoice }
            #expect(rows.map(\.action) == [.other(id: "other", label: "Other…", appName: "Other…", always: false)])
            await harness.close()
        }

        // With Option held from the start, the row reached is Always Open With: it is what asks macOS.
        @Test func reachingAlwaysOpenWithAsksMacOSAndLetsItsAppsBeChosen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let menu = try #require(tab.contextMenus.contentMenu(for: [try entry(tab, "note.txt")]))
            let session = try #require(tab.contextMenus.current)
            session.openWith.ask = { _, _ in
                OpenWithLookup(
                    apps: [ApplicationInfo(path: "/Applications/Zed.app", name: "Zed")],
                    kinds: [OpenWithKind(contentType: "public.plain-text", name: "Plain Text", isFolder: false)],
                    pinnedApps: [])
            }
            let alternate = try #require(menu.items.first { $0.isAlternate })
            session.menu(menu, willHighlight: alternate)
            let always = try #require(alternate.submenu)
            #expect(await waitUntil { always.items.contains { $0.title == "Zed" } })
            #expect(always.items.allSatisfy { $0.isSeparatorItem || $0.action != nil })
            #expect(alternate.title == "Always Open With")
            await harness.close()
        }

        /// The window can close while macOS answers. What comes after the answer still reads the tab.
        @Test func anAnswerFromMacOSAfterTheWindowClosedIsStillHandled() async throws {
            let harness = try ExplorerHarness.windowless()
            let notices = NoticeSpy()
            var answer: CheckedContinuation<OperationResult, Never>?
            weak var closedTab: MainWindowController?
            do {
                let tab = try await opened(harness)
                closedTab = tab
                tab.contextMenus.notices = notices
                tab.contextMenus.setDefaultApplication = { _, _ in
                    await withCheckedContinuation { answer = $0 }
                }
                tab.contextMenus.contextMenu(
                    open: [try entry(tab, "note.txt").path],
                    with: .application(
                        id: "zed", label: "Zed", appPath: "/Applications/Zed.app", appName: "Zed", always: true),
                    kind: OpenWithKind(contentType: "public.plain-text", name: "Plain Text Document", isFolder: false))
            }
            #expect(await waitUntil { answer != nil })
            await harness.close()
            answer?.resume(returning: .failure("macOS refused."))
            #expect(await waitUntil { !notices.shown.isEmpty })
            #expect(notices.shown.first?.title == "Couldn’t Change the App")
            #expect(await waitUntil { closedTab == nil })
        }

        @Test func tooManyItemsAreToldInANotice() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let notices = NoticeSpy()
            tab.contextMenus.notices = notices
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            tab.updatePreferences { $0.openItemLimit = 1 }
            tab.preferencesChanged(PreferencesChange(keys: [.openItemLimit], senderID: nil))
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
            await harness.close()
        }

        /// Sets "Double-click a file to" to Edit: Open from the menu must not listen to it.
        func editOnDoubleClick(_ tab: MainWindowController) {
            tab.updatePreferences { $0.fileActivationAction = .edit }
            tab.preferencesChanged(PreferencesChange(keys: [.fileActivationAction], senderID: nil))
        }

        func openSubject(_ paths: [String], entries: [DirectoryEntry]) -> ContextMenuSubject {
            ContextMenuSubject(
                surface: .content, paths: paths, targetPath: paths.first,
                entries: entries.map(ContextMenuCoordinator.commandEntry))
        }

        // `openPaths`: the one file on screen opens in what macOS chooses, whatever a double-click is set to.
        @Test func openFromTheMenuOpensAFileEvenWhenDoubleClickEdits() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            editOnDoubleClick(tab)
            let spy = OpenSpy()
            tab.opener = spy.opener
            tab.contextMenus.opener = spy.opener
            let note = try entry(tab, "note.txt")
            tab.contextMenus.contextMenu(perform: .open, subject: openSubject([note.path], entries: [note]))
            #expect(await waitUntil { !spy.all.isEmpty })
            #expect(spy.all == ["open \(note.path)"])
            await harness.close()
        }

        // `openPaths`: several items are each handed to the system in the order given, a folder among them, which does
        // not open in place.
        @Test func openFromTheMenuHandsSeveralItemsToTheSystemFoldersToo() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let spy = OpenSpy()
            tab.opener = spy.opener
            tab.contextMenus.opener = spy.opener
            var openedByTheTab: [String] = []
            tab.openFile = { openedByTheTab.append($0.path) }
            let note = try entry(tab, "note.txt")
            let folder = try #require(tab.content.entries.first { $0.kind == .directory })
            let before = tab.shownFolderPath
            tab.contextMenus.contextMenu(
                perform: .open, subject: openSubject([note.path, folder.path], entries: [note, folder]))
            #expect(await waitUntil { spy.all.count == 2 })
            #expect(spy.all == ["open \(note.path)", "open \(folder.path)"])
            #expect(openedByTheTab.isEmpty)
            #expect(tab.shownFolderPath == before)
            await harness.close()
        }

        // `openPaths`: one folder on screen opens in place; one that is not on screen goes to the system.
        @Test func openFromTheMenuOpensOneFolderByWhereItIs() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            tab.contextMenus.contextMenu(
                perform: .open,
                subject: ContextMenuSubject(
                    surface: .treeFolder, paths: ["/elsewhere/folder"], targetPath: "/elsewhere/folder",
                    entries: [CommandEntry(path: "/elsewhere/folder", kind: .directory)]))
            #expect(await waitUntil { !spy.all.isEmpty })
            #expect(spy.all == ["open /elsewhere/folder"])
            let folder = try #require(tab.content.entries.first { $0.kind == .directory })
            tab.contextMenus.contextMenu(perform: .open, subject: openSubject([folder.path], entries: [folder]))
            #expect(await waitUntil { tab.shownFolderPath == folder.path })
            #expect(spy.all.count == 1)
            await harness.close()
        }

        // An item macOS doesn't open is logged, and nothing is shown.
        @Test func aFailedOpenFromTheMenuShowsNoNotice() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let notices = NoticeSpy()
            tab.contextMenus.notices = notices
            let spy = OpenSpy()
            tab.contextMenus.opener = SystemOpener(
                openPath: { path in
                    spy.record("open \(path)")
                    return "No application"
                },
                openWithApplication: { _, _ in }, reveal: { _ in }, openURL: { _ in })
            let note = try entry(tab, "note.txt")
            tab.contextMenus.contextMenu(perform: .open, subject: openSubject([note.path], entries: [note]))
            #expect(await waitUntil { !spy.all.isEmpty })
            // A later notice, so one from the failed open would have come first.
            let tooMany = (0...tab.preferences.openItemLimit).map { "/a/\($0)" }
            tab.contextMenus.contextMenu(perform: .open, subject: openSubject(tooMany, entries: []))
            #expect(await waitUntil { !notices.shown.isEmpty })
            #expect(notices.shown.map(\.title) == ["Too Many Items to Open"])
            await harness.close()
        }

        // A failed Edit is told as the menu tells it, whichever control asked: a double-click set to Edit, Return or
        // the Edit command.
        @Test func aFailedEditFromADoubleClickOrTheCommandIsToldInANotice() async throws {
            struct Refused: LocalizedError {
                var errorDescription: String? { "The editor is gone." }
            }
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("second.txt"), atomically: true, encoding: .utf8)
            let tab = try await opened(harness)
            editOnDoubleClick(tab)
            let editor = tab.preferences.defaultTextEditor
            tab.opener = SystemOpener(
                openPath: { _ in "" }, openWithApplication: { _, _ in throw Refused() }, reveal: { _ in },
                openURL: { _ in })
            let note = try entry(tab, "note.txt")
            let second = try entry(tab, "second.txt")

            tab.open([note])
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(tab.frontAlert?.titleLabel.stringValue == "Couldn’t Open in \(editor.appName)")
            #expect(
                tab.frontAlert?.messageLabel?.stringValue
                    == "File Trail couldn’t open it in \(editor.appName). The editor is gone.")
            tab.dialogs.last?.dismiss()
            #expect(await waitUntil { tab.frontAlert == nil })

            tab.content.select(paths: [note.path, second.path])
            tab.perform(.editSelection)
            #expect(await waitUntil { tab.frontAlert != nil })
            #expect(
                tab.frontAlert?.messageLabel?.stringValue
                    == "File Trail couldn’t open them in \(editor.appName). The editor is gone.")
            tab.dialogs.last?.dismiss()
            await harness.close()
        }

        @Test func terminalFinderAndCopyPathAreDoneThroughTheSystem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            let note = try entry(tab, "note.txt")
            let subject = ContextMenuSubject(
                surface: .content, paths: [note.path], targetPath: note.path,
                entries: [CommandEntry(path: note.path, kind: .file)])
            tab.contextMenus.contextMenu(perform: .showInFinder, subject: subject)
            tab.contextMenus.contextMenu(perform: .terminal, subject: subject)
            #expect(await waitUntil { spy.all.count == 2 })
            #expect(spy.all.contains { $0 == "reveal \(note.path)" })
            #expect(spy.all.contains { $0.hasPrefix("open -a ") && $0.hasSuffix(harness.folder.path) })

            // Copy Path: shell-quoted only where there is whitespace, one to a line.
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            tab.contextMenus.pasteboard = pasteboard
            tab.contextMenus.copyPath([note.path, "/a b/c.txt"])
            #expect(pasteboard.string(forType: .string) == "\(note.path)\n'/a b/c.txt'")
            #expect(tab.notifications?.toasts.entries.last?.title == "Copied paths")
            #expect(tab.notifications?.toasts.entries.last?.message == "note.txt and 1 more")
            await harness.close()
        }

        // The menu holds the folder's reloads while it is open
        // Menus are NSMenus, which the system tracks and ends on a click elsewhere
        // (didEndTracking); the session ends with it.
        @Test func changesOutsideWaitWhileAMenuIsOpen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let menu = try #require(tab.contextMenus.contentMenu(for: nil))
            #expect(menu.delegate is ContextMenuSession)
            #expect(tab.contextMenus.current != nil)
            #expect(tab.folderChangesHeld == false)
            menu.delegate?.menuWillOpen?(menu)
            #expect(tab.folderChangesHeld)
            menu.delegate?.menuDidClose?(menu)
            #expect(tab.folderChangesHeld == false)
            #expect(tab.contextMenus.current == nil)
            await harness.close()
        }

        // The Trash's Empty Trash goes by what the tab last read, so a slow disk does not hold the menu up; the Trashes
        // are read again behind the menu, and the next menu has that answer.
        @Test func emptyTrashGoesByTheLastAnswerAndTheTrashIsReadAgainBehindTheMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let trash = FavoriteLabel.trashPath(homePath: FileManager.default.homeDirectoryForCurrentUser.path)
            let request = SidebarContextMenuRequest(
                item: TreePresentationItem(
                    id: .favorite(trash), kind: .favorite, label: "Trash", depth: 0, path: trash, parentID: nil,
                    expanded: false, canExpand: false),
                subview: .favorites, kind: .favorite)
            await settle()
            tab.trashIsEmptyReader = { false }
            tab.trashIsEmpty = true
            #expect(item(tab.contextMenus.sidebarMenu(for: request), "Empty Trash…") == nil)
            #expect(await waitUntil { tab.trashIsEmpty == false })
            #expect(item(tab.contextMenus.sidebarMenu(for: request), "Empty Trash…") != nil)
            await harness.close()
        }

        // A menu that closes lets go of its own hold only: a sheet that came up meanwhile (a background copy's
        // result) keeps the list as it is.
        @Test func aMenuClosingLeavesASheetsHoldInPlace() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let menu = try #require(tab.contextMenus.contentMenu(for: nil))
            menu.delegate?.menuWillOpen?(menu)
            tab.holdFolderChanges(.dialog, true)
            menu.delegate?.menuDidClose?(menu)
            #expect(tab.folderChangesHeld)
            await harness.close()
        }

    }
}
