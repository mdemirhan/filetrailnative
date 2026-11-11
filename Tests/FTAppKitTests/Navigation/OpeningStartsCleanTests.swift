// Opening a folder starts clean: no first item selected, a new order read without a step, and the reads and folder
// changes that overlap an opening, over a tab whose window is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// Holds one folder's listing back, once read, until the test lets it go, and counts the listings read of each folder, so
/// a test can be sure an opening is under way when it acts, and that nothing was read after.
private final class HeldFolder: ExplorerFileSystem, @unchecked Sendable {
    private let held: String
    private let real = NativeFileSystem()
    private let condition = NSCondition()
    private var isHeld = true
    private var counts: [String: Int] = [:]
    private var lastReads: [String: ContinuousClock.Instant] = [:]

    init(_ held: String) { self.held = held }

    func reads(of path: String) -> Int {
        condition.withLock { counts[path, default: 0] }
    }

    func lastRead(of path: String) -> ContinuousClock.Instant? {
        condition.withLock { lastReads[path] }
    }

    func letGo() {
        condition.withLock {
            isHeld = false
            condition.broadcast()
        }
    }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        let started = ContinuousClock.now
        let records = try real.readDirectory(path)
        condition.withLock {
            counts[path, default: 0] += 1
            lastReads[path] = started
            while path == held && isHeld { condition.wait() }
        }
        return records
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(path) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct OpeningStartsCleanTests: SidebarTesting {
        private func names(_ tab: MainWindowController) -> [String] { tab.content.entries.map(\.name) }

        // MARK: Nothing selected

        // However it is opened from the sidebar or the list, a folder with
        // items opens with none of them selected.
        @Test func noFirstItemIsSelectedAfterAFolderOpensFromTheTreeAFavoriteOrTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            tab.perform(.viewAsDetails)
            harness.layout(tab)
            let model = sidebar(tab).model
            func expectNothingSelected() {
                #expect(!tab.content.entries.isEmpty)
                #expect(tab.selectedPaths.isEmpty)
                #expect(tab.content.selection.leadPath == nil)
                #expect(ListProbe(tab: tab).table?.selectedRowIndexes.isEmpty == true)
            }

            let alpha = listed(harness, "Alpha")
            #expect(await waitUntil { model.nodes[alpha] != nil })
            model.selectItem(.filesystem(alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            harness.layout(tab)
            expectNothingSelected()

            let beta = listed(harness, "Beta")
            model.selectItem(.favorite(beta))
            #expect(await waitUntil { tab.shownFolderPath == beta })
            harness.layout(tab)
            expectNothingSelected()

            tab.go(to: URL(fileURLWithPath: listed(harness, "")))
            #expect(await waitUntil { tab.shownFolderPath == listed(harness, "") })
            let gamma = try #require(tab.content.entries.first { $0.name == "Gamma" })
            tab.content.select(paths: [gamma.path])
            tab.content.focusList()
            tab.perform(.openSelection)
            #expect(await waitUntil { tab.shownFolderPath == listed(harness, "Gamma") })
            harness.layout(tab)
            expectNothingSelected()
            await harness.close()
        }

        // MARK: Reading again with another order

        // The order flips and back, in place: no step in the history.
        @Test func foldersFirstReadsTheFolderAgainInTheNewOrderWithoutAStep() async throws {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("aaa.txt"), atomically: true, encoding: .utf8)
            let tab = try await harness.open(listed(harness, ""))
            let first = names(tab).filter { $0 != "app-state.json" }
            #expect(first.prefix(4) == ["Alpha", "Beta", "Gamma", "aaa.txt"])
            let history = tab.navigationHistory.paths

            tab.perform(.toggleFoldersFirst)
            #expect(await waitUntil { self.names(tab).first == "aaa.txt" })
            #expect(tab.navigationHistory.paths == history)

            tab.perform(.toggleFoldersFirst)
            #expect(await waitUntil { self.names(tab).first == "Alpha" })
            #expect(tab.navigationHistory.paths == history)
            await harness.close()
        }

        // MARK: A read that overlaps an opening

        private func reading(
            _ fileSystem: any ExplorerFileSystem, _ tab: MainWindowController, _ harness: ExplorerHarness
        ) {
            tab.servicesOverride = ExplorerServices(
                directoryService: DirectoryService(fileSystem: fileSystem), iconStore: TestServices.icons,
                clipboard: harness.windows.clipboard, preferences: harness.channel)
        }

        // Refresh and a write's end, while another folder is being opened from the tree: neither takes the tree
        // or the list back to the old folder, and neither reads anything.
        @Test func aRefreshOrAWritesEndDuringAnOpeningLeaveItAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = listed(harness, "")
            let tab = try await harness.open(root)
            await rooted(tab, harness)
            let model = sidebar(tab).model
            let beta = listed(harness, "Beta")
            #expect(await waitUntil { model.nodes[beta] != nil })
            let files = HeldFolder(beta)
            defer { files.letGo() }
            reading(files, tab, harness)

            model.selectItem(.filesystem(beta))
            #expect(await waitUntil { files.reads(of: beta) == 1 })
            #expect(tab.isNavigating)
            #expect(model.selected == .filesystem(beta))
            #expect(tab.shownFolderPath == root)

            tab.perform(.refreshOrApplySearchSort)
            await settle()
            #expect(model.selected == .filesystem(beta))
            #expect(tab.pendingChange == nil)
            tab.readAgain()
            await settle()
            #expect(model.selected == .filesystem(beta))
            #expect(tab.pendingChange == nil)
            #expect(tab.isNavigating)

            files.letGo()
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            #expect(names(tab) == ["Inner"])
            // Long enough for anything put off for the opening (250 ms) to have come back.
            try await Task.sleep(for: .milliseconds(300))
            #expect(tab.shownFolderPath == beta)
            #expect(names(tab) == ["Inner"])
            #expect(model.selected == .filesystem(beta))
            #expect(files.reads(of: root) == 0)
            #expect(files.reads(of: beta) == 1)
            await harness.close()
        }

        // A change heard while that same folder is being opened is read again 250 ms later, not at once: that
        // read may have started before the change.
        @Test func aChangeHeardDuringAnOpeningOfThatFolderIsReadAgainShortlyAfter() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = listed(harness, "")
            let tab = try await harness.open(root)
            let files = HeldFolder(root)
            defer { files.letGo() }
            reading(files, tab, harness)

            tab.go(to: URL(fileURLWithPath: root))
            #expect(await waitUntil { files.reads(of: root) == 1 })
            #expect(tab.isNavigating)
            // Made after the opening read the folder, and told as the folder watch tells it: only the read waiting for the
            // opening to end can find it.
            try "x".write(toFile: root + "/late.txt", atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.forgetFolderListings(root, changedPaths: nil)
            let told = ContinuousClock.now
            tab.reload(changedPaths: nil)
            #expect(tab.pendingChange != nil)

            files.letGo()
            #expect(await waitUntil { self.names(tab).contains("late.txt") })
            #expect(tab.pendingChange == nil)
            #expect(files.reads(of: root) == 2)
            #expect(told.duration(to: try #require(files.lastRead(of: root))) >= .milliseconds(250))
            await harness.close()
        }

        // A change to the folder left behind while another is being opened is dropped, and nothing reads the new folder
        // for it.
        @Test func aChangeHeardDuringAnOpeningOfAnotherFolderIsDropped() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = listed(harness, "")
            let tab = try await harness.open(root)
            // Rooted here, so the tree has no folders above to read as it follows.
            await rooted(tab, harness)
            let beta = listed(harness, "Beta")
            let files = HeldFolder(beta)
            defer { files.letGo() }
            reading(files, tab, harness)

            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { files.reads(of: beta) == 1 })
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: nil))
            #expect(tab.pendingChange == nil)

            files.letGo()
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            try "x".write(toFile: beta + "/late.txt", atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.forgetFolderListings(beta, changedPaths: nil)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!names(tab).contains("late.txt"))
            #expect(files.reads(of: beta) == 1)
            #expect(files.reads(of: root) == 0)
            await harness.close()
        }

        // Changes held back for a folder that was left meanwhile are forgotten when the hold ends.
        @Test func changesHeldBackForAFolderLeftMeanwhileAreForgotten() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = listed(harness, "")
            let tab = try await harness.open(root)
            let beta = listed(harness, "Beta")
            tab.holdFolderChanges(.dialog, true)
            tab.reload(changedPaths: [root + "/note.txt"])
            #expect(tab.pendingChange != nil)
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })

            let files = HeldFolder("")
            reading(files, tab, harness)
            tab.holdFolderChanges(.dialog, false)
            #expect(tab.pendingChange == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(files.reads(of: beta) == 0)
            await harness.close()
        }

        // A change told of another folder than the one on screen is not read.
        @Test func aChangeToAnotherFolderIsIgnored() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = listed(harness, "")
            let tab = try await harness.open(root)
            tab.holdFolderChanges(.dialog, true)
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: listed(harness, "Beta"), changedPaths: nil))
            #expect(tab.pendingChange == nil)
            harness.windows.folderChanged(windowID: tab.windowID, FolderChange(path: root, changedPaths: nil))
            #expect(tab.pendingChange != nil)
            tab.holdFolderChanges(.dialog, false)
            await harness.close()
        }
    }
}
