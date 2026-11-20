// Checks which path the home folder is known by
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct HomeFolderTests {
    // Under `CFFIXED_USER_HOME` (the automation and screenshot scripts set it) the home folder is the one it names,
    // by its real path: the system answers with "/tmp/…" for a home in "/private/tmp/…", and a listing with the
    // latter.
    @Test func theHomeFolderIsTheSystemsByItsRealPath() throws {
        let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
        let spelled = fixed ?? NSHomeDirectory()
        let real = try #require(realpath(spelled, nil))
        defer { free(real) }
        #expect(utf8Bytes(DiskPath.home.string) == utf8Bytes(String(cString: real)))
        #expect(DiskPath.home == DiskPath(NSHomeDirectory()).asOnDisk())
        // What reads the home folder for itself reads this one.
        #expect(FinderTags.asksPermission(DiskPath.home.string + "/Documents"))
        #expect(!FinderTags.asksPermission(DiskPath.home.string + "/Other"))
    }

    // The Trash is the system's, which is told the home folder as the system spells it; the one Trash is known by
    // its real path all the same.
    @Test func theTrashKeepsTheHomeFolderAsTheSystemSpellsIt() {
        let trash = TrashFolders(listMounts: { [] })
        let real = (try? MountTable.realPath(NSHomeDirectory() + "/.Trash")) ?? NSHomeDirectory() + "/.Trash"
        #expect(trash.home == real)
    }
}
