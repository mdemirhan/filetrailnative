// Checks the URL the Trash is given for an item: its name byte for byte as the disk has it, whichever way the path
// spells it, and a path with nothing at it as it was given; and that the path the Trash answers with is kept byte
// for byte
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct TrashURLTests {
    private func representation(_ url: URL) -> [UInt8]? {
        url.withUnsafeFileSystemRepresentation { $0.map { Array(String(cString: $0).utf8) } }
    }

    @Test func theTrashsURLSpellsANameAsTheDiskHasIt() throws {
        try withTemporaryDirectory(prefix: "trash-url") { root in
            let composed = "caf\u{E9}"
            let decomposed = "cafe\u{301}"
            for (index, (stored, asked)) in [(composed, decomposed), (decomposed, composed)].enumerated() {
                let folder = "\(root.path)/\(index)-\(stored)"
                let file = folder + ".txt"
                #expect(mkdir(folder, 0o755) == 0)
                #expect(close(open(file, O_CREAT | O_WRONLY, 0o644)) == 0)
                var info = stat()
                try #require(
                    lstat("\(root.path)/\(index)-\(asked)", &info) == 0, "the disk takes both spellings for one name")

                let folderURL = NativeFS.trashURL("\(root.path)/\(index)-\(asked)")
                #expect(representation(folderURL) == Array(folder.utf8))
                #expect(folderURL.hasDirectoryPath)
                #expect(DiskPath(urlSpelling: folderURL) == DiskPath(folder))

                let fileURL = NativeFS.trashURL("\(root.path)/\(index)-\(asked).txt")
                #expect(representation(fileURL) == Array(file.utf8))
                #expect(!fileURL.hasDirectoryPath)

                // Nothing there: the path as it was given, which Foundation's own initializer would respell.
                let missing = "\(root.path)/missing-\(stored)"
                #expect(representation(NativeFS.trashURL(missing)) == Array(missing.utf8))
            }
        }
    }

    // Undo finds a trashed item by the path the Trash answered with: the answer's own bytes, whichever way it
    // spells an accent.
    @Test func thePathInTheTrashIsTheAnswersOwnBytes() throws {
        for name in ["caf\u{E9}.txt", "cafe\u{301}.txt"] {
            let path = "/Volumes/Card/.Trashes/501/" + name
            let answer = path.withCString {
                URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
            }
            #expect(NativeFS.trashedPath(answer).map { Array($0.utf8) } == Array(path.utf8))
        }
        #expect(NativeFS.trashedPath(try #require(URL(string: "https://example.com/a.txt"))) == nil)
    }

    // The system's calls that take a URL are given the path's own bytes: a disk's id, and whether a folder is a
    // package, under a folder stored with a composed accent.
    @Test func aDisksIdAndAPackageAreToldUnderAComposedFolder() throws {
        try withTemporaryDirectory(prefix: "spelling-ops") { root in
            let folder = "\(root.path)/caf\u{E9}"
            let app = folder + "/T\u{E9}st.app"
            let file = folder + "/na\u{EF}ve.txt"
            #expect(mkdir(folder, 0o755) == 0)
            #expect(mkdir(app, 0o755) == 0)
            #expect(close(open(file, O_CREAT | O_WRONLY, 0o644)) == 0)
            #expect(NativeFS.diskId(of: file) != nil)
            #expect(NativeFS.diskId(of: file) == NativeFS.diskId(of: root.path))
            #expect(NativeFS.diskId(of: folder + "/gone") == nil)
            #expect(try PosixFileSystem().isPackage(app) == true)
            #expect(try PosixFileSystem().isPackage(folder) == false)
            #expect(try PosixFileSystem().isPackage(file) == false)
            #expect(try PosixFileSystem().isPackage(folder + "/gone") == nil)

            // An archive is taken apart in the system's folder for the disk of a folder so named, or in the folder.
            let staging = try Staging(near: folder, NativeWriteFileSystem())
            var info = stat()
            #expect(lstat(staging.work, &info) == 0)
            staging.remove()
            #expect(lstat(staging.root, &info) != 0)
        }
    }
}
