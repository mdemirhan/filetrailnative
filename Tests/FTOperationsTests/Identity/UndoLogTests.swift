// Port of packages/core/src/fs/undoLog.test.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private let disk = PosixFileSystem()
private let reader = StampReader(disk)

private func write(_ url: URL, _ text: String) throws {
    try Data(text.utf8).write(to: url)
}

private func makeFolder(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
}

struct ItemIdTests {
    // T-80e8e785 F-520 F-925
    @Test func isKnownOnlyWhenTheDiskGivesAUsableId() {
        #expect(itemIdOf(dev: 1, ino: 2) == ItemId(dev: 1, ino: 2))
        #expect(itemIdOf(dev: nil, ino: 2) == nil)
        // FAT and exFAT give empty files ids a number can't hold.
        #expect(itemIdOf(dev: 1, ino: UInt64.max) == nil)
    }

    // T-0d404d7a F-520
    @Test func isNullForAnItemThatCantBeRead() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            #expect(readItemId(disk.lstat, root.appending("gone").path) == nil)
        }
    }

    // T-53270e4c F-520
    @Test func tellsTheSameItemOnlyByTwoKnownIds() {
        #expect(sameItemId(ItemId(dev: 1, ino: 2), ItemId(dev: 1, ino: 2)))
        #expect(!sameItemId(ItemId(dev: 1, ino: 2), ItemId(dev: 3, ino: 2)))
        #expect(!sameItemId(ItemId(dev: 1, ino: 2), ItemId(dev: 1, ino: 3)))
        #expect(!sameItemId(nil, nil))
        #expect(!sameItemId(ItemId(dev: 1, ino: 2), nil))
    }

    @Test func readsAFolderIdOncePerOperation() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            var ids = FolderIds()
            var reads = 0
            let stat: (String) throws -> WriteServiceStats = { path in
                reads += 1
                return try disk.stat(path)
            }
            let first = ids.id(stat, root.path)
            let second = ids.id(stat, root.path)
            #expect(first != nil)
            #expect(first == second)
            #expect(reads == 1)
        }
    }
}

struct ReadItemStampTests {
    // T-c55b06fa F-520
    @Test func tellsFilesFoldersAndLinksApartAndCountsWhatAFolderHolds() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            try write(root.appending("a.txt"), "abc")
            try makeFolder(root.appending("Folder"))
            try write(root.appending("Folder/inside.txt"), "")
            try FileManager.default.createSymbolicLink(
                atPath: root.appending("link").path, withDestinationPath: "a.txt")

            let file = try #require(readItemStamp(reader, root.appending("a.txt").path))
            #expect(file.kind == .file && file.size == 3 && file.mtimeMs != nil && file.entryCount == nil)
            #expect(file.entryNames == nil)
            let folder = try #require(readItemStamp(reader, root.appending("Folder").path))
            #expect(folder.kind == .directory && folder.size == nil && folder.mtimeMs != nil && folder.entryCount == 1)
            #expect(folder.entryNames != nil)
            let link = try #require(readItemStamp(reader, root.appending("link").path))
            #expect(link.kind == .symlink && link.size == nil && link.mtimeMs != nil && link.entryCount == nil)
            #expect(link.entryNames == nil)
        }
    }

    // T-94d98c05 F-520
    @Test func doesntCountTheFilesFinderWritesIntoAFolderOnItsOwn() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            let folder = root.appending("Folder")
            try makeFolder(folder)
            try write(folder.appendingPathComponent(".DS_Store"), "")
            try write(folder.appendingPathComponent("a.txt"), "")
            try write(folder.appendingPathComponent("._a.txt"), "")
            try write(folder.appendingPathComponent(".hidden"), "")
            // An item of its own: there is no "notes" beside it.
            try write(folder.appendingPathComponent("._notes"), "")

            #expect(readItemStamp(reader, folder.path)?.entryCount == 3)
        }
    }

    // A folder whose item was renamed holds as many items, but not the same ones.
    // T-4e34e63a F-520
    @Test func tellsAFolderWhoseItemsWereRenamedFromOneLeftAsItWas() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            let folder = root.appending("Folder")
            try makeFolder(folder)
            try write(folder.appendingPathComponent("a.txt"), "")
            let before = readItemStamp(reader, folder.path)
            try write(folder.appendingPathComponent(".DS_Store"), "")
            #expect(readItemStamp(reader, folder.path)?.entryNames == before?.entryNames)
            try FileManager.default.moveItem(
                at: folder.appendingPathComponent("a.txt"), to: folder.appendingPathComponent("b.txt"))
            #expect(readItemStamp(reader, folder.path)?.entryNames != before?.entryNames)
        }
    }

    // T-15dd73aa F-520
    @Test func isNullForAnItemThatCantBeRead() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            #expect(readItemStamp(reader, root.appending("gone").path) == nil)
        }
    }

    // T-5ee2a302 F-520
    @Test func leavesWhatItCantTellUnknown() {
        let folder = WriteServiceStats(type: .directory)
        #expect(
            readItemStamp(StampReader(lstat: { _ in folder }), "/Folder")
                == ItemStamp(kind: .directory, size: nil, mtimeMs: nil, entryCount: nil))
        let unreadable = StampReader(lstat: { _ in folder }, readdir: { _ in throw OperationError("EACCES") })
        #expect(readItemStamp(unreadable, "/Folder")?.entryCount == nil)
        let device = StampReader(lstat: { _ in WriteServiceStats(type: .other) })
        #expect(readItemStamp(device, "/dev/thing")?.kind == .other)
    }

    // The digest is SHA-1 of the names sorted by UTF-16 code unit and joined by NUL, as the original's.
    @Test func digestsNamesAsTheOriginalDoes() {
        // printf 'a.txt\0b.txt' | shasum
        #expect(digestOfNames(["b.txt", "a.txt"]) == "6ce2420bc45fdd0df9530431b9bd05b5c9a7daf1")
        // An astral character sorts before U+FFFD by UTF-16 code unit (a surrogate), after it by scalar.
        // printf '\xf0\x9f\x98\x80\0\xef\xbf\xbd' | shasum
        #expect(digestOfNames(["\u{FFFD}", "\u{1F600}"]) == "f08f3fdc79086d68de489b447e5022bd0d2417ee")
    }
}

struct StampWithoutIdTests {
    // T-9b741525 F-520
    @Test func keepsHowAnItemLooksOnlyWhenItHasNoIdToGoBy() throws {
        try withTemporaryDirectory(prefix: "filetrail-undo-ids") { root in
            try write(root.appending("a.txt"), "abc")
            let path = root.appending("a.txt").path
            #expect(stampWithoutId(reader, path, ItemId(dev: 1, ino: 2)) == nil)
            let stamp = try #require(stampWithoutId(reader, path, nil))
            #expect(stamp.kind == .file && stamp.size == 3)
            #expect(stampWithoutId(reader, root.appending("gone").path, nil) == nil)
        }
    }
}

struct UndoLogCodingTests {
    // The original's JSON: nulls where it writes null, optional keys only when set.
    @Test func encodesStepsInTheOriginalsShape() throws {
        let stamp = ItemStamp(kind: .file, size: 3, mtimeMs: 1.5, entryCount: nil)
        let log = UndoLog.undoable(units: [
            UndoUnit(steps: [
                .moved(.init(from: "/a", to: "/b", id: ItemId(dev: 1, ino: 2), itemKind: .file, parentId: nil)),
                .moved(
                    .init(
                        from: "/t", to: "/c", id: nil, itemKind: nil, parentId: nil, fromTrash: true, stamp: nil,
                        locked: true)),
                .created(path: "/n", id: nil, stamp: stamp),
                .trashed(from: "/x", trashPath: "/.Trash/x", id: nil, parentId: nil, stamp: stamp),
                .batchRenamed(items: [BatchRenamedItem(from: "/p", to: "/q", id: nil, itemKind: .directory)]),
            ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(log), as: UTF8.self)
        let expected =
            #"{"undoable":true,"units":[{"steps":["#
            + #"{"from":"\/a","id":{"dev":1,"ino":2},"itemKind":"file","kind":"moved","parentId":null,"to":"\/b"},"#
            + #"{"from":"\/t","fromTrash":true,"id":null,"itemKind":null,"kind":"moved","locked":true,"parentId":null,"#
            + #""stamp":null,"to":"\/c"},"#
            + #"{"id":null,"kind":"created","path":"\/n","stamp":{"entryCount":null,"kind":"file","mtimeMs":1.5,"#
            + #""size":3}},"#
            + #"{"from":"\/x","id":null,"kind":"trashed","parentId":null,"stamp":{"entryCount":null,"kind":"file","#
            + #""mtimeMs":1.5,"size":3},"trashPath":"\/.Trash\/x"},"#
            + #"{"items":[{"from":"\/p","id":null,"itemKind":"directory","to":"\/q"}],"kind":"batchRenamed"}]}]}"#
        #expect(text == expected.replacingOccurrences(of: "\\/", with: "/"))
        #expect(try JSONDecoder().decode(UndoLog.self, from: try encoder.encode(log)) == log)
        let refused = String(decoding: try encoder.encode(UndoLog.notUndoable(reason: .deletedForGood)), as: UTF8.self)
        #expect(refused == #"{"reason":"deleted_for_good","undoable":false}"#)
    }
}
