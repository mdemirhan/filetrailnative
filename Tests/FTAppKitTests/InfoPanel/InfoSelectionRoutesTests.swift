// Ports by behavior row (components/GetInfoPanel.test.tsx, InfoRow.test.tsx, App.tsx:644-689) what the Info panel, the Info
// Row and the status text say of a real selection in a tab, the Opens with and Open With menus over this Mac's answers
// with the actions' spies, and Calculate Size from its routes
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct InfoSelectionRoutesTests {
        private func views(_ id: String, in tab: MainWindowController) -> [NSView] {
            guard let root = tab.window?.contentView?.superview else { return [] }
            return findViews(id, in: root)
        }

        private func texts(_ id: String, in tab: MainWindowController) -> [String] {
            views(id, in: tab).map(fieldText)
        }

        private func status(_ tab: MainWindowController) -> String {
            tab.content.contentShell.pathBarRow.status.stringValue
        }

        private func path(_ name: String, in tab: MainWindowController) throws -> String {
            try #require(tab.content.listed.first { $0.name == name }?.path)
        }

        /// Files of known sizes beside what the harness makes.
        private func files(_ sizes: [String: Int], in harness: ExplorerHarness) throws {
            for (name, size) in sizes {
                try Data(count: size).write(to: harness.folder.appending(name))
            }
        }

        // MARK: Counting

        // B-INFO-052: only real folders count as folders; a package and a link count as files; and only the entries shown
        // are counted.
        @Test func theSummaryCountsRealFoldersAndWhatIsShown() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createDirectory(
                at: harness.folder.appending("Tool.app/Contents"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: harness.folder.appending("Link"), withDestinationURL: harness.folder.appending("Alpha"))
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let selected = try ["Alpha", "Tool.app", "Link", "Beta"].map { try path($0, in: tab) }
            let beta = selected[3]
            tab.content.applySelection(ContentSelection(paths: selected, anchorPath: selected[0], leadPath: beta))
            #expect(await waitUntil { texts("infoPanel.subtitle", in: tab) == ["2 folders and 2 files"] })
            #expect(texts("infoPanel.name", in: tab) == ["4 items"])
            // Beta is left out by the filter, and stays selected as it has the lead.
            tab.content.setFilter("l")
            #expect(tab.content.selection.paths.count == 4)
            #expect(!tab.content.entries.contains { $0.path == beta })
            #expect(await waitUntil { texts("infoPanel.subtitle", in: tab) == ["1 folder and 2 files"] })
            #expect(texts("infoPanel.name", in: tab) == ["3 items"])
            await harness.close()
        }

        // B-INFO-091: the Info Row and the panel sum the entries shown; the status text the whole selection.
        @Test func theRowSumsWhatIsShownAndTheStatusTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["aaa.txt": 100, "aab.txt": 200, "zzz.txt": 400], in: harness)
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let selected = try ["aaa.txt", "aab.txt", "zzz.txt"].map { try path($0, in: tab) }
            tab.content.applySelection(
                ContentSelection(paths: selected, anchorPath: selected[0], leadPath: selected[2]))
            let all = SizeText.size(700)
            #expect(await waitUntil { texts("infoRow.fact", in: tab).contains(all) })
            #expect(await waitUntil { status(tab).hasSuffix(" selected · \(all)") })
            tab.content.setFilter("aa")
            #expect(tab.content.selection.paths.count == 3)
            let shown = SizeText.size(300)
            #expect(await waitUntil { texts("infoRow.fact", in: tab).contains(shown) })
            #expect(await waitUntil { texts("infoPanel.subtitle", in: tab) == ["2 files · \(shown)"] })
            #expect(status(tab).hasSuffix("3 of \(tab.content.listed.count) selected · \(all)"))
            await harness.close()
        }

        // T-9fa8ca8a B-INFO-075: a total that can't be told isn't shown: the row has its count and no fact.
        @Test func theRowHasNoFactWithoutATotal() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["aaa.txt": 100, "aab.txt": 200], in: harness)
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            let paths = try ["aaa.txt", "aab.txt"].map { try path($0, in: tab) }
            // Gone since the folder was read: its size never comes.
            try FileManager.default.removeItem(atPath: paths[1])
            tab.content.select(paths: paths)
            #expect(await waitUntil { texts("infoRow.name", in: tab) == ["2 items"] })
            try await Task.sleep(for: .milliseconds(300))
            harness.layout(tab)
            #expect(texts("infoRow.name", in: tab) == ["2 items"])
            #expect(views("infoRow.fact", in: tab).isEmpty)
            #expect(views("infoRow.folderSize.calculate", in: tab).isEmpty)
            await harness.close()
        }

        // T-9fa8ca8a B-INFO-075: several files in the row: their count and their total, nothing to calculate.
        @Test func theRowSumsSeveralFiles() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["aaa.txt": 100, "aab.txt": 200], in: harness)
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            tab.content.select(paths: try ["aaa.txt", "aab.txt"].map { try path($0, in: tab) })
            #expect(await waitUntil { texts("infoRow.name", in: tab) == ["2 items"] })
            #expect(await waitUntil { texts("infoRow.fact", in: tab).contains(SizeText.size(300)) })
            #expect(views("infoRow.folderSize.calculate", in: tab).isEmpty)
            await harness.close()
        }

        // T-49205480 B-INFO-076: folders among them: the row's link measures both, and it reads their total and counts.
        @Test func theRowsLinkMeasuresTheSelectedFolders() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["Alpha/one.txt": 100, "Beta/two.txt": 200, "aaa.txt": 400], in: harness)
            let tab = try await harness.open()
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            let alpha = try path("Alpha", in: tab)
            let beta = try path("Beta", in: tab)
            tab.content.select(paths: [alpha, beta, try path("aaa.txt", in: tab)])
            #expect(await waitUntil { texts("infoRow.name", in: tab) == ["3 items"] })
            harness.layout(tab)
            #expect(tab.folderSizes.cachedEntry(alpha) == nil)
            let link = try #require(views("infoRow.folderSize.calculate", in: tab).first as? TextLinkView)
            link.onClick?()
            #expect(
                await waitUntil { tab.folderSizes.readySize(alpha) == 100 && tab.folderSizes.readySize(beta) == 200 })
            let total = SizeText.size(700)
            #expect(
                await waitUntil {
                    harness.layout(tab)
                    return texts("infoRow.folderSize.size", in: tab).contains {
                        $0.hasPrefix(total) && $0.contains(" · ") && $0.contains("file")
                    }
                })
            await harness.close()
        }

        // MARK: Opens with

        /// The panel on a file, once macOS has answered about it.
        private func panelOnANote() async throws -> (
            ExplorerHarness, MainWindowController, InfoController, OpenWithLookup
        ) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [try path("note.txt", in: tab)])
            let info = try #require(tab.infoController)
            #expect(await waitUntil { info.openWithLookup != nil })
            return (harness, tab, info, try #require(info.openWithLookup))
        }

        /// The first row of the menu open for an app other than `app`.
        private func anotherApp(than app: String?, in menu: AppMenu) -> Int? {
            menu.items.firstIndex { $0.appPath != nil && $0.appPath != app }
        }

        // T-43f23ca5 B-INFO-064: the row says what it does; choosing the app a kind already opens in changes nothing, and
        // another changes the app of every file of the kind.
        @Test func opensWithChangesTheKindsAppOnlyForAnother() async throws {
            let (harness, tab, info, lookup) = try await panelOnANote()
            let current = try #require(lookup.defaultApp)
            let kind = try #require(lookup.kinds.first)
            var changed: [String] = []
            info.actions.setDefaultApplication = { appPath, contentType in
                changed.append("\(appPath) \(contentType)")
                return .success
            }
            info.actions.confirmAlways = { _, _ in true }
            harness.layout(tab)
            #expect(await waitUntil { !views("infoPanel.opensWith", in: tab).isEmpty })
            let row = try #require(views("infoPanel.opensWith", in: tab).first as? OpensWithPopupView)
            #expect(
                await waitUntil {
                    row.accessibilityLabel()?.hasPrefix("Opens with \(current.name): change the app for every ") == true
                        && row.accessibilityLabel()?.hasSuffix("every ") == false
                })
            #expect(texts("infoPanel.opensWith.name", in: tab) == [current.name])

            row.onClick()
            let menu = try #require(AppMenuPresenter.shared.menu)
            #expect(row.menuOpen)
            let same = try #require(menu.items.firstIndex { $0.appPath == current.path })
            menu.onChoose(same)
            try await Task.sleep(for: .milliseconds(100))
            #expect(changed.isEmpty)
            #expect(!row.menuOpen)

            row.onClick()
            let again = try #require(AppMenuPresenter.shared.menu)
            let other = try #require(anotherApp(than: current.path, in: again))
            let otherPath = try #require(again.items[other].appPath)
            again.onChoose(other)
            #expect(await waitUntil { !changed.isEmpty })
            #expect(changed == ["\(otherPath) \(kind.contentType)"])

            // Other… asks which app, and that one becomes the kind's.
            #expect(await waitUntil { info.openWithLookup != nil && !views("infoPanel.opensWith", in: tab).isEmpty })
            info.actions.pickApplication = { _ in (path: "/Applications/Picked.app", name: "Picked") }
            let shown = try #require(views("infoPanel.opensWith", in: tab).first as? OpensWithPopupView)
            shown.onClick()
            let third = try #require(AppMenuPresenter.shared.menu)
            third.onChoose(try #require(third.items.firstIndex { $0.title == "Other\u{2026}" }))
            #expect(await waitUntil { changed.count == 2 })
            #expect(changed.last == "/Applications/Picked.app \(kind.contentType)")
            await harness.close()
        }

        // B-INFO-064: with no app it reads None.
        @Test func opensWithReadsNoneWithNoApp() {
            let row = OpensWithPopupView()
            row.kindLabel = "Plain Text"
            row.app = nil
            #expect(findViews("infoPanel.opensWith.name", in: row).map(fieldText) == ["None"])
            #expect(row.accessibilityLabel() == "Opens with no app: change the app for every Plain Text")
            row.app = InfoOpenApp(path: "/Applications/Zed.app", name: "Zed")
            #expect(findViews("infoPanel.opensWith.name", in: row).map(fieldText) == ["Zed"])
            #expect(row.accessibilityLabel() == "Opens with Zed: change the app for every Plain Text")
        }

        // T-3ae2ee91 B-INFO-065: until macOS answers the row is there with a dash, so the rows under it don't move.
        @Test func theOpensWithRowWaitsForTheAnswer() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [try path("note.txt", in: tab)])
            // At once: the lookup starts 80 ms after the item changes.
            let labels = texts("infoPanel.row.label", in: tab)
            let row = try #require(labels.firstIndex(of: "Opens with"))
            #expect(labels[row + 1] == "Size")
            #expect(views("infoPanel.opensWith", in: tab).isEmpty)
            #expect(texts("infoPanel.row.value", in: tab).contains("—"))
            // Open doesn't wait for the answer.
            #expect(views("infoPanel.openGroup", in: tab).count == 1)
            await harness.close()
        }

        // T-1a141f6f: choosing a row of Open With runs that app on the file and closes the menu; an outside click and
        // Escape are the system menu's (D-022).
        @Test func openWithRunsTheChosenApp() async throws {
            let (harness, tab, info, lookup) = try await panelOnANote()
            let spy = OpenSpy()
            info.actions.opener = spy.opener
            harness.layout(tab)
            let group = try #require(views("infoPanel.openGroup", in: tab).first as? SplitOpenButton)
            #expect(await waitUntil { group.isSplit })
            group.onChevron()
            let menu = try #require(AppMenuPresenter.shared.menu)
            #expect(group.menuOpen)
            let choice = try #require(anotherApp(than: lookup.defaultApp?.path, in: menu))
            let app = try #require(menu.items[choice].appPath)
            menu.onChoose(choice)
            #expect(await waitUntil { !spy.all.isEmpty })
            #expect(spy.all == ["open -a \(app) \(try path("note.txt", in: tab))"])
            #expect(!group.menuOpen)
            await harness.close()
        }

        // MARK: Calculate Size and the status text

        // B-INFO-101: with nothing selected the status text takes in the size of the folder on screen as it comes.
        @Test func theStatusTextTakesInTheFoldersSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusContentPane)
            #expect(!status(tab).contains(" · "))
            tab.perform(.calculateSize)
            let folder = tab.shownFolderPath
            #expect(await waitUntil { tab.folderSizes.readySize(folder) != nil })
            let size = try #require(tab.folderSizes.readySize(folder))
            #expect(await waitUntil { status(tab) == "\(tab.content.listed.count) items · \(SizeText.size(size))" })
            await harness.close()
        }

        // B-INFO-165: in a view without a Size column the status text shows a selected folder's size.
        @Test func theStatusTextShowsTheSelectedFoldersSizeInIcons() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["Alpha/one.txt": 2000], in: harness)
            let tab = try await harness.open()
            tab.perform(.viewAsIcons)
            #expect(await waitUntil { tab.content.mode == .icons && !tab.content.entries.isEmpty })
            let alpha = try path("Alpha", in: tab)
            tab.content.select(paths: [alpha])
            tab.perform(.focusContentPane)
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(alpha) == 2000 })
            let listed = tab.content.listed.count
            #expect(await waitUntil { status(tab) == "1 of \(listed) selected · \(SizeText.size(2000))" })
            await harness.close()
        }

        // B-INFO-161: one folder is measured afresh, even with its size known.
        @Test func calculateSizeOnOneFolderMeasuresItAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["Alpha/one.txt": 1000], in: harness)
            let tab = try await harness.open()
            let alpha = try path("Alpha", in: tab)
            tab.content.select(paths: [alpha])
            tab.perform(.focusContentPane)
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(alpha) == 1000 })
            try files(["Alpha/two.txt": 500], in: harness)
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(alpha) == 1500 })
            await harness.close()
        }

        // B-INFO-161: of several, those known are left: one grown since keeps its old size while the other is measured.
        @Test func calculateSizeOnSeveralLeavesThoseKnown() async throws {
            let harness = try ExplorerHarness.windowless()
            try files(["Alpha/one.txt": 1000, "Beta/one.txt": 300], in: harness)
            let tab = try await harness.open()
            let alpha = try path("Alpha", in: tab)
            let beta = try path("Beta", in: tab)
            tab.content.select(paths: [alpha])
            tab.perform(.focusContentPane)
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(alpha) == 1000 })
            try files(["Alpha/two.txt": 500], in: harness)
            tab.content.select(paths: [alpha, beta])
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(beta) == 300 })
            #expect(tab.folderSizes.readySize(alpha) == 1000)
            await harness.close()
        }
    }
}
