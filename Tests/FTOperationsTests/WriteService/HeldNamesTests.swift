// What the write engine reads from a folder is named as the disk holds it, so what it then renames or removes is found
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// "café.txt" with its "é" one scalar, and "naïve.txt" with its "ï" an "i" and its mark.
private let composed = "caf\u{E9}.txt"
private let decomposed = "nai\u{308}ve.txt"

private func make(_ path: String) {
    // open(2) keeps the name as given; Foundation would decompose it.
    let file = open(path, O_CREAT | O_WRONLY, 0o644)
    #expect(file >= 0, "open \(path)")
    if file >= 0 { close(file) }
}

private func bytes(_ names: [String]) -> [[UInt8]] {
    names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
}

/// The folder's names without the "._name" files FAT and exFAT keep a file's attributes in, which go with their file.
private func names(in folder: String) throws -> [String] {
    try PosixFileSystem().readdir(folder).filter { !$0.utf8.starts(with: "._".utf8) }
}

/// FAT and exFAT list a name with its accents decomposed. Asked about the one item they answer with the spelling it
/// was made or first looked up by since the disk was mounted, and a rename (FAT) or an unlink (exFAT) finds it only
/// by that one. The engine reads a folder's names as the disk holds them on every kind of disk.
@Suite struct HeldNamesTests {
    private static let disks = [DiskImage.Kind.fat32, .exfat, .hfs, .apfs]

    @Test(.tags(.diskImage), .diskImages, arguments: disks)
    func aFoldersNamesAreReadAsTheDiskHoldsThem(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { volume in
            let folder = volume.path + "/names"
            #expect(mkdir(folder, 0o755) == 0)
            make(folder + "/" + composed)
            make(folder + "/" + decomposed)
            make(folder + "/plain.txt")

            let read = try names(in: folder)

            // HFS+ stores every name decomposed; the others hold a name as it was made.
            let held = kind == .hfs ? composed.decomposedStringWithCanonicalMapping : composed
            #expect(bytes(read) == bytes([held, decomposed, "plain.txt"]))
            try NativeWriteFileSystem().rm(folder, recursive: true, force: false)
        }
    }

    @Test(.tags(.diskImage), .diskImages, arguments: disks)
    func eachNameReadIsRenamedAndRemovedByIt(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { volume in
            let folder = volume.path + "/renamed"
            #expect(mkdir(folder, 0o755) == 0)
            make(folder + "/" + composed)
            make(folder + "/" + decomposed)
            let disk = NativeWriteFileSystem()

            for name in try names(in: folder) {
                try disk.renameExclusive(folder + "/" + name, folder + "/x-" + name)
            }
            let renamed = try names(in: folder)
            #expect(renamed.count == 2 && renamed.allSatisfy { $0.utf8.starts(with: "x-".utf8) })
            for name in renamed {
                try disk.rm(folder + "/" + name, recursive: false, force: false)
            }

            #expect(try names(in: folder).isEmpty)
            try disk.rm(folder, recursive: true, force: false)
        }
    }

    @Test(.tags(.diskImage), .diskImages, arguments: disks)
    func aFolderOfAccentedNamesIsRemoved(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { volume in
            let folder = volume.path + "/removed"
            #expect(mkdir(folder, 0o755) == 0)
            for inside in ["dossier\u{E9}", "dossiee\u{301}"] {
                #expect(mkdir(folder + "/" + inside, 0o755) == 0)
                make(folder + "/" + inside + "/" + composed)
                make(folder + "/" + inside + "/" + decomposed)
            }
            make(folder + "/" + composed)

            try NativeWriteFileSystem().rm(folder, recursive: true, force: false)

            var info = stat()
            #expect(lstat(folder, &info) != 0)
        }
    }

    // A disk written elsewhere and plugged in: nothing on it has been looked up yet, and the first to ask about an
    // item decides the spelling the disk holds it by. The folder's own reading asks by the name listed, so every
    // name comes decomposed, a file's "._" companion beside it spelled alike, and what is read is found by it.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func onADiskMountedAgainTheNamesReadAreTheOnesItThenHolds(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind, ownMountPoint: true) { volume in
            let folder = volume.path + "/plugged"
            #expect(mkdir(folder, 0o755) == 0)
            let made = ["caf\u{E9}.txt", "tagg\u{E9}.txt", "\u{E9}t\u{E9}.txt", "gard\u{E9}.txt"]
            for name in made { make(folder + "/" + name) }
            let tag = Array("(\"Red\\n6\")".utf8)
            #expect(
                setxattr(folder + "/tagg\u{E9}.txt", "com.apple.metadata:_kMDItemUserTags", tag, tag.count, 0, 0) == 0)
            // In the mount that made them the disk holds them as made.
            #expect(bytes(try names(in: folder)) == bytes(made))

            try await DiskImage.remount(volume)

            let disk = NativeWriteFileSystem()
            let all = try disk.readdir(folder)
            let read = all.filter { !$0.utf8.starts(with: "._".utf8) }
            #expect(bytes(read) == bytes(made.map(\.decomposedStringWithCanonicalMapping)))
            // Each "._" file is beside a file of its own name, byte for byte.
            let companions = all.filter { $0.utf8.starts(with: "._".utf8) }
            #expect(companions.contains { $0.utf8.elementsEqual(("._" + "tagge\u{301}.txt").utf8) })
            for companion in companions {
                #expect(read.contains { $0.utf8.elementsEqual(companion.utf8.dropFirst(2)) }, "\(companion)")
            }
            // A listing names them the same, and so does the disk asked about the one item.
            let listed = try NativeFileSystem().readDirectory(folder).map(\.name)
            #expect(bytes(listed) == bytes(all))
            for name in read {
                #expect(
                    DiskPath(folder + "/" + name.precomposedStringWithCanonicalMapping).asOnDisk().name.utf8
                        .elementsEqual(name.utf8))
            }
            // And each is renamed and removed by the name read.
            try disk.renameExclusive(folder + "/cafe\u{301}.txt", folder + "/moved.txt")
            try disk.rm(folder + "/e\u{301}te\u{301}.txt", recursive: false, force: false)
            #expect(
                bytes(try names(in: folder))
                    == bytes(
                        ["gard\u{E9}.txt", "tagg\u{E9}.txt"].map(\.decomposedStringWithCanonicalMapping) + ["moved.txt"]
                    ))
        }
    }

    // The same disk, where something asked about an item by the other spelling before its folder was read (a path
    // typed, another app): the disk holds it by that spelling, the folder's reading says so, and it is found by it.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func onADiskMountedAgainANameAskedForFirstIsTheOneRead(kind: DiskImage.Kind) async throws {
        try await DiskImage.withVolume(kind, ownMountPoint: true) { volume in
            let folder = volume.path + "/plugged"
            #expect(mkdir(folder, 0o755) == 0)
            let typed = "nai\u{308}ve.txt".precomposedStringWithCanonicalMapping
            make(folder + "/" + "nai\u{308}ve.txt")
            make(folder + "/" + "re\u{301}sume\u{301}.txt")
            try await DiskImage.remount(volume)

            var info = stat()
            #expect(lstat(folder + "/" + typed, &info) == 0)

            let disk = NativeWriteFileSystem()
            #expect(bytes(try names(in: folder)) == bytes([typed, "re\u{301}sume\u{301}.txt"]))
            try disk.renameExclusive(folder + "/" + typed, folder + "/moved.txt")
            try disk.rm(folder + "/moved.txt", recursive: false, force: false)
            try disk.rm(folder + "/re\u{301}sume\u{301}.txt", recursive: false, force: false)
            #expect(try names(in: folder).isEmpty)
        }
    }
}
