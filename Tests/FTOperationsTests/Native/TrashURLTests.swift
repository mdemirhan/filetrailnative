// Checks the URL the Trash is given for an item: its name byte for byte as the disk has it, whichever way the path
// spells it, and a path with nothing at it as it was given
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
}
