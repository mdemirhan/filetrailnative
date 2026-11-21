// What each source of a path calls an item whose name holds an accent, on each kind of disk
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// How a text spells its accents.
enum AccentSpelling: String, Sendable {
    /// No accent in it: one spelling only.
    case plain
    /// Every accent one scalar with its letter.
    case composed
    /// Every accent a scalar of its own after its letter.
    case decomposed
    case mixed

    init(of text: String) {
        let composed = text.precomposedStringWithCanonicalMapping
        let decomposed = text.decomposedStringWithCanonicalMapping
        let isComposed = text.utf8.elementsEqual(composed.utf8)
        let isDecomposed = text.utf8.elementsEqual(decomposed.utf8)
        self = isComposed && isDecomposed ? .plain : isComposed ? .composed : isDecomposed ? .decomposed : .mixed
    }
}

/// The paths the system's events name under a folder, as it sends them.
final class RawFolderEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "filetrail.tests.raw-folder-events")

    init?(root: String) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let events = Unmanaged<RawFolderEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            events.lock.withLock {
                for index in 0..<count {
                    if let path = paths[index] as? String { events.seen.append(path) }
                }
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    var paths: [String] { lock.withLock { seen } }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

extension ExplorerWindowlessTests {
    /// The app holds a path as its disk spells it, and on some disks the system's calls don't agree on that. A folder
    /// and a file in it are made under names with an accent, stored composed and stored decomposed, and each source
    /// the app takes a path from is asked what it calls them. APFS gives the name as stored everywhere and HFS+
    /// decomposed everywhere. FAT32 and exFAT give every name decomposed where a folder is read (`readdir`,
    /// `getattrlistbulk`). Asked about the one item (`getattrlist`, `realpath`, so a listing's own path and every path
    /// respelled where it comes in) and in the system's events, they give the spelling the item was made or first
    /// looked up by since the disk was mounted: here the one each item is made by, in this mount. FAT32's `rename`
    /// finds its source only by that spelling, and exFAT's `unlink` likewise. `HeldNamesTests` has a disk mounted
    /// again, where the first to ask decides.
    ///
    /// What the system says is measured on this macOS and written down so that a change in it is noticed: the app's
    /// one spelling on such a disk, the one the disk holds, is decided from it. What the app's own readers of a
    /// folder say (a listing's rows, the tree's rows, a search's results) is then that name on every disk. A release
    /// measures it (`ReleaseTests`): what it measures changes with macOS, not with the app.
    @MainActor
    @Suite(.enabled(if: ReleaseTests.enabled)) struct AccentSpellingSourcesTests {
        private static let both = [AccentSpelling.composed, .decomposed]

        /// What each source says, for a name stored composed; a name stored decomposed is decomposed everywhere, on
        /// every disk, and differs only in the last two lines.
        private static let storedComposed: [DiskImage.Kind: [String: String]] = [
            .apfs: [
                "readdir names it": "composed", "getattrlist names it": "composed",
                "getattrlist names it, asked the other way": "composed",
                "realpath of the file, asked the other way": "composed/composed",
                "a listing's own path, asked the other way": "composed",
                "a listing's row": "composed/composed", "the tree's row of the folder": "composed",
                "fd from the folder above": "composed/composed", "fd from the folder": "composed/composed",
                "the system's events": "composed/composed", "the app's watch names it": "composed",
                "lstat by the other spelling": "found", "rename by the other spelling": "found",
                "unlink by the other spelling": "found", "the other spelling beside it": "the same item",
            ],
            .hfs: [
                "readdir names it": "decomposed", "getattrlist names it": "decomposed",
                "getattrlist names it, asked the other way": "decomposed",
                "realpath of the file, asked the other way": "decomposed/decomposed",
                "a listing's own path, asked the other way": "decomposed",
                "a listing's row": "decomposed/decomposed", "the tree's row of the folder": "decomposed",
                "fd from the folder above": "decomposed/decomposed", "fd from the folder": "decomposed/decomposed",
                "the system's events": "decomposed/decomposed", "the app's watch names it": "decomposed",
                "lstat by the other spelling": "found", "rename by the other spelling": "found",
                "unlink by the other spelling": "found", "the other spelling beside it": "the same item",
            ],
            .fat32: [
                "readdir names it": "decomposed", "getattrlist names it": "composed",
                "getattrlist names it, asked the other way": "composed",
                "realpath of the file, asked the other way": "composed/composed",
                "a listing's own path, asked the other way": "composed",
                "a listing's row": "composed/composed", "the tree's row of the folder": "composed",
                "fd from the folder above": "composed/composed", "fd from the folder": "composed/composed",
                "the system's events": "composed/composed", "the app's watch names it": "composed",
                "lstat by the other spelling": "found", "rename by the other spelling": "not found",
                "unlink by the other spelling": "found", "the other spelling beside it": "the same item",
            ],
            .exfat: [
                "readdir names it": "decomposed", "getattrlist names it": "composed",
                "getattrlist names it, asked the other way": "composed",
                "realpath of the file, asked the other way": "composed/composed",
                "a listing's own path, asked the other way": "composed",
                "a listing's row": "composed/composed", "the tree's row of the folder": "composed",
                "fd from the folder above": "composed/composed", "fd from the folder": "composed/composed",
                "the system's events": "composed/composed", "the app's watch names it": "composed",
                "lstat by the other spelling": "found", "rename by the other spelling": "found",
                "unlink by the other spelling": "not found", "the other spelling beside it": "the same item",
            ],
        ]

        private func expected(_ stored: AccentSpelling, on disk: DiskImage.Kind) -> [String: String] {
            guard var expected = Self.storedComposed[disk] else { return [:] }
            guard stored == .decomposed else { return expected }
            // Stored decomposed, every source gives it decomposed; what a call finds by the other spelling stays.
            for (source, said) in expected where said.contains("composed") {
                expected[source] = said.replacingOccurrences(of: "decomposed", with: "composed")
                    .replacingOccurrences(of: "composed", with: "decomposed")
            }
            return expected
        }

        private func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// How the part of `path` after `top` is spelled, part by part ("composed/decomposed").
        private func spelled(_ path: String?, below top: String) -> String {
            guard let path else { return "none" }
            guard path.utf8.starts(with: (top + "/").utf8) else { return "outside: " + path }
            let rest = String(decoding: path.utf8.dropFirst(top.utf8.count + 1), as: UTF8.self)
            return rest.split(separator: "/").map { AccentSpelling(of: String($0)).rawValue }.joined(separator: "/")
        }

        private func spellings(_ names: [String]) -> String {
            Set(names.map { AccentSpelling(of: $0).rawValue }).sorted().joined(separator: ",")
        }

        private func found(_ status: Int32) -> String {
            status == 0 ? "found" : errno == ENOENT ? "not found" : String(cString: strerror(errno))
        }

        private func search(_ runtime: FdSearchRuntime, for query: String, in root: String) throws
            -> [SearchResultItem]
        {
            let started = runtime.startSearch(SearchRequest(rootPath: root, query: query))
            var items: [SearchResultItem] = []
            var cursor = 0
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                let update = try runtime.getUpdate(jobId: started.jobId, cursor: cursor)
                items += update.items
                cursor = update.nextCursor
                if update.done { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return items
        }

        @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.apfs, .hfs, .fat32, .exfat])
        func whatEachSourceCallsAnAccentedName(_ disk: DiskImage.Kind) async throws {
            try await DiskImage.withSharedVolume(disk) { volume in
                let top = try #require(real(volume.path))
                for stored in Self.both {
                    let said = try await measure(stored, under: top)
                    let expected = expected(stored, on: disk)
                    for (source, value) in expected.sorted(by: { $0.key < $1.key }) {
                        #expect(said[source] == value, "\(disk.rawValue), stored \(stored.rawValue): \(source)")
                    }
                    #expect(said.count == expected.count)
                }
            }
        }

        /// A folder and a file in it stored `stored`, and what each source calls them.
        private func measure(_ stored: AccentSpelling, under top: String) async throws -> [String: String] {
            func spell(_ text: String, otherwise: Bool = false) -> String {
                (stored == .composed) != otherwise
                    ? text.precomposedStringWithCanonicalMapping : text.decomposedStringWithCanonicalMapping
            }
            // Each way of storing has names of its own, so the two don't meet in one folder.
            let folderName = stored == .composed ? "caf\u{E9}" : "na\u{EF}ve"
            let fileName = stored == .composed ? "r\u{E9}sum\u{E9}.txt" : "consomm\u{E9}.txt"
            let folder = top + "/" + spell(folderName)
            let file = folder + "/" + spell(fileName)
            let otherFolder = top + "/" + spell(folderName, otherwise: true)
            let otherFile = otherFolder + "/" + spell(fileName, otherwise: true)
            AccentDisk.makeFolder(folder)
            AccentDisk.write(Data("x".utf8), to: file)
            var said: [String: String] = [:]

            let listedNames = AccentDisk.listedNames(in: folder).map { String(decoding: $0, as: UTF8.self) }
            said["readdir names it"] = spellings(listedNames.filter { $0 == fileName })
            said["getattrlist names it"] = spellings(DiskPath.nameOnDisk(file).map { [$0] } ?? [])
            said["getattrlist names it, asked the other way"] = spellings(
                DiskPath.nameOnDisk(otherFile).map { [$0] } ?? [])
            said["realpath of the file, asked the other way"] = spelled(real(otherFile), below: top)
            let second = mkdir(otherFolder, 0o755)
            said["the other spelling beside it"] = second == 0 ? "a second item" : "the same item"
            if second == 0 { rmdir(otherFolder) }

            let service = DirectoryService()
            let listing = try await service.snapshot(path: otherFolder)
            said["a listing's own path, asked the other way"] = spelled(listing.path, below: top)
            said["a listing's row"] = spelled(listing.entries.first { $0.name == fileName }?.path, below: top)
            let tree = try await service.treeChildren(path: top)
            said["the tree's row of the folder"] = spelled(
                tree.children.first { $0.name == folderName }?.path, below: top)

            let runtime = FdSearchRuntime(fdBinaryPath: try FdBinary.resolveBundledPath())
            let query = stored == .composed ? "sum" : "som"
            let fromAbove = try search(runtime, for: query, in: top).first { $0.name == fileName }
            said["fd from the folder above"] = spelled(fromAbove?.path, below: top)
            let fromTheFolder = try search(runtime, for: query, in: listing.path).first { $0.name == fileName }
            said["fd from the folder"] = spelled(fromTheFolder?.path, below: top)
            runtime.close()

            // The system's events for the folder, watched by its real path: a file made in it.
            if let watched = real(folder), let events = RawFolderEvents(root: watched) {
                try? await Task.sleep(for: .milliseconds(300))
                AccentDisk.write(Data("y".utf8), to: folder + "/" + spell("cr\u{E8}me.txt"))
                _ = await waitUntil(timeout: .seconds(5)) { events.paths.contains { $0.hasSuffix(".txt") } }
                events.stop()
                said["the system's events"] =
                    Set(events.paths.filter { $0.hasSuffix(".txt") }.map { spelled($0, below: top) }).sorted()
                    .joined(separator: ",")
            }
            // The app's own watch of the folder, as a pane has it watched: by the listing's path of it.
            var heard: [String] = []
            var started = false
            let stop = FSEventsFolderWatcher.watchFolder(
                path: listing.path, onChange: { if let name = $0 { heard.append(name) } }, onFail: {},
                onStart: { started = true })
            _ = await waitUntil(timeout: .seconds(5)) { started }
            try? await Task.sleep(for: .milliseconds(300))
            AccentDisk.write(Data("z".utf8), to: folder + "/" + spell("p\u{E2}t\u{E9}.txt"))
            _ = await waitUntil(timeout: .seconds(5)) { !heard.isEmpty }
            stop()
            said["the app's watch names it"] = spellings(heard)

            // What a call finds by the spelling the name isn't stored in.
            var info = stat()
            said["lstat by the other spelling"] = found(lstat(otherFile, &info))
            let moved = folder + "/moved.txt"
            let renamed = rename(otherFile, moved)
            said["rename by the other spelling"] = found(renamed)
            if renamed == 0 { _ = rename(moved, file) }
            said["unlink by the other spelling"] = found(unlink(otherFile))
            return said
        }
    }
}
