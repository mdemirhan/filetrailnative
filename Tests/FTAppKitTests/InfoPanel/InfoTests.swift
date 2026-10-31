// Covers the path bar, the Info Row, the Info panel and the folder sizes in an explorer window that is never shown,
// by feature row (App.commands.test.tsx's Info panel cases, App.menusAndTree.test.tsx's Calculate Size cases,
// ContentPane.test.tsx's path bar)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoTests {
        func texts(_ id: String, in tab: MainWindowController) -> [String] {
            guard let root = tab.window?.contentView?.superview else { return [] }
            return findViews(id, in: root).map(fieldText)
        }

        func path(_ name: String, in tab: MainWindowController) -> String {
            tab.content.entries.first { $0.name == name }?.path ?? ""
        }

        func select(_ names: [String], in tab: MainWindowController, harness: ExplorerHarness) {
            tab.content.select(paths: names.compactMap { name in tab.content.entries.first { $0.name == name }?.path })
        }

        // The Info panel's Always Open With asks first, then goes to the actions' own seams: never this Mac's defaults.
        // B-INFO-061 T-8727f2e5
        @Test func alwaysOpenWithFromThePanelUsesItsSeams() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let actions = try #require(tab.infoController?.actions)
            let spy = OpenSpy()
            actions.opener = spy.opener
            var changed: [String] = []
            actions.setDefaultApplication = { appPath, contentType in
                changed.append("\(appPath) \(contentType)")
                return .success
            }
            actions.confirmAlways = { _, _ in true }
            let kind = OpenWithKind(contentType: "public.plain-text", name: "Plain Text Document", isFolder: false)
            let action = OpenWithAction.application(
                id: "zed", label: "Zed", appPath: "/Applications/Zed.app", appName: "Zed", always: true)
            actions.runOpenWith(action, paths: ["/x/a.txt"], kind: kind)
            #expect(await waitUntil { !spy.all.isEmpty })
            #expect(changed == ["/Applications/Zed.app public.plain-text"])
            actions.changeDefaultApp(action, kind: kind)
            #expect(await waitUntil { changed.count == 2 })
            await harness.close()
        }

        // Copy Path and Copy Name put the text on the pasteboard they were given, not on the user's clipboard.
        // B-INFO-057
        @Test func copyUsesItsPasteboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let actions = try #require(tab.infoController?.actions)
            let board = NSPasteboard.withUniqueName()
            actions.pasteboard = board
            #expect(actions.copy("/x/a.txt", what: "Path"))
            #expect(board.string(forType: .string) == "/x/a.txt")
            board.releaseGlobally()
            await harness.close()
        }

        // `openPathExternally` only logs a failed open; the others show the original's notices, word for word.
        // T-8a7d2ddb
        @Test func thePanelsFailedActionsShowTheOriginalsNotices() async throws {
            struct Refused: Error, LocalizedError {
                var errorDescription: String? { "It refused." }
            }
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let actions = try #require(tab.infoController?.actions)
            let spy = OpenSpy()
            actions.opener = SystemOpener(
                openPath: { path in
                    spy.record("open \(path)")
                    return "No application"
                },
                openWithApplication: { _, _ in throw Refused() }, reveal: { _ in throw Refused() }, openURL: { _ in })
            var notices: [String: String] = [:]
            actions.notice = { notices[$0] = $1 }
            let editor = tab.preferences.defaultTextEditor.appName

            actions.openExternally("/x/a.txt")
            #expect(await waitUntil { !spy.all.isEmpty })
            actions.openInTerminal("/x/a.txt")
            actions.showInFinder("/x/a.txt")
            actions.edit("/x/a.txt")
            #expect(await waitUntil { notices.count == 3 })
            #expect(
                notices == [
                    "Couldn’t Open Terminal": "File Trail couldn’t open the terminal app in this folder.",
                    "Couldn’t Show in Finder": "Finder couldn’t show it. It refused.",
                    "Couldn’t Open in \(editor)": "File Trail couldn’t open it in \(editor). It refused.",
                ])
            await harness.close()
        }

        // A file activated in the window goes to the tab's seam (the harness's stands in for macOS).
        @Test func anActivatedFileOpensThroughTheTabsSeam() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            var opened: [String] = []
            tab.openFile = { opened.append($0.lastPathComponent) }
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.open([note])
            #expect(opened == ["note.txt"])
            await harness.close()
        }

        // T-209d6f52 F-697 F-748 F-820 B-INFO-001 B-INFO-066 B-INFO-069: the panel and the row follow the selection.
        // B-INFO-090 B-INFO-194 B-NAV-205
        @Test func thePanelAndTheRowDescribeTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            // Nothing selected: the folder on screen.
            let folderName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == [folderName] })
            #expect(texts("infoRow.name", in: tab) == [folderName])
            select(["note.txt"], in: tab, harness: harness)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["note.txt"] })
            #expect(texts("infoRow.name", in: tab) == ["note.txt"])
            #expect(await waitUntil { texts("infoPanel.row.label", in: tab).contains("Permissions") })
            #expect(await waitUntil { tab.content.contentShell.infoRow.height == 30 })
            await harness.close()
        }

        // F-805 B-INFO-009: Show Info points the panel at an item that is not selected, and a selection takes it back.
        // F-832 B-INFO-065: a press on the chevron of the split Open button opens the Open With menu under the button, its
        // right edge on the button's.
        // T-8727f2e5
        @Test func theChevronOpensTheOpenWithMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !tab.content.entries.isEmpty }
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            select(["note.txt"], in: tab, harness: harness)
            let content = try #require(tab.window?.contentView)
            let group = try #require(findViews("infoPanel.openGroup", in: content).first as? SplitOpenButton)
            #expect(await waitUntil { group.isSplit })
            group.layoutSubtreeIfNeeded()
            let window = try #require(tab.window)
            let point = group.chevron.convert(
                NSPoint(x: group.chevron.bounds.midX, y: group.chevron.bounds.midY), to: nil)
            let root = try #require(window.contentView?.superview)
            // The press lands on the button itself, which takes the first click of a window not in front: a plain view
            // there would only bring the window forward, and the menu would not open.
            let pressed = try #require(root.hitTest(root.convert(point, from: nil)))
            #expect(pressed === group)
            let down = try #require(MouseEvents.event(.leftMouseDown, at: point, in: window))
            #expect(pressed.acceptsFirstMouse(for: down))
            let up = try #require(MouseEvents.event(.leftMouseUp, at: point, in: window))
            pressed.mouseDown(with: down)
            pressed.mouseUp(with: up)
            let menu = try #require(AppMenuPresenter.shared.menu)
            #expect(menu.identifier == "contextMenu.submenu")
            #expect(menu.nsMenu.minimumWidth == 200)
            #expect(group.menuOpen)
            AppMenuPresenter.shared.close()
            await harness.close()
        }

        // B-NAV-205 B-SEL-018
        @Test func showInfoPointsThePanelAtAnUnselectedItem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            info.showInfo(for: path("Beta", in: tab))
            harness.layout(tab)
            #expect(tab.panels.propertiesOpen)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["Beta"] })
            select(["Gamma"], in: tab, harness: harness)
            #expect(await waitUntil { texts("infoPanel.name", in: tab) == ["Gamma"] })
            await harness.close()
        }

        // B-INFO-166: the Info Row's buttons act on what the row shows, not on the item the panel is open on.
        @Test func theRowsButtonsActOnWhatTheRowShows() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            select(["Alpha"], in: tab, harness: harness)
            let alpha = path("Alpha", in: tab)
            info.showInfo(for: path("Beta", in: tab))
            #expect(info.targetOverride == path("Beta", in: tab))
            #expect((tab.folderSizes.cachedEntry(alpha) ?? .idle) == .idle)
            info.row.onCalculate()
            #expect(await waitUntil { (tab.folderSizes.cachedEntry(alpha) ?? .idle) != .idle })
            await harness.close()
        }

        // B-INFO-049: free space is read again when the folder changes, and when the clock ticks.
        @Test(.windowlessAlone) func freeSpaceIsReadAgain() async throws {
            final class Reads: @unchecked Sendable {
                let lock = NSLock()
                var count = 0
                func add() -> Int64 {
                    lock.lock()
                    defer { lock.unlock() }
                    count += 1
                    return Int64(count) * 1_000_000
                }
                var current: Int {
                    lock.lock()
                    defer { lock.unlock() }
                    return count
                }
            }
            let reads = Reads()
            let original = InfoController.volumeSizes
            InfoController.volumeSizes = { _ in
                var sizes = VolumeInfo.sizes(atPath: "/")
                sizes.availableBytes = reads.add()
                return sizes
            }
            defer { InfoController.volumeSizes = original }
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            info.showInfo(for: "/")
            #expect(await waitUntil { reads.current == 1 })
            info.update()
            try await Task.sleep(for: .milliseconds(100))
            #expect(reads.current == 1)
            tab.reload()
            #expect(await waitUntil { reads.current >= 2 })
            await harness.close()
        }

        // B-INFO-111 B-VIEW-006 T-01ad97ab: a press on a segment or a separator gives the list the keyboard, as a press on
        // the bar beside them does.
        @Test func aPressOnASegmentOrSeparatorGivesTheListTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(harness.folder.appending("Alpha").path)
            let bar = tab.content.contentShell.pathBarRow
            #expect(await waitUntil { bar.pathBar.segments.last?.label == "Alpha" })
            harness.layout(tab)
            let window = try #require(tab.window)
            for id in ["pathBar.segment", "pathBar.separator"] {
                window.makeFirstResponder(nil)
                let view = try #require(findViews(id, in: bar).first)
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                view.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: point, in: window)))
                #expect(window.firstResponder === tab.content.focusView)
            }
            await harness.close()
        }

        // T-a322b806 B-INFO-202: Show Info on an app measures it; it stays the one measured while the panel shows it.
        @Test func showInfoMeasuresTheItemItPutInThePanel() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Tool.app/Contents"), withIntermediateDirectories: true)
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            let app = path("Tool.app", in: tab)
            info.showInfo(for: app)
            #expect(await waitUntil { (tab.folderSizes.cachedEntry(app) ?? .idle) != .idle })
            await harness.close()
        }

        // B-INFO-008 B-INFO-202: a change from outside keeps Show Info's item, and so its measurement.
        // B-NAV-206 B-SEL-018
        @Test func anOutsideChangeKeepsShowInfosItem() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Tool.app/Contents"), withIntermediateDirectories: true)
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            let app = path("Tool.app", in: tab)
            info.showInfo(for: app)
            #expect(await waitUntil { (tab.folderSizes.cachedEntry(app) ?? .idle) != .idle })
            var read = false
            let watching = tab.observe { if $0 == .folder { read = true } }
            tab.reload()
            #expect(await waitUntil { read })
            withExtendedLifetime(watching) {}
            #expect(info.targetOverride == app)
            await harness.close()
        }

        // B-INFO-008: so does one that takes a selected item away: only a selection made in the list lets the item go.
        @Test func anOutsideChangeThatTakesASelectedItemKeepsShowInfosItem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            let alpha = path("Alpha", in: tab)
            select(["note.txt"], in: tab, harness: harness)
            info.showInfo(for: alpha)
            try FileManager.default.removeItem(at: harness.folder.appending("note.txt"))
            tab.services.directoryService.cache.clear()
            tab.reload()
            #expect(await waitUntil { tab.content.selection.paths.isEmpty })
            #expect(info.targetOverride == alpha)
            await harness.close()
        }

        // B-INFO-008: Refresh is no change from outside (`refreshDirectory`): the item goes.
        // B-NAV-206
        @Test func aRefreshLetsShowInfosItemGo() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let info = try #require(tab.infoController)
            info.showInfo(for: path("Alpha", in: tab))
            tab.refresh()
            #expect(await waitUntil { info.targetOverride == nil })
            await harness.close()
        }

        // T-33598034 B-INFO-203: with only the Info Row open, the one app selected is measured.
        @Test func theInfoRowAloneMeasuresTheSelectedApp() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Tool.app/Contents"), withIntermediateDirectories: true)
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            let app = path("Tool.app", in: tab)
            select(["Tool.app"], in: tab, harness: harness)
            #expect(await waitUntil { (tab.folderSizes.cachedEntry(app) ?? .idle) != .idle })
            await harness.close()
        }

        // T-650e6f58 T-df07c21f F-824 B-INFO-160 B-INFO-161: Calculate Size measures the selected folders; with nothing
        // selected, the folder on screen.
        @Test func calculateSizeMeasuresTheSelectedFolders() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            let alpha = path("Alpha", in: tab)
            let beta = path("Beta", in: tab)
            select(["Alpha", "Beta", "note.txt"], in: tab, harness: harness)
            tab.perform(.focusContentPane)
            tab.perform(.calculateSize)
            #expect(
                await waitUntil { tab.folderSizes.readySize(alpha) != nil && tab.folderSizes.readySize(beta) != nil })
            #expect(tab.folderSizes.readySize(tab.currentFolder.path) == nil)
            tab.content.select(paths: [])
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(tab.currentFolder.path) != nil })
            #expect(
                await waitUntil {
                    texts("infoRow.folderSize.size", in: tab).contains { $0.contains(" · ") && $0.contains("folder") }
                })
            await harness.close()
        }

        // T-3c985219 T-487ad066 F-743 F-805 B-INFO-120 B-INFO-121 B-INFO-123 B-INFO-124: a separator lists the folders next to the
        // one that follows it, with that one ticked; choosing another goes there.
        // T-b514ec81
        @Test func aSeparatorsMenuStepsSideways() async throws {
            let harness = try ExplorerHarness.windowless()
            let alphaPath = harness.folder.appending("Alpha").path
            // The listing reports the real path of a temporary folder (/private/var).
            let tab = try await harness.open(alphaPath.hasPrefix("/var/") ? "/private" + alphaPath : alphaPath)
            let bar = tab.content.contentShell.pathBarRow
            let parentName = harness.folder.path.split(separator: "/").last.map(String.init) ?? ""
            #expect(await waitUntil { bar.pathBar.segments.last?.label == "Alpha" })
            harness.layout(tab)
            let separators = findViews("pathBar.separator", in: bar).compactMap { $0 as? PathSeparatorView }
            let separator = try #require(separators.last)
            #expect(separator.accessibilityLabel() == "Folders in \(parentName)")
            separator.onClick?()
            #expect(await waitUntil { AppMenuPresenter.shared.menu?.identifier == "pathBarMenu" })
            let menu = try #require(AppMenuPresenter.shared.menu)
            #expect(menu.rows.map(\.title).sorted() == ["Alpha", "Beta", "Gamma"])
            #expect(menu.rows.filter { $0.checked == true }.map(\.title) == ["Alpha"])
            let beta = try #require(menu.items.firstIndex { $0.title == "Beta" })
            menu.onChoose(beta)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Beta" })
            #expect(!AppMenuPresenter.shared.isOpen)
            await harness.close()
        }

        // T-c3292381 F-745 B-INFO-113: Return goes to the typed path.
        // T-5f7427b6
        @Test func returnGoesToTheTypedPath() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let bar = tab.content.contentShell.pathBarRow
            bar.beginEditing()
            let target = harness.folder.appending("Gamma").path
            bar.editor.field.stringValue = target
            bar.editor.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: bar.editor.field))
            let editor = try #require(bar.editor.field.currentEditor() as? NSTextView)
            _ = bar.editor.control(
                bar.editor.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Gamma" })
            #expect(!bar.isEditing)
            await harness.close()
        }
    }
}
