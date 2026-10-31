// Port of apps/desktop/src/main/bootstrap/batchRenameInspect.test.ts
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

private let home = "/Users/demo"

/// Milliseconds since 1970 of a time on this Mac's clock (`new Date(2026, 8, 30, 10, 12, 40)`).
private func localMs(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Double {
    let date = Calendar.current.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    return (date?.timeIntervalSince1970 ?? 0) * 1000
}

private func stats(
    birthtimeMs: Double? = localMs(2026, 9, 30, 10, 12, 40), mtimeMs: Double? = localMs(2026, 10, 1, 8, 30, 15)
)
    -> WriteServiceStats
{
    WriteServiceStats(type: .file, mtimeMs: mtimeMs, birthtimeMs: birthtimeMs)
}

/// Counts the calls made to it, from any thread.
private final class Calls: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: [String]())
    func record(_ call: String) { made.withLock { $0.append(call) } }
    var all: [String] { made.withLock { $0 } }
}

private func deps(
    lstat: @escaping @Sendable (String) throws -> WriteServiceStats = { _ in stats() },
    readdir: @escaping @Sendable (String) throws -> [String] = { _ in ["a.jpg", "b.jpg", ".hidden"] },
    isCaseSensitive: @escaping @Sendable (String) throws -> Bool? = { _ in false },
    getFlags: @escaping @Sendable (String) throws -> UInt32 = { _ in 0 },
    canWriteFolder: @escaping @Sendable (String) throws -> Bool = { _ in true },
    readDatesTaken: @escaping @Sendable ([String]) async throws -> [String?] = {
        $0.map { _ in "2026-05-14T18:02:11" }
    },
    assertRenamable: @escaping @Sendable (String) throws -> Void = { _ in }
) -> BatchRenameInspectDeps {
    BatchRenameInspectDeps(
        lstat: lstat, readdir: readdir, isCaseSensitive: isCaseSensitive, getFlags: getFlags,
        canWriteFolder: canWriteFolder, readDatesTaken: readDatesTaken, assertRenamable: assertRenamable,
        homePath: home)
}

private func inspect(_ paths: [String], dateTaken: Bool = false, _ deps: BatchRenameInspectDeps) async
    -> BatchRenameInspection
{
    await BatchRenameInspect.inspect(BatchRenameInspectRequest(paths: paths, includeDateTaken: dateTaken), deps)
}

@Suite struct BatchRenameInspectTests {
    // T-1b10005b F-245 F-569
    // B-DLG-150
    @Test func givesEachItemsDatesAndEveryNameInItsFolderHiddenOnesToo() async {
        let answer = await inspect(["/trip/a.jpg", "/trip/b.jpg"], deps())
        let dated = { (path: String) in
            BatchRenameInspection.Item(
                path: path, createdAt: "2026-09-30T10:12:40", modifiedAt: "2026-10-01T08:30:15", takenAt: nil,
                cannotRename: nil)
        }
        #expect(
            answer
                == BatchRenameInspection(
                    items: [dated("/trip/a.jpg"), dated("/trip/b.jpg")],
                    folders: [.init(path: "/trip", names: ["a.jpg", "b.jpg", ".hidden"], caseSensitive: false)]))
    }

    // T-73191f3a F-245 F-569
    @Test func readsTheDatesTakenOnlyWhenAskedAndKeepsOnlyWellFormedOnes() async {
        let calls = Calls()
        let without = deps(readDatesTaken: { paths in
            calls.record("read \(paths.count)")
            return ["2026-05-14T18:02:11", "yesterday"]
        })
        _ = await inspect(["/trip/a.jpg"], without)
        #expect(calls.all.isEmpty)
        let answer = await inspect(["/trip/a.jpg", "/trip/b.jpg"], dateTaken: true, without)
        #expect(answer.items.map(\.takenAt) == ["2026-05-14T18:02:11", nil])
        let failing = deps(readDatesTaken: { _ in throw OperationError("no") })
        let none = await inspect(["/trip/a.jpg"], dateTaken: true, failing)
        #expect(none.items.first?.takenAt == nil)
    }

    // T-0c6885bc F-245 F-569
    @Test func groupsItemsByFolderAndReportsEachFolderOnce() async {
        let calls = Calls()
        let answer = await inspect(
            ["/a/1.txt", "/b/2.txt", "/a/3.txt"],
            deps(isCaseSensitive: { path in
                calls.record(path)
                return path == "/b" ? true : nil
            }))
        #expect(answer.folders.map(\.path) == ["/a", "/b"])
        #expect(answer.folders.map(\.caseSensitive) == [false, true])
        #expect(calls.all.count == 2)
    }

    // T-761e9009 F-245 F-569
    // B-DLG-151
    @Test func saysWhyAnItemCantBeRenamed() async {
        let missing = await inspect(["/trip/gone.txt"], deps(lstat: { _ in throw errno("ENOENT") }))
        #expect(missing.items.first?.cannotRename == "“gone.txt” no longer exists.")
        #expect(missing.items.first?.createdAt == nil)
        #expect(missing.items.first?.modifiedAt == nil)

        let trash = await inspect(["\(home)/.Trash"], deps())
        #expect(trash.items.first?.cannotRename == "The Trash can’t be renamed.")

        let lockedFolder = await inspect(["/trip/a.jpg"], deps(getFlags: { $0 == "/trip" ? 0x2 : 0 }))
        #expect(
            lockedFolder.items.first?.cannotRename == "“trip” is locked. Unlock it in Finder's Get Info and try again.")

        let readOnly = await inspect(["/trip/a.jpg"], deps(canWriteFolder: { _ in false }))
        #expect(readOnly.items.first?.cannotRename == "You don’t have permission to rename items in “trip”.")

        let lockedItem = await inspect(["/trip/a.jpg"], deps(getFlags: { $0 == "/trip/a.jpg" ? 0x2 : 0 }))
        #expect(
            lockedItem.items.first?.cannotRename == "“a.jpg” is locked. Unlock it in Finder's Get Info and try again.")

        let protectedFolder = await inspect(
            ["\(home)/Documents"],
            deps(assertRenamable: { _ in throw WriteCoordinatorError("“Documents” can't be renamed.") }))
        #expect(protectedFolder.items.first?.cannotRename == "“Documents” can't be renamed.")
    }

    // T-64776c2c F-245 F-569
    // B-DLG-152
    @Test func leavesOutDatesTheDiskDoesntReallyHaveAndNamesItCantRead() async {
        let answer = await inspect(
            ["/trip/a.jpg"],
            deps(
                lstat: { _ in stats(birthtimeMs: 0, mtimeMs: .nan) },
                readdir: { _ in throw OperationError("unreadable") },
                isCaseSensitive: { _ in throw OperationError("unknown") }))
        #expect(answer.items.first?.createdAt == nil)
        #expect(answer.items.first?.modifiedAt == nil)
        #expect(answer.folders.first == .init(path: "/trip", names: [], caseSensitive: false))
    }
}

@Suite struct BatchRenameInspectRealDiskTests {
    private func realDeps() -> BatchRenameInspectDeps {
        BatchRenameInspectDeps.native(homePath: home) { _ in }
    }

    // T-da7f5d79 F-163 F-245 F-569
    @Test func readsNamesDatesAndTheDateAPhotoWasTaken() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-inspect") { root in
            try takenJpeg.write(to: root.appending("photo.jpg"))
            try "n".write(to: root.appending("notes.txt"), atomically: false, encoding: .utf8)
            try "h".write(to: root.appending(".hidden"), atomically: false, encoding: .utf8)
            let notesPath = root.appending("notes.txt").path
            let answer = await BatchRenameInspect.inspect(
                BatchRenameInspectRequest(
                    paths: [root.appending("photo.jpg").path, notesPath], includeDateTaken: true), realDeps())
            #expect(answer.items.first?.takenAt == "2021-07-04T09:15:30")
            #expect(answer.items.first?.cannotRename == nil)
            var info = Darwin.stat()
            #expect(Darwin.lstat(notesPath, &info) == 0)
            let local = { (time: timespec) in
                BatchRename.toLocalDateTime(Date(timeIntervalSince1970: TimeInterval(time.tv_sec)))
            }
            #expect(
                answer.items.last
                    == .init(
                        path: notesPath, createdAt: local(info.st_birthtimespec), modifiedAt: local(info.st_mtimespec),
                        takenAt: nil, cannotRename: nil))
            #expect(answer.folders.first?.names.sorted() == [".hidden", "notes.txt", "photo.jpg"])
        }
    }

    // T-807fc7d3 F-245 F-569
    @Test func findsLockedItemsAndFoldersThatCantBeWrittenTo() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-inspect") { root in
            let locked = root.appending("locked.txt").path
            let readOnly = root.appending("read-only").path
            try "l".write(toFile: locked, atomically: false, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: readOnly, withIntermediateDirectories: false)
            try "a".write(toFile: readOnly + "/a.txt", atomically: false, encoding: .utf8)
            #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
            #expect(chmod(readOnly, 0o555) == 0)
            defer {
                chflags(locked, 0)
                chmod(readOnly, 0o755)
            }
            let answer = await BatchRenameInspect.inspect(
                BatchRenameInspectRequest(paths: [locked, readOnly + "/a.txt"], includeDateTaken: false), realDeps())
            #expect(
                answer.items.map(\.cannotRename) == [
                    "“locked.txt” is locked. Unlock it in Finder's Get Info and try again.",
                    "You don’t have permission to rename items in “read-only”.",
                ])
        }
    }
}

/// packages/native-fs/test-fixtures/taken.jpg: taken on 2021-07-04 at 09:15:30.
private let takenJpeg =
    Data(
        base64Encoded:
            "/9j/4AAQSkZJRgABAQAASABIAAD/4QBgRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA5ADAAIAAAAUAAAARKACAAQAAAABAAAACKADAAQAAAABAAAACAAAAAAyMDIxOjA3OjA0IDA5OjE1OjMwAP/tADhQaG90b3Nob3AgMy4wADhCSU0EBAAAAAAAADhCSU0EJQAAAAAAENQdjNmPALIE6YAJmOz4Qn7/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwDk6KKK/tw/ms//2Q=="
    ) ?? Data()
