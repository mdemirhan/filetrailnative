// Ports by feature the scenarios of the wave-3-end checkpoint that differed: 38 (paste in another window), 10 (dates of
// results), a17 (a date in the list), 78 and 80 (the folder let go of) and 101, 106 and 107 (where the tree stands)
#if DEBUG
    import AppKit
    import FTFoundation
    import FTTestSupport
    import Foundation
    import Testing

    @testable import FTAppKit

    /// Opens only when told to: details asked for wait on it.
    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    /// An explorer window as the menu sees it, on screen though the harness never shows it: the app is in the background
    /// with its windows showing, which the menu tells from none being open.
    @MainActor
    private final class ShownHandle: ExplorerWindowHandle {
        let inner: any ExplorerWindowHandle
        init(_ inner: any ExplorerWindowHandle) { self.inner = inner }
        var windowID: Int { inner.windowID }
        var window: NSWindow? { inner.window }
        var isOnScreen: Bool { true }
        func perform(_ command: RendererCommand) { inner.perform(command) }
    }

    @MainActor
    private final class ShownWindows: ExplorerWindowListing {
        let inner: any ExplorerWindowListing
        init(_ inner: any ExplorerWindowListing) { self.inner = inner }
        var front: (any ExplorerWindowHandle)? { inner.front.map(ShownHandle.init) }
        var count: Int { inner.count }
        func handle(for window: NSWindow) -> (any ExplorerWindowHandle)? {
            inner.handle(for: window).map(ShownHandle.init)
        }
        func handle(windowID: Int) -> (any ExplorerWindowHandle)? {
            inner.handle(windowID: windowID).map(ShownHandle.init)
        }
    }

    extension ExplorerWindowlessTests {
        @MainActor
        @Suite(.windowlessAlone) struct CheckpointStepsTests {
            private static let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()

            /// A runner over `steps`, on `tab`, whose run is never started: the steps are carried out one by one.
            private func runner(
                _ steps: String, tab: MainWindowController, in folder: TemporaryDirectory
            ) throws -> AutomationRunner {
                let file = folder.appending("scenario.json")
                try Data(#"{"name": "x", "steps": [\#(steps)]}"#.utf8).write(to: file)
                let runner = AutomationRunner(
                    options: .init(scenario: file, out: folder.url), controller: { [weak tab] in tab })
                _ = runner.load()
                return runner
            }

            // T-317cfcc8 F-638 F-643 B-VIEW-171 B-VIEW-184: scenario 38 with the app in the background, as a capture run
            // may leave it: no window is key, so ⌘C and ⌘V go through the menu to the window picked last. The copy
            // reaches the other window's clipboard button, and the paste lists, selects and tells of the file there.
            // B-VIEW-229
            @Test func keyStepsCopyInThePickedWindowAndPasteInTheOther() async throws {
                let window = try await WritingWindow.open()
                let harness = window.harness
                let tab = window.tab
                let listing = ShownWindows(harness.windows)
                let menu = MainMenu(windows: listing)
                harness.windows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
                harness.windows.onMenuState = { [weak menu] id, state in
                    menu?.sync.setWindowState(windowID: id, state)
                }
                menu.build()
                menu.observeFocus()
                defer { NSApp.mainMenu = nil }
                tab.perform(.newWindow)
                #expect(await waitUntil { harness.windows.allTabs.count == 2 })
                let other = try #require(harness.windows.allTabs.first { $0 !== tab })
                other.servicesOverride = harness.services
                other.ensureLoaded()
                other.go(to: window.folder.appendingPathComponent("Gamma"))
                #expect(await waitUntil { other.folder.lastPathComponent == "Gamma" })
                #expect(NSApp.keyWindow == nil)
                #expect(harness.windows.front === other)
                let scratch = try TemporaryDirectory.shallow(prefix: "filetrail-steps")
                defer { scratch.remove() }
                let steps = try runner("", tab: tab, in: scratch)

                let first = try #require(tab.window)
                AutomationRunner.windowPicked(first)
                #expect(harness.windows.front === tab)
                window.select(["note.txt"])
                #expect(steps.press("c", modifiers: ["cmd"], window: first).status == .ok)
                let note = window.folder.appendingPathComponent("note.txt").path
                #expect(tab.services.clipboard.contents.sourcePaths == [note])
                harness.layout(other)
                let button = other.explorerToolbar.clipboardButton
                #expect(button?.count.stringValue == "1")

                let second = try #require(other.window)
                AutomationRunner.windowPicked(second)
                #expect(harness.windows.front === other)
                #expect(steps.press("v", modifiers: ["cmd"], window: second).status == .ok)
                // The toast lasts 4 s, which a busy Mac can spend on the waits before it: it is looked for all along.
                var toastShown = false
                #expect(
                    await waitUntil {
                        toastShown =
                            toastShown
                            || other.notifications?.toasts.entries.contains { $0.title == "Pasted into Gamma" } == true
                        return toastShown && window.exists("Gamma/note.txt")
                            && other.content.selectedEntries.map(\.name) == ["note.txt"]
                    })
                await window.close()
            }

            // F-813 B-SRCH-104: scenario 10. A step does not count as finished while the details of the rows on screen
            // are being read: the snapshot after it has the dates and sizes of the results (the field being edited).
            @Test func aStepWaitsForTheDetailsOfTheRowsOnScreen() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                tab.perform(.viewAsDetails)
                harness.layout(tab)
                let engine = FakeSearchEngine()
                let timers = ManualTimers()
                tab.search.session.engine = engine
                tab.search.session.timers = timers
                let details = tab.content.loaders.metadata
                let gate = Gate()
                tab.content.loaders.metadata = { folder, paths in
                    await gate.wait()
                    return await details(folder, paths)
                }
                let field = try #require(tab.searchField)
                tab.window?.makeFirstResponder(field)
                engine.finds = { _ in (["note.txt"], false, false) }
                field.stringValue = "no"
                tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                timers.advance(0.4)
                #expect(await waitUntil { tab.content.entries.count == 1 })
                harness.layout(tab)
                #expect(await waitUntil { tab.content.isReadingDetails })
                let shown = try #require(tab.content.entries.first?.path)
                let scratch = try TemporaryDirectory.shallow(prefix: "filetrail-steps")
                defer { scratch.remove() }
                let steps = try runner("", tab: tab, in: scratch)
                var settled = false
                Task { @MainActor in
                    await steps.settle()
                    settled = true
                }
                try await Task.sleep(for: .milliseconds(400))
                #expect(!settled)
                #expect(tab.content.metadata(for: shown) == nil)
                gate.open()
                #expect(await waitUntil { settled })
                #expect(tab.content.metadata(for: shown)?.sizeBytes != nil)
                await harness.close()
            }

            // F-831 B-NAV-134: a17 step 13. "list row date" of the elements names the list's Date Modified cells: there
            // is one to a row, and it reads what a person sees there.
            @Test func aListRowDateIsTheDateCell() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                tab.perform(.viewAsDetails)
                harness.layout(tab)
                let window = try #require(tab.window)
                let elements = try AutomationElements.load(
                    Self.repo.appendingPathComponent("tools/capture/elements.json"))
                let identifier = try #require(elements.identifiers["list row date"])
                let entries = tab.content.entries
                #expect(await waitUntil { entries.allSatisfy { tab.content.metadata(for: $0.path) != nil } })
                harness.layout(tab)
                let table = try #require(Views.folderTable(in: window))
                let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
                let dates = Views.all(NSView.self, in: row).filter { $0.accessibilityIdentifier() == identifier }
                #expect(dates.count == 1)
                #expect(dates.allSatisfy { !ElementFinder.text(of: $0).isEmpty })
                await harness.close()
            }

            // F-737 B-TREE-059 B-TREE-060: scenario 80. A press on a section's heading lets go of the folder: no title, no
            // path, "Select a folder…" and no reading it again, until a folder is opened.
            // B-INFO-103 B-NAV-117 B-NAV-123
            @Test func aFolderLetGoOfShowsNoFolder() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                tab.perform(.viewAsDetails)
                harness.layout(tab)
                let sidebar = tab.sidebarController
                let folder = tab.folder
                tab.perform(.rootTreeAtSelection)
                #expect(await waitUntil { TreePaths.same(sidebar.model.rootPath, folder.path) })
                #expect(tab.group?.tabs.count == 1)
                sidebar.model.clearSelection()
                #expect(tab.content.container(for: .empty(text: ContentStateText.noFolder)))
                #expect(tab.shownFolderPath.isEmpty)
                #expect(ExplorerToolbar.title(of: tab).isEmpty)
                #expect(tab.window?.title == "File Trail")
                let bar = tab.content.contentShell.pathBarRow
                #expect(bar.pathBar.segments.map(\.label) == ["No folder selected"])
                tab.reload()
                try await Task.sleep(for: .milliseconds(150))
                #expect(tab.content.entries.isEmpty)
                #expect(tab.content.container(for: .empty(text: ContentStateText.noFolder)))
                tab.go(to: folder)
                #expect(await waitUntil { !tab.content.entries.isEmpty })
                #expect(tab.shownFolderPath == folder.path)
                #expect(!ExplorerToolbar.title(of: tab).isEmpty)
                #expect(bar.pathBar.segments.map(\.label) != ["No folder selected"])
                await harness.close()
            }

            // B-TREE-060: with no folder the tab is "Favorites" and keeps no path: not in its snapshot or its saved tab, and
            // it isn't remembered when closed. Hidden files only change the setting. A new tab has no folder either.
            @Test func aFolderLetGoOfKeepsNoPath() async throws {
                let harness = try ExplorerHarness.windowless()
                let tab = try await harness.open()
                let folder = tab.folder
                let group = try #require(tab.group)
                tab.sidebarController.model.clearSelection()

                #expect(tab.tabDescription.label == "Favorites")
                #expect(tab.tabDescription.tooltip.isEmpty)
                #expect(tab.snapshot.currentPath.isEmpty)
                #expect(tab.snapshot.selectedTreeItemID == nil)
                #expect(tab.openTab.path == nil)
                #expect(tab.openTab.favoritePath == nil)
                group.saveSession()
                #expect(tab.preferences.lastVisitedPath == nil)
                group.session.rememberClosedTab(tab.snapshot)
                #expect(group.session.closedTabs.isEmpty)

                let hidden = tab.includeHidden
                tab.perform(.toggleHiddenFiles)
                #expect(tab.includeHidden != hidden)
                try await Task.sleep(for: .milliseconds(150))
                #expect(tab.shownFolderPath.isEmpty)
                #expect(tab.content.entries.isEmpty)
                #expect(tab.content.container(for: .empty(text: ContentStateText.noFolder)))

                group.openNewTab(from: tab)
                let new = try #require(group.tabs.last)
                #expect(new !== tab)
                new.ensureLoaded()
                try await Task.sleep(for: .milliseconds(150))
                #expect(new.shownFolderPath.isEmpty)
                #expect(new.snapshot.historyPaths.isEmpty)
                #expect(new.tabDescription.label == "Favorites")
                #expect(new.content.entries.isEmpty)

                tab.go(to: folder)
                #expect(await waitUntil { !tab.content.entries.isEmpty })
                #expect(tab.tabDescription.label != "Favorites")
                #expect(tab.snapshot.currentPath == folder.path)
                await harness.close()
            }

            // A driven run starts from nothing: a run that gets the number of an earlier process doesn't find its
            // windows (78's second tab).
            @Test func aDrivenRunNeverSharesItsState() {
                #expect(AppDelegate.drivenUserDataDirectory() != AppDelegate.drivenUserDataDirectory())
            }

            // A density change reveals nothing (TreePane's reveal doesn't depend on it): the tree stays at its offset,
            // unless the rows no longer reach that far, where it stands at their end, as a browser's scrollTop does.
            // B-TREE-137 T-7bee4986
            @Test func aDensityChangeLeavesTheTreeWhereItStands() async throws {
                let harness = try ExplorerHarness.windowless()
                for index in 0..<120 {
                    try FileManager.default.createDirectory(
                        at: harness.folder.appending(String(format: "folder-%03d", index)),
                        withIntermediateDirectories: true)
                }
                let tab = try await harness.open(harness.folder.path)
                let sidebar = tab.sidebarController
                sidebar.model.rootTree(at: tab.folder.path)
                harness.layout(tab)
                tab.go(to: tab.folder.appendingPathComponent("folder-050"))
                #expect(await waitUntil { sidebar.model.selected?.filesystemPath?.hasSuffix("folder-050") == true })
                harness.layout(tab)
                let selected = try #require(sidebar.model.selected)
                let index = try #require(sidebar.tree.index(ofItem: selected))
                #expect(sidebar.tree.isFullyVisible(index))
                let before = sidebar.tree.scrollTop
                #expect(before > 0)
                tab.updatePreferences(["compactTreeView": .bool(true)])
                harness.layout(tab)
                try await Task.sleep(for: .milliseconds(100))
                #expect(sidebar.tree.scrollTop == before)
                // Back, and from the end of the rows, where the compact rows are shorter than the offset.
                tab.updatePreferences(["compactTreeView": .bool(false)])
                harness.layout(tab)
                sidebar.tree.scrollTop = sidebar.tree.contentHeight - sidebar.tree.visibleHeight
                let end = sidebar.tree.scrollTop
                tab.updatePreferences(["compactTreeView": .bool(true)])
                harness.layout(tab)
                try await Task.sleep(for: .milliseconds(100))
                #expect(sidebar.tree.scrollTop < end)
                #expect(abs(sidebar.tree.scrollTop - (sidebar.tree.contentHeight - sidebar.tree.visibleHeight)) < 1)
                await harness.close()
            }

            // F-832: the prefs before the first step that needs the window are the original's seeded preferences: its
            // tree reveals the folder with them, and the row stands last in view. The window made smaller after that
            // leaves the tree where it stands, the row below the fold (101, 106, 107).
            @Test func seededPreferencesComeBeforeTheWindowsSize() async throws {
                let harness = try ExplorerHarness.windowless()
                for index in 0..<60 {
                    try FileManager.default.createDirectory(
                        at: harness.folder.appending(String(format: "folder-%02d", index)),
                        withIntermediateDirectories: true)
                }
                let tab = try await harness.open(harness.folder.path)
                let sidebar = tab.sidebarController
                sidebar.model.rootTree(at: tab.folder.path)
                harness.layout(tab)
                tab.go(to: tab.folder.appendingPathComponent("folder-59"))
                #expect(await waitUntil { sidebar.model.selected?.filesystemPath?.hasSuffix("folder-59") == true })
                harness.layout(tab)
                let scratch = try TemporaryDirectory.shallow(prefix: "filetrail-steps")
                defer { scratch.remove() }
                let steps = try runner(
                    #"{"step": "window", "width": 760, "height": 520}, "#
                        + #"{"step": "prefs", "prefs": {"density": "compact"}}, {"step": "open", "path": "/"}"#,
                    tab: tab, in: scratch)
                let seeded = await steps.seedPreferences()
                #expect(Array(seeded.keys) == [1])
                #expect(seeded[1]?.status == .ok)
                #expect(tab.preferences.compactTreeView)
                harness.layout(tab)
                let selected = try #require(sidebar.model.selected)
                let index = try #require(sidebar.tree.index(ofItem: selected))
                let before = sidebar.tree.scrollTop
                #expect(sidebar.tree.isFullyVisible(index))
                #expect(abs(sidebar.tree.frame(ofRow: index).maxY - before - sidebar.tree.visibleHeight) < 1)
                let window = try #require(tab.window)
                window.setContentSize(NSSize(width: 760, height: 520))
                harness.layout(tab)
                try await Task.sleep(for: .milliseconds(100))
                #expect(sidebar.tree.scrollTop == before)
                #expect(!sidebar.tree.isFullyVisible(index))
                await harness.close()
            }
        }
    }
#endif
