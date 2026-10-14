// Ports the nativeDatesTaken cases of packages/native-fs/src/native-fs.test.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct DatesTakenTests {
    private func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// taken.jpg with its DateTimeOriginal (its only date) replaced by `date`.
    private func photoDated(_ date: String, at url: URL) throws {
        var data = DatesTakenFixtures.taken
        let original = Data("2021:07:04 09:15:30".utf8)
        let range = try #require(data.range(of: original))
        data.replaceSubrange(range, with: Data(date.utf8))
        try write(data, url)
    }

    // T-f2411f69
    @Test func readsTheDateAPhotoWasTakenOnePerPath() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        try write(Data("not a photo".utf8), root.appending("notes.txt"))
        // A photo's extension with something else in it.
        try write(Data("not really a photo".utf8), root.appending("broken.jpg"))
        try write(DatesTakenFixtures.taken, root.appending("taken.jpg"))
        try write(DatesTakenFixtures.digitized, root.appending("digitized.jpg"))
        try write(DatesTakenFixtures.undated, root.appending("undated.jpg"))
        // Only photos: a video has no date taken here, though it has a creation date.
        try write(DatesTakenFixtures.clip, root.appending("clip.mov"))
        let names = [
            "taken.jpg", "digitized.jpg", "undated.jpg", "clip.mov", "notes.txt", "broken.jpg", "missing.jpg",
            "no extension",
        ]
        let answers = await DatesTaken.read(names.map { root.appending($0).path })
        #expect(
            answers == [
                "2021-07-04T09:15:30", "2019-12-31T23:59:58", nil, nil, nil, nil, nil, nil,
            ])
        #expect(await DatesTaken.read([]).isEmpty)
    }

    // N/A T-aa124d90 the argument is typed as a list of paths, so the addon's TypeError has no counterpart
    @Test func exifDatesAreStrictlyDigits() {
        #expect(DatesTaken.localDate(fromExif: "2026:05:14 18:02:11") == "2026-05-14T18:02:11")
        #expect(DatesTaken.localDate(fromExif: "2026:05:14 18:02:1x") == nil)
        #expect(DatesTaken.localDate(fromExif: "2026:05:14 18:02") == nil)
        #expect(DatesTaken.localDate(fromExif: 5) == nil)
        #expect(DatesTaken.localDate(fromExif: nil) == nil)
    }

    // T-eee6f364
    @Test func readsAPhotoWhoseExtensionIsInCapitals() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let path = root.appending("IMG_0001.JPG")
        try write(DatesTakenFixtures.taken, path)
        #expect(await DatesTaken.read([path.path]) == ["2021-07-04T09:15:30"])
    }

    // T-5874efa5
    @Test func readsAPhotoWhoseFolderAndNameHaveAccents() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let path = root.appending("Café").appendingPathComponent("été.jpg")
        try write(DatesTakenFixtures.taken, path)
        #expect(await DatesTaken.read([path.path]) == ["2021-07-04T09:15:30"])
    }

    // T-663d0a15
    @Test func readsTheDateAHeicPhotoWasTaken() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let path = root.appending("taken.heic")
        try write(DatesTakenFixtures.takenHeic, path)
        #expect(await DatesTaken.read([path.path]) == ["2021-07-04T09:15:30"])
    }

    // T-4461d73c
    @Test func findsNoDateInAPhotoWhoseCameraWroteZerosOrSpaces() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let zeros = root.appending("zeros.jpg")
        let spaces = root.appending("spaces.jpg")
        try photoDated("0000:00:00 00:00:00", at: zeros)
        try photoDated("    :  :     :  :  ", at: spaces)
        #expect(await DatesTaken.read([zeros.path, spaces.path]) == [nil, nil])
    }
}
