// Port of the nativeRenameExclusive and nativeIsCaseSensitive cases of packages/native-fs/src/native-fs.test.ts,
// with the fallback, AppleDouble volumes and case-sensitive disks on disk images
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private typealias Files = NativeTestFiles

struct NativeRenameExclusiveTests {
    // T-6de0bf0d F-348 F-406
    @Test func movesAnItemWithoutReplacingAnything() throws {
        try withTemporaryDirectory(prefix: "native-fs-rename") { root in
            try Files.write(root.appending("a.txt").path, "moved")
            try Files.write(root.appending("b.txt").path, "existing")

            let error = #expect(throws: NativeError.self) {
                try NativeFS.renameExclusive(root.appending("a.txt").path, root.appending("b.txt").path)
            }
            #expect(error?.code == "EEXIST" && error?.syscall == "rename")
            #expect(error?.path == root.appending("a.txt").path && error?.dest == root.appending("b.txt").path)
            #expect(Files.read(root.appending("b.txt").path) == Array("existing".utf8))

            try NativeFS.renameExclusive(root.appending("a.txt").path, root.appending("c.txt").path)
            #expect(Files.read(root.appending("c.txt").path) == Array("moved".utf8))
            #expect(!Files.exists(root.appending("a.txt").path))
        }
    }

    // A volume without RENAME_EXCL: looked for first, then rename(2).
    // F-348
    @Test func checksFirstThenRenamesOnAVolumeThatCantRenameExclusively() throws {
        var renamed: [String] = []
        let present: Set<String> = ["/v/b.txt"]
        var calls = RenameCalls()
        calls.renamex = { _, _ in ENOTSUP }
        calls.lstat = { present.contains($0) ? 0 : ENOENT }
        calls.rename = { from, to in
            renamed.append("\(from) -> \(to)")
            return 0
        }

        let taken = #expect(throws: NativeError.self) {
            try NativeFS.renameExclusive("/v/a.txt", "/v/b.txt", calls: calls)
        }
        #expect(taken?.code == "EEXIST" && taken?.syscall == "rename")
        #expect(renamed.isEmpty)

        try NativeFS.renameExclusive("/v/a.txt", "/v/c.txt", calls: calls)
        #expect(renamed == ["/v/a.txt -> /v/c.txt"])

        calls.lstat = { _ in EACCES }
        let unreadable = #expect(throws: NativeError.self) {
            try NativeFS.renameExclusive("/v/a.txt", "/v/d.txt", calls: calls)
        }
        #expect(unreadable?.code == "EACCES")
    }

    // FAT and exFAT: a move that never replaces, whichever way the volume allows it.
    // F-348 F-337
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func movesWithoutReplacingOnFATDisks(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { volume in
            try Files.write(volume.path + "/a.txt", "moved")
            try Files.write(volume.path + "/b.txt", "existing")
            let error = #expect(throws: NativeError.self) {
                try NativeFS.renameExclusive(volume.path + "/a.txt", volume.path + "/b.txt")
            }
            #expect(error?.code == "EEXIST")
            #expect(Files.read(volume.path + "/b.txt") == Array("existing".utf8))
            try NativeFS.renameExclusive(volume.path + "/a.txt", volume.path + "/c.txt")
            #expect(Files.read(volume.path + "/c.txt") == Array("moved".utf8))
        }
    }
}

struct NativeCaseSensitivityTests {
    // T-13d0fdf4 F-333 F-406
    @Test func answersForTheVolumeHoldingAPath() throws {
        try withTemporaryDirectory(prefix: "native-fs-case") { root in
            try Files.write(root.appending("Probe").path, "")
            let answer = try NativeFS.isCaseSensitive(root.path)
            // The answer must agree with what the volume does with a case-swapped name.
            #expect(answer == !Files.exists(root.appending("pROBE").path))
        }
    }

    // T-2fbea9df F-333
    @Test func rejectsAPathThatDoesntExist() {
        let error = #expect(throws: NativeError.self) { try NativeFS.isCaseSensitive("/nonexistent/path/xyz") }
        #expect(error?.code == "ENOENT" && error?.syscall == "pathconf")
    }

    // F-333
    @Test(.tags(.diskImage), .diskImages)
    func answersTrueOnACaseSensitiveDisk() async throws {
        try await DiskImage.withVolume(.apfsCaseSensitive) { volume in
            let answer = try NativeFS.isCaseSensitive(volume.path)
            #expect(answer == true)
        }
    }
}

struct NativeAppleDoubleTests {
    private static let magic: [UInt8] = [0x00, 0x05, 0x16, 0x07, 0, 2, 0, 0]

    // F-414 F-406
    @Test func readsTheMagicNumber() throws {
        try withTemporaryDirectory(prefix: "native-fs-appledouble") { root in
            try Files.write(root.appending("._a").path, Self.magic)
            try Files.write(root.appending("._b").path, [0x00, 0x05, 0x16])
            try Files.write(root.appending("._c").path, [0x00, 0x05, 0x16, 0x08])
            #expect(NativeFS.startsWithAppleDoubleMagic(root.appending("._a").path))
            #expect(!NativeFS.startsWithAppleDoubleMagic(root.appending("._b").path))
            #expect(!NativeFS.startsWithAppleDoubleMagic(root.appending("._c").path))
            #expect(!NativeFS.startsWithAppleDoubleMagic(root.appending("._gone").path))
            // APFS keeps attributes natively: a "._name" file there is an ordinary item, whatever it holds.
            #expect(try NativeFS.usesAppleDouble(root.path) == false)
            #expect(!NativeFS.isAppleDoubleOnItsVolume(root.appending("._a").path))
            #expect(NativeFS.isAppleDoubleOnItsVolume(root.appending("._a").path, usesAppleDouble: { _ in true }))
            #expect(!NativeFS.isAppleDoubleOnItsVolume(root.appending("._a").path, usesAppleDouble: { _ in nil }))
            #expect(
                !NativeFS.isAppleDoubleOnItsVolume(
                    root.appending("._a").path, usesAppleDouble: { _ in throw OperationError("EIO") }))
        }
    }

    @Test func namesTheErrnoForAMissingPath() {
        let error = #expect(throws: NativeError.self) { try NativeFS.usesAppleDouble("/nonexistent/path/xyz") }
        #expect(error?.code == "ENOENT" && error?.syscall == "getattrlist")
    }

    // F-414
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func tellsADiskThatKeepsAttributesInAppleDoubleFiles(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind) { volume in
            #expect(try NativeFS.usesAppleDouble(volume.path) == true)
            try Files.write(volume.path + "/a.txt", "a")
            #expect(Files.setXattr(volume.path + "/a.txt", "com.example.test", "value") == 0)
            // macOS wrote the attribute into "._a.txt", with the magic number.
            #expect(NativeFS.isAppleDoubleOnItsVolume(volume.path + "/._a.txt"))
            try Files.write(volume.path + "/._plain", "not AppleDouble")
            #expect(!NativeFS.isAppleDoubleOnItsVolume(volume.path + "/._plain"))
        }
    }
}
