import CFileTrail
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// The tests that walk real folders, one at a time: each walk puts four threads on the disk, and the tests of the other
/// modules that wait on short timers don't stand ten of them at once.
@Suite(.serialized) enum RealWalks {}

/// A finished walk with every folder it reported: those handed over as they finished, and the rest that came
/// with the result.
struct MeasuredWalk {
    var result: FolderSizeResult
    var batches: [FinishedFolders]

    /// Every folder reported, by path.
    var dirs: [String: FolderTotals] {
        var all: [String: FolderTotals] = [:]
        for batch in batches {
            for folder in batch.dirs {
                all[folder.path] = folder.totals
            }
        }
        for folder in result.dirs {
            all[folder.path] = folder.totals
        }
        return all
    }

    /// The batches in order, the result's folders last.
    var allBatches: [FinishedFolders] {
        batches + [FinishedFolders(dev: result.dev, dirs: result.dirs)]
    }
}

@MainActor
func measure(
    _ native: NativeFolderSize = NativeFolderSize(), _ path: String, background: Bool = false
) async throws -> MeasuredWalk {
    var batches: [FinishedFolders] = []
    let result = try await native.getFolderSize(path, background: background) { batches.append($0) }.value
    return MeasuredWalk(result: result, batches: batches)
}

/// Made with the system calls, which keep a name as spelled (Foundation would spell an accent its own way, and
/// the walker reports names exactly).
func write(_ path: String, _ size: Int) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let bytes = [UInt8](repeating: UInt8(ascii: "x"), count: size)
    var written = 0
    while written < size {
        let count = bytes[written...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        written += count
    }
}

/// `mkdir -p`.
func makeFolder(_ path: String) throws {
    var made = path.hasPrefix("/") ? "" : "."
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        made += "/" + part
        if mkdir(made, 0o755) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Files and folders of the first suite's tree:
///   root/ a.txt (10), b.txt (20), sub/ c.txt (5), deep/ d.txt (100), empty/, link -> a.txt
private func makeTree(_ root: String) throws {
    try makeFolder("\(root)/sub/deep")
    try makeFolder("\(root)/empty")
    try write("\(root)/a.txt", 10)
    try write("\(root)/b.txt", 20)
    try write("\(root)/sub/c.txt", 5)
    try write("\(root)/sub/deep/d.txt", 100)
    try FileManager.default.createSymbolicLink(atPath: "\(root)/link", withDestinationPath: "\(root)/a.txt")
}

private func totals(_ walk: MeasuredWalk, _ path: String) -> FolderTotals? {
    walk.dirs[path]
}

extension RealWalks {
    @MainActor @Suite struct NativeFolderSizeTests {
        @Test func returnsTotalLogicalSizeDiskTotalFileAndFolderCountsAndSubDirStats() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                let walk = try await measure(NativeFolderSize(), root)
                let result = walk.result

                // Symlink logical size varies, so we check file count and sub-dir structure instead.
                #expect(result.fileCount == 5)  // a.txt, b.txt, c.txt, d.txt, link
                #expect(result.folderCount == 3)  // sub, sub/deep, empty
                #expect(result.total >= 135)  // at least 10+20+5+100
                #expect(result.diskTotal >= result.total)  // disk >= logical

                // Sub-directory entries exist for sub, sub/deep, and empty
                let dirs = walk.dirs
                #expect(dirs["\(root)/sub"] != nil)
                #expect(dirs["\(root)/sub/deep"] != nil)
                #expect(dirs["\(root)/empty"] != nil)
                #expect(dirs[root] == nil)  // root itself excluded

                // sub/deep has d.txt = [100, diskBytes, 1]
                let deep = try #require(dirs["\(root)/sub/deep"])
                #expect(deep.sizeBytes == 100)
                #expect(deep.fileCount == 1)
                #expect(deep.folderCount == 0)

                // sub has c.txt(5) + deep(100) = 105 total, 2 files
                let sub = try #require(dirs["\(root)/sub"])
                #expect(sub.sizeBytes == 105)
                #expect(sub.fileCount == 2)
                #expect(sub.folderCount == 1)

                // empty has 0 bytes, 0 files
                let empty = try #require(dirs["\(root)/empty"])
                #expect(empty.sizeBytes == 0 && empty.fileCount == 0 && empty.folderCount == 0)
            }
        }

        @Test func countsAPackagesContentsOneByOneLikeAnyFolder() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                try makeFolder("\(root)/Tool.app/Contents/MacOS")
                try write("\(root)/Tool.app/Contents/Info.plist", 1)
                try write("\(root)/Tool.app/Contents/MacOS/Tool", 1)
                let result = try await measure(NativeFolderSize(), root).result

                #expect(result.fileCount == 7)  // the 5 above + Info.plist, Tool
                #expect(result.folderCount == 6)  // the 3 above + Tool.app, Contents, MacOS
            }
        }

        @Test func canBeCancelled() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                try makeTree(directory.path)
                // Start a calculation and immediately cancel
                let native = NativeFolderSize()
                let walk = native.getFolderSize(directory.path, background: false) { _ in }
                native.cancelFolderSize()

                let error = await #expect(throws: FolderSizeError.self) { try await walk.value }
                #expect(error?.message.lowercased().contains("cancelled") == true)
            }
        }

        @Test func handlesNonExistentPaths() async {
            let error = await #expect(throws: FolderSizeError.self) {
                try await measure(NativeFolderSize(), "/nonexistent/path/xyz")
            }
            #expect(error?.code == "ENOENT")
            #expect(error?.message == "ENOENT: No such file or directory, folder size '/nonexistent/path/xyz'")
        }

        @Test func countsALinkToAFolderInsideAsAFileAndDoesntFollowIt() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                try FileManager.default.createSymbolicLink(atPath: "\(root)/to-sub", withDestinationPath: "\(root)/sub")
                let walk = try await measure(NativeFolderSize(), root)

                #expect(walk.result.fileCount == 6)  // the 5 above + to-sub
                #expect(walk.result.folderCount == 3)
                #expect(!walk.dirs.keys.contains { $0.hasPrefix("\(root)/to-sub") })
            }
        }

        // As Finder's Get Info does: each link to a file is counted, as a copy would copy it.
        @Test func countsAFileWithSeveralHardLinksOnceForEachLink() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                try FileManager.default.linkItem(atPath: "\(root)/sub/deep/d.txt", toPath: "\(root)/sub/d-again.txt")
                let walk = try await measure(NativeFolderSize(), root)

                #expect(walk.result.fileCount == 6)
                #expect(totals(walk, "\(root)/sub")?.sizeBytes == 205)
            }
        }

        @Test func countsAFolderItCantOpenAsOneWithNothingInItAndFinishesTheFolderHoldingIt() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                let locked = "\(root)/sub/locked"
                try makeFolder(locked)
                try write("\(locked)/secret.txt", 1_000)
                chmod(locked, 0o000)
                defer { chmod(locked, 0o755) }
                let walk = try await measure(NativeFolderSize(), root)

                #expect(walk.result.folderCount == 4)  // sub, sub/deep, empty, sub/locked
                #expect(walk.result.fileCount == 5)
                #expect(walk.dirs[locked] == nil)
                let sub = try #require(walk.dirs["\(root)/sub"])
                #expect(sub.sizeBytes == 105 && sub.fileCount == 2 && sub.folderCount == 2)
            }
        }

        @Test func namesTheFoldersInsideAFolderGivenWithASlashAtItsEndWithOneSlash() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                try makeTree(root)
                let walk = try await measure(NativeFolderSize(), "\(root)/")

                #expect(walk.dirs.keys.sorted() == ["\(root)/empty", "\(root)/sub", "\(root)/sub/deep"].sorted())
            }
        }

        // /usr/share/snmp is a firmlink to /System/Volumes/Data/usr/share/snmp: it is measured where it is browsed, and
        // /System/Volumes/Data, where the data volume is mounted, is left out, so measuring / counts each folder once.
        @Test(.enabled(if: FileManager.default.fileExists(atPath: "/usr/share/snmp/mibs")))
        func goesThroughAFirmlinkMeasuringItWhereItIsBrowsed() async throws {
            let walk = try await measure(NativeFolderSize(), "/usr/share")

            #expect(walk.dirs.keys.contains("/usr/share/snmp/mibs"))
        }

        @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data/Users")))
        func leavesOutAFolderAnotherVolumeIsMountedOnThoughItHasTheSameDevice() async throws {
            let walk = try await measure(NativeFolderSize(), "/System/Volumes")

            #expect(!walk.dirs.keys.contains { $0.hasPrefix("/System/Volumes/Data") })
        }

        @Test func measuresInTheBackgroundAsItDoesInFront() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                try makeTree(directory.path)
                let native = NativeFolderSize()
                let front = try await measure(native, directory.path)
                let background = try await measure(native, directory.path, background: true)

                #expect(background.dirs == front.dirs)
                #expect(background.result.total == front.result.total)
                #expect(background.result.diskTotal == front.result.diskTotal)
                #expect(background.result.fileCount == front.result.fileCount)
                #expect(background.result.folderCount == front.result.folderCount)
                #expect(background.result.dev == front.result.dev)
            }
        }

        // Each folder is opened from the one holding it, so no path is too long to open; the paths are only put together
        // for the result.
        @Test func measuresFoldersWhosePathsAreLongerThanPATHMAX() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-test") { directory in
                let root = directory.path
                func name(_ level: Int) -> String {
                    String(format: "%03d", level) + String(repeating: "n", count: 240)
                }
                let levels = 6
                // Made from the bottom up, each folder moved into a new one, so that no path used is longer than two names.
                var top = "\(root)/chain-0"
                try makeFolder(top)
                try write("\(top)/leaf.txt", 33)
                for level in 1..<levels {
                    let holder = "\(root)/chain-\(level)"
                    try makeFolder(holder)
                    try FileManager.default.moveItem(atPath: top, toPath: "\(holder)/\(name(level))")
                    top = holder
                }
                // Taken apart the way it was made: a path that long can't be removed by name.
                defer {
                    for level in stride(from: levels - 1, through: 1, by: -1) {
                        let apart = "\(root)/apart-\(level)"
                        try? FileManager.default.moveItem(atPath: "\(top)/\(name(level))", toPath: apart)
                        try? FileManager.default.removeItem(atPath: top)
                        top = apart
                    }
                    try? FileManager.default.removeItem(atPath: top)
                }
                let walk = try await measure(NativeFolderSize(), top)
                let names = (0..<(levels - 1)).map { name(levels - 1 - $0) }
                let deepest = ([top] + names).joined(separator: "/")

                #expect(deepest.utf8.count > 1024)
                #expect(walk.result.folderCount == levels - 1)
                #expect(walk.result.total == 33)
                #expect(walk.dirs[deepest]?.sizeBytes == 33)
            }
        }

        @Test func handlesEmptyDirectories() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-empty") { directory in
                let walk = try await measure(NativeFolderSize(), directory.path)

                #expect(walk.result.total == 0)
                #expect(walk.result.diskTotal == 0)
                #expect(walk.result.fileCount == 0)
                #expect(walk.result.folderCount == 0)
                #expect(walk.dirs.isEmpty)
            }
        }

        @Test func reportsTheDeviceOfTheDiskWalked() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-dev") { directory in
                var info = stat()
                #expect(stat(directory.path, &info) == 0)
                let walk = try await measure(NativeFolderSize(), directory.path)

                #expect(walk.result.dev == Int64(info.st_dev))
            }
        }

        // An app from the Dock may open 256 files at once. A folder waiting its turn holds no descriptor, so a folder
        // with more subfolders than that is measured whole. The limit is lowered for the whole test process, so it
        // leaves room above what is open now for the tests running beside this one.
        @Test func measuresAFolderWithMoreSubfoldersThanTheAppMayOpenFilesAtOnce() async throws {
            try await withTemporaryDirectory(prefix: "native-fs-many") { directory in
                let root = directory.path
                // 1,200 folders of 3 holding 3 each: every folder the walk lists hands it more to queue, so the queue
                // grows faster than four threads empty it.
                let count = 1_200
                for index in 0..<count {
                    for middle in 0..<3 {
                        for inner in 0..<3 {
                            try makeFolder("\(root)/f\(index)/m\(middle)/i\(inner)")
                        }
                    }
                }
                let openNow = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
                var saved = rlimit()
                #expect(getrlimit(RLIMIT_NOFILE, &saved) == 0)
                var lowered = saved
                lowered.rlim_cur = rlim_t(max(256, openNow + 512))
                try #require(lowered.rlim_cur < rlim_t(count))
                #expect(setrlimit(RLIMIT_NOFILE, &lowered) == 0)
                defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }

                let walk = try await measure(NativeFolderSize(), root)

                #expect(walk.result.folderCount == count * 13)
                #expect(walk.dirs.count == count * 13)
            }
        }
    }
}

/// A tree of 5 + 25 + 125 = 155 folders, each with a few small files: enough folders that a walk is usually taken
/// from more than once before it ends.
private func makeFinishedTree(_ dir: String, depth: Int) throws {
    for index in 0..<5 {
        let child = "\(dir)/d\(index)"
        try makeFolder(child)
        for file in 0...index {
            try write("\(child)/f\(file).txt", 10 * (file + 1) + depth)
        }
        if depth > 1 {
            try makeFinishedTree(child, depth: depth - 1)
        }
    }
}

/// What measuring each folder should give, read with lstat: size, files, folders.
@discardableResult
private func expectedSizes(_ dir: String, _ out: inout [String: [Int64]]) throws -> [Int64] {
    var size: Int64 = 0
    var files: Int64 = 0
    var folders: Int64 = 0
    for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
        let path = "\(dir)/\(name)"
        var info = stat()
        #expect(lstat(path, &info) == 0)
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = try expectedSizes(path, &out)
            size += child[0]
            files += child[1]
            folders += child[2] + 1
        } else {
            size += Int64(info.st_size)
            files += 1
        }
    }
    out[dir] = [size, files, folders]
    return [size, files, folders]
}

/// Each reported folder once, with the sizes it should have.
@discardableResult
private func expectReportedOnce(_ batches: [FinishedFolders], _ expected: [String: [Int64]]) -> Set<String> {
    var seen = Set<String>()
    for batch in batches {
        for folder in batch.dirs {
            #expect(!seen.contains(folder.path), "\(folder.path) reported twice")
            seen.insert(folder.path)
            let totals = folder.totals
            #expect([totals.sizeBytes, Int64(totals.fileCount), Int64(totals.folderCount)] == expected[folder.path])
        }
    }
    return seen
}

extension RealWalks {
    @MainActor @Suite struct NativeFolderSizeFinishedFoldersTests {
        private func withTree(_ body: (String, [String: [Int64]]) async throws -> Void) async throws {
            try await withTemporaryDirectory(prefix: "native-fs-finished") { directory in
                try makeFinishedTree(directory.path, depth: 3)
                var expected: [String: [Int64]] = [:]
                try expectedSizes(directory.path, &expected)
                try await body(directory.path, expected)
            }
        }

        @Test func reportsEveryFolderOnceAfterTheFoldersInsideItAndLeavesTheRestForTheResult() async throws {
            try await withTree { root, expected in
                let walk = try await measure(NativeFolderSize(), root)
                let result = walk.result

                let seen = expectReportedOnce(walk.allBatches, expected)
                #expect(seen.count == expected.count - 1)
                #expect(!seen.contains(root))
                #expect([result.total, Int64(result.fileCount), Int64(result.folderCount)] == expected[root])
                for batch in walk.batches {
                    #expect(batch.dev == result.dev)
                }
                // A folder is finished only once everything inside it is: never in a batch before one of its sub-folders.
                var batchOf: [String: Int] = [:]
                for (index, batch) in walk.allBatches.enumerated() {
                    for folder in batch.dirs {
                        batchOf[folder.path] = index
                    }
                }
                for (path, index) in batchOf {
                    let parent = (path as NSString).deletingLastPathComponent
                    if parent != root {
                        let parentBatch = try #require(batchOf[parent])
                        #expect(parentBatch >= index)
                    }
                }
            }
        }

        // The finished folders are streamed as the walk finishes them, and a walk that has ended has nothing more to
        // say.
        @Test func hasNothingMoreToDeliverOnceAWalkHasEndedOrBeenCancelled() async throws {
            try await withTree { root, _ in
                let native = NativeFolderSize()
                var delivered = 0
                _ = try await native.getFolderSize(root, background: false) { _ in delivered += 1 }.value

                let cancelled = native.getFolderSize(root, background: false) { _ in delivered += 1 }
                native.cancelFolderSize()
                let error = await #expect(throws: FolderSizeError.self) { try await cancelled.value }
                #expect(error?.code == "ECANCELLED")
                let afterCancel = delivered
                try await Task.sleep(for: .milliseconds(50))
                #expect(delivered == afterCancel)
            }
        }

        @Test func keepsOnlyWholeFoldersWhenCancelledPartWay() async throws {
            try await withTree { root, expected in
                let native = NativeFolderSize()
                var batches: [FinishedFolders] = []
                let walk = native.getFolderSize(root, background: false) { batch in
                    batches.append(batch)
                    native.cancelFolderSize()
                }
                do {
                    let result = try await walk.value
                    // The walk ended before the first batch could cancel it.
                    batches.append(FinishedFolders(dev: result.dev, dirs: result.dirs))
                } catch let error as FolderSizeError {
                    #expect(error.code == "ECANCELLED")
                }
                expectReportedOnce(batches, expected)
            }
        }

        @Test func namesAFolderWithANewlineQuoteBackslashOrLettersBeyondASCIIInItsNameExactly() async throws {
            try await withTree { root, _ in
                let names = ["line\nbreak \"quoted\" \\ tab\t", "Résumé 日本語 🎉", "two\\\\slashes"]
                for (index, name) in names.enumerated() {
                    try makeFolder("\(root)/\(name)")
                    try write("\(root)/\(name)/f.txt", 7 + index)
                }
                let walk = try await measure(NativeFolderSize(), root)
                for (index, name) in names.enumerated() {
                    #expect(walk.dirs["\(root)/\(name)"]?.sizeBytes == Int64(7 + index))
                }
            }
        }

        @Test func handsFinishedFoldersToTheCallbackAndTheRestWithTheResult() async throws {
            try await withTree { root, expected in
                let walk = try await measure(NativeFolderSize(), root)
                let seen = expectReportedOnce(walk.allBatches, expected)
                #expect(seen.count == expected.count - 1)
            }
        }

        @Test func handsWhatACancelledWalkFinishedToTheCallbackBeforeRejecting() async throws {
            try await withTree { root, expected in
                let native = NativeFolderSize()
                var batches: [FinishedFolders] = []
                let walk = native.getFolderSize(root, background: false) { batches.append($0) }
                native.cancelFolderSize()
                let error = await #expect(throws: FolderSizeError.self) { try await walk.value }
                #expect(error?.code == "ECANCELLED")
                expectReportedOnce(batches, expected)
            }
        }
    }
}

/// One item as the write operations read it when they take it off the folders that held it.
private func itemSize(_ path: String) throws -> ItemSize {
    var item = ft_item_size()
    let errnum = ft_item_size_of(path, &item)
    guard errnum == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errnum) ?? .EIO) }
    let kind: ItemSize.Kind =
        switch item.kind {
        case FT_ITEM_FILE: .file
        case FT_ITEM_FOLDER: .folder
        default: .other
        }
    return ItemSize(kind: kind, sizeBytes: item.size_bytes, diskBytes: item.disk_bytes, dev: item.dev)
}

extension RealWalks {
    @MainActor @Suite struct NativeItemSizeTests {
        private func withItems(_ body: (String) async throws -> Void) async throws {
            try await withTemporaryDirectory(prefix: "native-fs-item") { directory in
                let root = directory.path
                try makeFolder("\(root)/sub")
                try write("\(root)/a.bin", 12_345)
                try write("\(root)/sub/b.txt", 300)
                try FileManager.default.createSymbolicLink(atPath: "\(root)/link", withDestinationPath: "sub")
                #expect(mkfifo("\(root)/pipe", 0o644) == 0)
                try await body(root)
            }
        }

        // What the folders that hold an item lose when it is removed must be what measuring them counted for it.
        @Test func countsEachItemAsMeasuringItsFolderDoes() async throws {
            try await withItems { root in
                let walk = try await measure(NativeFolderSize(), root)
                var items: [ItemSize] = []
                for name in ["a.bin", "link", "pipe", "sub"] {
                    items.append(try itemSize("\(root)/\(name)"))
                }
                #expect(items.map(\.kind) == [.file, .file, .other, .folder])
                #expect(Set(items.map(\.dev)) == [walk.result.dev ?? -1])

                let sub = try #require(walk.dirs["\(root)/sub"])
                let files = items.filter { $0.kind == .file }
                #expect(files.reduce(sub.sizeBytes) { $0 + $1.sizeBytes } == walk.result.total)
                #expect(files.reduce(sub.diskBytes) { $0 + $1.diskBytes } == walk.result.diskTotal)
                #expect(files.count + sub.fileCount == walk.result.fileCount)
                #expect(1 + sub.folderCount == walk.result.folderCount)
            }
        }

        @Test func failsForAnItemThatIsGone() async throws {
            try await withItems { root in
                #expect(throws: POSIXError(.ENOENT)) { try itemSize("\(root)/missing") }
            }
        }
    }
}
