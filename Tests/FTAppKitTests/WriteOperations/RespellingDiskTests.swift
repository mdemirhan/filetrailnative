// What a write made on a disk that stores a name otherwise than it was asked to: selected, and named in its row
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// "café" as it is typed, its "é" one scalar, and as HFS+ stores it whatever was typed, an "e" and its accent.
private let typed = "caf\u{E9}"
private let stored = "cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

private func touch(_ path: String) {
    let file = Darwin.open(path, O_CREAT | O_WRONLY, 0o644)
    #expect(file >= 0)
    close(file)
}

/// A disk that stores every name with its accents decomposed, as HFS+ does: the listing of `folder` gives the names
/// so, whatever the real disk under it keeps. Everything else is the real disk's, which takes either spelling.
private struct DecomposingDisk: ExplorerFileSystem {
    let folder: String
    private let real = NativeFileSystem()

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        let records = try real.readDirectory(path)
        guard DiskPath(path) == DiskPath(folder) else { return records }
        return records.map { record in
            var record = record
            record.name = record.name.decomposedStringWithCanonicalMapping
            return record
        }
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(path) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

/// The paths the disk was asked to name, in order; its next answer can be held until the test lets it go.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [DiskPath] = []
    private var gate: DispatchSemaphore?
    private var waiting = false

    func add(_ path: DiskPath) {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            asked.append(path)
            waiting = self.gate != nil
            return self.gate
        }
        gate?.wait()
    }

    var paths: [DiskPath] { lock.withLock { asked } }
    var isHolding: Bool { lock.withLock { waiting } }

    func holdNext() { lock.withLock { gate = DispatchSemaphore(value: 0) } }

    func letGo() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer {
                self.gate = nil
                waiting = false
            }
            return self.gate
        }
        gate?.signal()
    }
}

extension ExplorerWindowlessTests {
    /// A write names what it made as it was asked to, and HFS+ stores an accent its own way: the row of what was made
    /// is spelled otherwise than the write's own path. It is selected all the same, and named in its row where the
    /// write leaves its name open.
    @MainActor
    @Suite struct RespellingDiskTests {
        /// A window on a fresh folder of an HFS+ volume holding "a.txt", and the folder as the disk spells it.
        private func onHFS(_ body: (WritingWindow, String) async throws -> Void) async throws {
            try await DiskImage.withSharedVolume(.hfs) { volume in
                let folder = try #require(realpath(volume.path, nil).map { String(cString: $0) })
                touch(folder + "/a.txt")
                let window = try await WritingWindow.open(folder)
                #expect(await waitUntil { window.tab.content.entries.count == 1 && !window.tab.isNavigating })
                try await body(window, folder)
                await window.close()
            }
        }

        /// The row named `name` byte for byte.
        private func row(_ name: String, in tab: MainWindowController) -> DirectoryEntry? {
            tab.content.listed.first { DiskPath($0.name) == DiskPath(name) }
        }

        /// Whether the row named `name` is listed and is the one item selected, by its own entry.
        private func isSelected(_ name: String, in tab: MainWindowController) -> Bool {
            guard let row = row(name, in: tab), !tab.isWriteLocked else { return false }
            return bytes(tab.content.selection.paths) == bytes([row.path])
                && bytes(tab.content.selectedEntries.map(\.path)) == bytes([row.path])
        }

        @Test(.tags(.diskImage), .diskImages)
        func aFileRenamedToANameWithAnAccentIsSelected() async throws {
            try await onHFS { window, folder in
                let tab = window.tab
                tab.content.select(paths: [folder + "/a.txt"])
                _ = await tab.writeActions?.rename(folder + "/a.txt", to: typed + ".txt")
                #expect(await waitUntil { isSelected(stored + ".txt", in: tab) })
                // The disk keeps the name its own way, and the row is spelled as the disk has it.
                #expect(row(typed + ".txt", in: tab) == nil)
                #expect(window.recorder.shown.isEmpty)
            }
        }

        // New Folder's own name has no accent; the one typed into its row has, and the folder stays selected.
        @Test(.tags(.diskImage), .diskImages)
        func aNewFolderNamedWithAnAccentInItsRowIsSelected() async throws {
            try await onHFS { window, _ in
                let tab = window.tab
                tab.content.focusList()
                tab.perform(.newFolder)
                #expect(await waitUntil { tab.content.inlineRename != nil && !tab.isWriteLocked })
                #expect(isSelected("untitled folder", in: tab))
                tab.content.renameSubmitted(typed)
                #expect(await waitUntil { tab.content.inlineRename == nil && isSelected(stored, in: tab) })
                #expect(window.recorder.shown.isEmpty)
            }
        }

        // New Folder with Selection: its folder is selected with its name open, and named with an accent it stays
        // selected.
        @Test(.tags(.diskImage), .diskImages)
        func aFolderMadeOfTheSelectionAndNamedWithAnAccentIsSelected() async throws {
            try await onHFS { window, folder in
                let tab = window.tab
                tab.content.select(paths: [folder + "/a.txt"])
                tab.content.focusList()
                tab.perform(.newFolderWithSelection)
                #expect(await waitUntil { tab.content.inlineRename != nil && !tab.isWriteLocked })
                #expect(isSelected("untitled folder", in: tab))
                #expect(row("a.txt", in: tab) == nil)
                tab.content.renameSubmitted(typed)
                #expect(await waitUntil { tab.content.inlineRename == nil && isSelected(stored, in: tab) })
                #expect(window.recorder.shown.isEmpty)
            }
        }

        // A file made under a name with an accent (a template's) is selected, and its name opens in its row.
        @Test(.tags(.diskImage), .diskImages)
        func aFileMadeUnderANameWithAnAccentIsSelectedAndNamedInItsRow() async throws {
            try await onHFS { window, folder in
                let tab = window.tab
                _ = await tab.writeActions?.newFile(in: folder, named: typed + ".txt", contents: Data("x".utf8))
                #expect(await waitUntil { tab.content.inlineRename != nil && isSelected(stored + ".txt", in: tab) })
                let made = try #require(row(stored + ".txt", in: tab))
                #expect(tab.content.inlineRename.map { DiskPath($0.path) } == DiskPath(made.path))
                tab.content.renameCancelled()
                #expect(window.recorder.shown.isEmpty)
            }
        }

        // A file copied from a disk that keeps its name as typed, pasted here: the copy is selected.
        @Test(.tags(.diskImage), .diskImages)
        func anItemPastedUnderANameWithAnAccentIsSelected() async throws {
            try await onHFS { window, folder in
                let tab = window.tab
                let source = try #require(realpath(window.harness.folder.path, nil).map { String(cString: $0) })
                touch(source + "/" + typed + ".txt")
                tab.go(to: source)
                #expect(await waitUntil { !tab.isNavigating && row(typed + ".txt", in: tab) != nil })
                tab.content.select(paths: [source + "/" + typed + ".txt"])
                tab.content.focusList()
                tab.perform(.copySelection)
                #expect(bytes(tab.services.clipboard.contents.sourcePaths) == bytes([source + "/" + typed + ".txt"]))
                tab.go(to: folder)
                #expect(await waitUntil { !tab.isNavigating && row("a.txt", in: tab) != nil })
                tab.perform(.pasteSelection)
                #expect(await waitUntil { isSelected(stored + ".txt", in: tab) })
                #expect(window.recorder.shown.isEmpty)
            }
        }

        // On this Mac's own disk, with a listing that spells names as HFS+ would: what the write made is selected by
        // the name the disk gives for it, and the disk is asked only for what has no row spelled as the write named it.
        @Test func theDiskIsAskedOnlyForWhatHasNoRowAndItsAnswerIsSelected() async throws {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let folder = NodePath.join(tab.folderPath, "Respelled")
            #expect(mkdir(folder, 0o755) == 0)
            touch(folder + "/a.txt")
            touch(folder + "/z.txt")
            let service = DirectoryService(fileSystem: DecomposingDisk(folder: folder))
            tab.servicesOverride = ExplorerServices(
                directoryService: service, iconStore: TestServices.icons, clipboard: harness.windows.clipboard,
                preferences: harness.channel)
            let operations = AppWriteOperations(
                userData: try TemporaryDirectory.shallow(prefix: "respelling-writes").url, directoryService: service,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            let recorder = DialogRecorder()
            operations.dialogs = recorder.dialogs
            let asked = Asked()
            tab.activePane.nameOnDisk = { path in
                asked.add(path)
                return path.parent.appending(path.name.decomposedStringWithCanonicalMapping)
            }
            tab.perform(.viewAsDetails)
            tab.go(to: folder)
            #expect(await waitUntil { !tab.isNavigating && row("a.txt", in: tab) != nil })
            harness.layout(tab)

            // A name without an accent has its row, and the disk is not asked.
            tab.content.select(paths: [folder + "/a.txt"])
            _ = await tab.writeActions?.rename(folder + "/a.txt", to: "b.txt")
            #expect(await waitUntil { isSelected("b.txt", in: tab) })
            #expect(asked.paths.isEmpty)

            // A name with one: its row is spelled as the disk has it, and the disk is asked for it, once.
            _ = await tab.writeActions?.rename(folder + "/b.txt", to: typed + ".txt")
            #expect(await waitUntil { isSelected(stored + ".txt", in: tab) })
            #expect(asked.paths == bytes([folder + "/" + typed + ".txt"]))

            // A file made under such a name is selected and named in its row, the disk asked once for both.
            _ = await tab.writeActions?.newFile(in: folder, named: "na\u{EF}ve.txt", contents: Data("x".utf8))
            #expect(await waitUntil { tab.content.inlineRename != nil && isSelected("nai\u{308}ve.txt", in: tab) })
            let made = try #require(row("nai\u{308}ve.txt", in: tab))
            #expect(tab.content.inlineRename.map { DiskPath($0.path) } == DiskPath(made.path))
            #expect(asked.paths == bytes([folder + "/" + typed + ".txt", folder + "/na\u{EF}ve.txt"]))
            tab.content.renameCancelled()

            // Something picked while the disk is asked stays picked.
            asked.holdNext()
            _ = await tab.writeActions?.rename(folder + "/" + stored + ".txt", to: "th\u{E9}.txt")
            #expect(await waitUntil { asked.isHolding })
            tab.content.select(paths: [folder + "/z.txt"])
            asked.letGo()
            #expect(await waitUntil { asked.paths.count == 3 && row("the\u{301}.txt", in: tab) != nil })
            try? await Task.sleep(for: .milliseconds(200))
            #expect(bytes(tab.content.selection.paths) == bytes([folder + "/z.txt"]))
            #expect(recorder.shown.isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
