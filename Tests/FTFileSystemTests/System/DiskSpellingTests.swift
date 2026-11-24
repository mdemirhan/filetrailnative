// Checks that a path with an accent the disk stores composed reaches the system spelled as the disk has it: the URLs
// made for the system's calls hold the path's own bytes
import AppKit
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import ImageIO
import Testing

@testable import FTFileSystem

/// A folder and files whose names the disk stores with a composed accent, made by `mkdir` and `open` so that
/// nothing respells them on the way.
struct ComposedPlace {
    static let folderName = "caf\u{E9}"
    static let otherSpelling = "cafe\u{301}"
    let root: String
    var folder: String { root + "/" + Self.folderName }
    /// The same folder as an app that decomposes accents would spell its path.
    var folderSpelledOtherwise: String { root + "/" + Self.otherSpelling }

    /// In the test's folder by its real path (/private/var/…), which is how a listing spells it.
    init(_ root: TemporaryDirectory) throws {
        let real = try #require(realpath(root.path, nil))
        defer { free(real) }
        self.root = String(cString: real)
        try #require(mkdir(folder, 0o755) == 0)
    }

    @discardableResult
    func file(_ name: String, _ contents: Data = Data("x".utf8)) throws -> String {
        let path = folder + "/" + name
        let descriptor = open(path, O_CREAT | O_WRONLY, 0o644)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try contents.withUnsafeBytes { bytes in
            try #require(write(descriptor, bytes.baseAddress, bytes.count) == bytes.count)
        }
        return path
    }

    static func png() throws -> Data {
        let image = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(image.representation(using: .png, properties: [:]))
    }
}

func utf8Bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// How many times the disk was asked.
final class DiskCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// The bytes a URL hands a system call.
func systemBytes(of url: URL) -> [UInt8]? {
    url.withUnsafeFileSystemRepresentation { $0.map { Array(String(cString: $0).utf8) } }
}

@Suite struct DiskSpellingTests {
    @Test func theItemsHandedToOpenAndShowAreSpelledAsTheirPathsAre() throws {
        try withTemporaryDirectory(prefix: "spelling-open") { root in
            let place = try ComposedPlace(root)
            let file = try place.file("na\u{EF}ve.txt")
            let link = place.folder + "/link"
            try #require(symlink(place.folder, link) == 0)
            let urls = SystemOpener.itemURLs([place.folder, file, link, place.folder + "/gone"])
            #expect(urls.map(systemBytes) == [place.folder, file, link, place.folder + "/gone"].map(utf8Bytes))
            // A folder is said to be one; a link to a folder is the link, so Finder shows the link itself.
            #expect(urls.map(\.hasDirectoryPath) == [true, false, false, false])
        }
    }

    @Test func aLinkToAFolderIsNotAFolderToItsURL() throws {
        try withTemporaryDirectory(prefix: "spelling-link") { root in
            let folder = root.path + "/Folder"
            try #require(mkdir(folder, 0o755) == 0)
            try #require(symlink(folder, root.path + "/link") == 0)
            // As `URL(fileURLWithPath:)` tells them apart.
            #expect(DiskPath(folder).fileURL().hasDirectoryPath)
            #expect(!DiskPath(root.path + "/link").fileURL().hasDirectoryPath)
            #expect(!URL(fileURLWithPath: root.path + "/link").hasDirectoryPath)
        }
    }

    @Test func tagsWrittenUnderAComposedFolderAreReadBack() throws {
        try withTemporaryDirectory(prefix: "spelling-tags") { root in
            let place = try ComposedPlace(root)
            let file = try place.file("na\u{EF}ve.txt")
            let tags = [FinderTag(name: "Red", color: .red), FinderTag(name: "Project", color: nil)]
            try FinderTags.write(tags, to: file)
            #expect(try FinderTags.read(file) == tags)
            #expect(FinderTags.colors(file) == [.red])
            // The label went on the same file: the system reads it by the path's own bytes.
            let label = try DiskPath(file).url(isDirectory: false).resourceValues(forKeys: [.labelNumberKey])
            #expect(label.labelNumber == FinderTagColor.red.rawValue)
            try FinderTags.write([], to: file)
            #expect(try FinderTags.read(file).isEmpty)
        }
    }

    @Test func aFilesKindAndPictureAreReadUnderAComposedFolder() async throws {
        try await withTemporaryDirectory(prefix: "spelling-reads") { root in
            let place = try ComposedPlace(root)
            let text = try place.file("na\u{EF}ve.txt")
            let picture = try place.file("im\u{E5}ge.png", try ComposedPlace.png())
            #expect(FileKind.kind(forPath: text)?.isEmpty == false)
            #expect(FileKind.ByContentType().kind(forPath: text)?.isEmpty == false)
            let url = DiskPath(picture).url(isDirectory: false)
            #expect(systemBytes(of: url) == utf8Bytes(picture))
            #expect(QuickLookThumbnailRenderer.imagePixels(url, side: 64) == 32)
            #expect(QuickLookThumbnailRenderer.decodedImage(url, side: 64)?.width == 8)
            // The app's own files are read and written by the same URLs.
            let state = place.folder + "/st\u{E5}te.json"
            try DiskFileSystem().write(state, "{}")
            #expect(try DiskFileSystem().read(state) == Data("{}".utf8))
            #expect(DiskPath.nameOnDisk(state).map(utf8Bytes) == utf8Bytes("st\u{E5}te.json"))
            // A photo's date is looked for in a file with an image's extension, whatever its folder is called.
            #expect(await DatesTaken.read([picture, text]) == [nil, nil])
        }
    }

    @Test func aPictureBehindALinkIsReadWhereTheLinkLeadsAsTheDiskSpellsIt() throws {
        try withTemporaryDirectory(prefix: "spelling-thumb") { root in
            let place = try ComposedPlace(root)
            let picture = try place.file("im\u{E5}ge.png", try ComposedPlace.png())
            let link = place.root + "/link.png"
            try #require(symlink(place.folderSpelledOtherwise + "/ima\u{30A}ge.png", link) == 0)
            let target = QuickLookThumbnailRenderer.linkTarget(of: DiskPath(link).url(isDirectory: false))
            #expect(systemBytes(of: target) == utf8Bytes(picture))
            #expect(QuickLookThumbnailRenderer.imagePixels(DiskPath(link).url(isDirectory: false), side: 64) == 32)
        }
    }

    @Test func aDragOutCarriesEachItemByItsPathsOwnBytes() throws {
        try withTemporaryDirectory(prefix: "spelling-drag") { root in
            let place = try ComposedPlace(root)
            let file = try place.file("na\u{EF}ve.txt")
            // The first two have rows that say what they are; the last has none, and the disk is asked.
            let urls = FileDrag.itemURLs([place.folder, file, place.folder], directories: [true, false])
            #expect(urls.map(systemBytes) == [place.folder, file, place.folder].map(utf8Bytes))
            #expect(urls.map(\.hasDirectoryPath) == [true, false, true])
        }
    }

    @Test func theAppsOwnFilesKeepTheirNamesAndPlaces() throws {
        #expect(LogRotation.rotatedPath("/logs/app.log", 1) == "/logs/app.1.log")
        #expect(LogRotation.rotatedPath("/logs/app", 2) == "/logs/app.2")
        #expect(LogRotation.rotatedPath("/l\u{F6}gs/app.old.log", 3) == "/l\u{F6}gs/app.old.3.log")
        #expect(utf8Bytes(LogRotation.rotatedPath("/l\u{F6}gs/app.log", 1)) == utf8Bytes("/l\u{F6}gs/app.1.log"))
        try withTemporaryDirectory(prefix: "spelling-own") { root in
            let place = try ComposedPlace(root)
            let samples = IconSamples(root: DiskPath(place.folder + "/samples").url(isDirectory: true))
            let folder = try samples.path(for: .folder)
            #expect(utf8Bytes(folder) == utf8Bytes(place.folder + "/samples/folder"))
            #expect(FileManager.default.fileExists(atPath: folder + "/item"))
            #expect(utf8Bytes(try samples.path(forTint: .red)) == utf8Bytes(place.folder + "/samples/tag-6"))
        }
    }

    // FAT and exFAT keep a name as it was written. Whichever way a path spells it, the disk finds it, and so do the
    // system's calls that take a URL: tags, reads and resource values work on a file stored composed.
    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func tagsAndReadsReachAFileStoredComposedOnADiskThatKeepsNamesAsWritten(kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { folder in
            let composed = folder.path + "/caf\u{E9}"
            try #require(mkdir(composed, 0o755) == 0)
            let file = composed + "/na\u{EF}ve.txt"
            let descriptor = open(file, O_CREAT | O_WRONLY, 0o644)
            try #require(descriptor >= 0)
            close(descriptor)
            try FinderTags.write([FinderTag(name: "Red", color: .red)], to: file)
            #expect(try FinderTags.read(file) == [FinderTag(name: "Red", color: .red)])
            let url = DiskPath(file).fileURL()
            #expect(systemBytes(of: url) == utf8Bytes(file))
            #expect(try url.resourceValues(forKeys: [.labelNumberKey]).labelNumber == FinderTagColor.red.rawValue)
            #expect(try Data(contentsOf: DiskPath(file).url(isDirectory: false)).isEmpty)
            #expect(FileKind.kind(forPath: file)?.isEmpty == false)
            // The same calls by a URL that spells the accents decomposed, as `URL(fileURLWithPath:)` makes it: on
            // this macOS they find the file too. Only the Trash is known to refuse such a URL on FAT.
            let respelled = URL(fileURLWithPath: file)
            #expect(systemBytes(of: respelled) != utf8Bytes(file))
            #expect(
                (try? respelled.resourceValues(forKeys: [.labelNumberKey]).labelNumber) == FinderTagColor.red.rawValue)
            #expect((try? Data(contentsOf: respelled)) != nil)
        }
    }
}
