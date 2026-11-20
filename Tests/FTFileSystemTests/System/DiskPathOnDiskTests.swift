// Checks a path respelled as its disk has it: accents and letter case as the folder lists them, links followed, a
// name that isn't there yet kept as given, and the home folder
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

struct DiskPathOnDiskTests {
    private let composed = "caf\u{E9}"
    private let decomposed = "cafe\u{301}"

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The names in a folder, byte for byte as the disk lists them.
    private func listed(_ folder: String) throws -> [[UInt8]] {
        let stream = try #require(opendir(folder))
        defer { closedir(stream) }
        var names: [[UInt8]] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(Array(name.utf8)) }
        }
        return names
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// A fresh folder by its real path, which is what every answer starts with: the system spells its temporary
    /// folder through a link (/var for /private/var).
    private func withRealFolder(_ body: (String) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "disk-path") { try body(FolderIdentity.realPath($0.path)) }
    }

    // The Mac's own disks take both spellings for one name and keep the one the item was made with.
    @Test func aNameAskedForInTheOtherSpellingComesBackAsTheDiskHasIt() throws {
        try withRealFolder { root in
            for (stored, asked) in [(composed, decomposed), (decomposed, composed)] {
                let folder = root + "/" + stored
                #expect(mkdir(folder, 0o755) == 0)
                defer { rmdir(folder) }
                try #require(exists(root + "/" + asked), "the disk takes both spellings for one name")
                #expect(try listed(root) == [bytes(stored)])

                let onDisk = DiskPath(root + "/" + asked).asOnDisk()
                #expect(onDisk == DiskPath(folder))
                #expect(bytes(onDisk.name) == bytes(stored))
                #expect(DiskPath(folder).asOnDisk() == DiskPath(folder))

                // A folder on the way is respelled too.
                #expect(close(open(folder + "/inside.txt", O_CREAT | O_WRONLY, 0o644)) == 0)
                defer { unlink(folder + "/inside.txt") }
                #expect(
                    DiskPath(root + "/" + asked + "/inside.txt").asOnDisk() == DiskPath(folder + "/inside.txt"))
            }
        }
    }

    @Test func aNameAskedForInOtherLetterCaseComesBackAsTheDiskHasIt() throws {
        try withRealFolder { root in
            let folder = root + "/Folder"
            #expect(mkdir(folder, 0o755) == 0)
            try #require(exists(root + "/fOLDER"), "the disk ignores letter case")
            #expect(DiskPath(root + "/fOLDER").asOnDisk() == DiskPath(folder))
        }
    }

    @Test func aNameThatIsNotThereYetIsKeptAsGiven() throws {
        try withRealFolder { root in
            let folder = root + "/" + composed
            #expect(mkdir(folder, 0o755) == 0)
            try #require(exists(root + "/" + decomposed), "the disk takes both spellings for one name")
            for name in ["nai\u{308}ve.txt", "na\u{EF}ve.txt", "New Folder"] {
                // The folder as the disk has it, the name as it was given.
                let onDisk = DiskPath(root + "/" + decomposed + "/" + name).asOnDisk()
                #expect(onDisk == DiskPath(folder + "/" + name))
                #expect(bytes(onDisk.name) == bytes(name))
            }
            // Nothing to go by when the folder isn't there either.
            let missing = DiskPath(root + "/missing/" + decomposed)
            #expect(missing.asOnDisk() == missing)
            #expect(DiskPath("").asOnDisk() == DiskPath(""))
        }
    }

    @Test func linksDotsAndDoubledSlashesAreResolved() throws {
        try withRealFolder { root in
            let folder = root + "/" + composed
            #expect(mkdir(folder, 0o755) == 0)
            #expect(close(open(folder + "/a.txt", O_CREAT | O_WRONLY, 0o644)) == 0)
            #expect(symlink(folder, root + "/link") == 0)
            #expect(symlink(root + "/nowhere", root + "/dangling") == 0)

            #expect(DiskPath(root + "/link").asOnDisk() == DiskPath(folder))
            #expect(DiskPath(root + "/link/a.txt").asOnDisk() == DiskPath(folder + "/a.txt"))
            #expect(DiskPath(root + "/link/new.txt").asOnDisk() == DiskPath(folder + "/new.txt"))
            #expect(
                DiskPath(root + "//" + decomposed + "/../link/./a.txt").asOnDisk() == DiskPath(folder + "/a.txt"))
            // A link that leads nowhere stays the link.
            #expect(DiskPath(root + "/dangling").asOnDisk() == DiskPath(root + "/dangling"))
            // The system's own link.
            #expect(DiskPath("/tmp").asOnDisk() == DiskPath("/private/tmp"))
            #expect(DiskPath("/").asOnDisk() == DiskPath("/"))
        }
    }

    @Test func theHomeFolderIsSpelledAsTheDiskHasIt() {
        let home = DiskPath.home
        #expect(home.string.hasPrefix("/"))
        #expect(home == DiskPath(NSHomeDirectory()).asOnDisk())
        #expect(home.asOnDisk() == home)
        #expect(home == DiskPath(FolderIdentity.realPath(NSHomeDirectory())))
    }
}
