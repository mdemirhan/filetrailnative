// A search's conditions on real files: each condition alone and with others, with no text and with some, what it reads
// of each item only once its name and entry kept it.
import CoreGraphics
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTFileSystem

@Suite struct SearchConditionWalkTests {
    /// A tree of items each condition tells apart.
    private func makeTree(_ top: String) throws {
        for folder in ["docs", "x.pdf", "Deck.key", "Tool.app", "empty", "node_modules", "node_modules/pkg", "src"] {
            try makeSearchFolder(top + "/" + folder)
        }
        try makeSearchFile(top + "/docs/small.pdf", String(repeating: "x", count: 100))
        try makeSearchFile(top + "/docs/notes.txt", "notes")
        try makeSearchFile(top + "/empty.txt")
        try makeSearchFile(top + "/node_modules/pkg/index.js", "x")
        try makeSearchFile(top + "/src/main.swift", "x")
        try makeSearchFile(top + "/Deck.key/Index.zip", "x")
        try makeSearchFile(top + "/run.sh", "#!/bin/sh\n")
        #expect(chmod(top + "/run.sh", 0o755) == 0)
        try makeSearchFile(top + "/readonly.txt", "x")
        #expect(chmod(top + "/readonly.txt", 0o444) == 0)
        try makeSearchFile(top + "/locked.txt", "x")
        #expect(chflags(top + "/locked.txt", UInt32(UF_IMMUTABLE)) == 0)
        // 2.5 MB of nothing.
        let big = open(top + "/docs/big.pdf", O_WRONLY | O_CREAT, 0o644)
        #expect(ftruncate(big, 2_500_000) == 0)
        close(big)
        #expect(symlink(top + "/docs", top + "/link-to-docs") == 0)
        try makePicture(top + "/wide.png", width: 300, height: 20)
        try makePicture(top + "/tiny.png", width: 10, height: 10)
        try FinderTags.write([FinderTag(name: "Work", color: nil)], to: top + "/docs/notes.txt")
        try FinderTags.write(
            [FinderTag(name: "Work", color: nil), FinderTag(name: "Red", color: .red)], to: top + "/src/main.swift")
        // Modified two years ago.
        var times = [timeval(tv_sec: time(nil) - 2 * 366 * 86_400, tv_usec: 0)]
        times.append(times[0])
        #expect(utimes(top + "/docs/notes.txt", &times) == 0)
    }

    private func makePicture(_ path: String, width: Int, height: Int) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let url = URL(fileURLWithPath: path)
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func names(
        _ runtime: WalkSearchRuntime, _ top: String, _ conditions: [SearchCondition], query: String = "",
        hidden: Bool = false
    ) throws -> Set<String> {
        let (update, items) = try runWalk(
            runtime, SearchRequest(rootPath: top, query: query, includeHidden: hidden, conditions: conditions))
        #expect(update.status == .complete, "\(conditions): \(update.error ?? "")")
        return Set(items.map(\.name))
    }

    @Test func eachConditionKeepsWhatItAsksFor() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeTree(top)
            let found = { (conditions: [SearchCondition]) in try names(runtime, top, conditions) }
            // A folder counts by its extension only as a package: x.pdf is a folder, Deck.key a presentation.
            #expect(try found([.kind([.pdf])]) == ["small.pdf", "big.pdf"])
            #expect(try found([.kind([.presentation])]) == ["Deck.key"])
            #expect(try found([.kind([.application])]) == ["Tool.app"])
            #expect(try found([.kind([.folder])]) == ["docs", "x.pdf", "empty", "node_modules", "pkg", "src"])
            #expect(try found([.kind([.picture, .pdf])]) == ["small.pdf", "big.pdf", "wide.png", "tiny.png"])
            #expect(try found([.fileExtension(["SH", "swift"])]) == ["run.sh", "main.swift"])
            // A size leaves out folders.
            #expect(
                try found([.size(SearchSizeRule(comparison: .larger, value: 1, unit: .megabytes))]) == ["big.pdf"])
            #expect(
                try found([.size(SearchSizeRule(comparison: .between, value: 50, upper: 200, unit: .kilobytes))])
                    .isEmpty)
            #expect(try found([.pictureSize(SearchPixelRule(larger: true, pixels: 100))]) == ["wide.png"])
            #expect(try found([.pictureSize(SearchPixelRule(larger: false, pixels: 100))]) == ["tiny.png"])
            #expect(try found([.date(.modified, .moreThanAgo(1, .years))]) == ["notes.txt"])
            #expect(
                try found([.date(.modified, .withinLast(1, .years)), .kind([.text])]) == [
                    "empty.txt", "readonly.txt", "locked.txt",
                ])
            #expect(try found([.tags(["work"], all: false)]) == ["notes.txt", "main.swift"])
            #expect(try found([.tags(["Work", "Red"], all: true)]) == ["main.swift"])
            #expect(try found([.attribute(.executable, is: true)]) == ["run.sh"])
            #expect(try found([.attribute(.locked, is: true)]) == ["locked.txt"])
            #expect(try found([.attribute(.readOnly, is: true)]) == ["readonly.txt", "locked.txt"])
            #expect(try found([.attribute(.empty, is: true)]) == ["empty", "empty.txt", "x.pdf", "Tool.app"])
            #expect(try found([.attribute(.symbolicLink, is: true)]) == ["link-to-docs"])
            #expect(try !found([.attribute(.symbolicLink, is: false)]).contains("link-to-docs"))
            // A folder skipped isn't gone into.
            #expect(try found([.skipFolders(["node_modules"]), .fileExtension(["js"])]).isEmpty)
            #expect(try found([.fileExtension(["js"])]) == ["index.js"])
        }
    }

    @Test func conditionsGoWithTheTextAndWithEachOther() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeTree(top)
            #expect(try names(runtime, top, [.kind([.pdf])], query: "big") == ["big.pdf"])
            #expect(
                try names(
                    runtime, top,
                    [.kind([.pdf]), .size(SearchSizeRule.init(comparison: .smaller, value: 1, unit: .kilobytes))]) == [
                        "small.pdf"
                    ])
            // Two Kind chips: what is of both.
            #expect(
                try names(runtime, top, [.kind([.pdf, .text]), .kind([.text])]) == [
                    "notes.txt", "empty.txt", "readonly.txt", "locked.txt",
                ])
            // A chip with an empty list asks for nothing.
            #expect(try names(runtime, top, [.fileExtension([]), .kind([.application])]) == ["Tool.app"])
        }
    }

    // Hidden asks for hidden items, whether or not the folder shows them; Not hidden leaves them out when it does.
    @Test func theHiddenConditionListsHiddenItems() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeSearchFile(top + "/.env", "A=1")
            try makeSearchFile(top + "/flagged.txt")
            try makeSearchFile(top + "/plain.txt")
            #expect(chflags(top + "/flagged.txt", UInt32(UF_HIDDEN)) == 0)
            #expect(try names(runtime, top, [.attribute(.hidden, is: true)]) == [".env", "flagged.txt"])
            #expect(try names(runtime, top, [.attribute(.hidden, is: false)], hidden: true) == ["plain.txt"])
            #expect(try names(runtime, top, []) == ["plain.txt"])
        }
    }

    // A picture's date taken is read from it; a file with none meets only a rule of long ago.
    @Test func theDateTakenIsReadFromThePicture() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try DatesTakenFixtures.taken.write(to: URL(fileURLWithPath: top + "/taken.jpg"))
            try DatesTakenFixtures.undated.write(to: URL(fileURLWithPath: top + "/undated.jpg"))
            var calendar = Calendar.current
            calendar.timeZone = .current
            let day = calendar.date(from: DateComponents(year: 2021, month: 7, day: 4))!
            #expect(try names(runtime, top, [.date(.taken, .between(day, day))]) == ["taken.jpg"])
            #expect(try names(runtime, top, [.date(.taken, .before(day))]) == ["undated.jpg"])
            #expect(try names(runtime, top, [.date(.taken, .after(day))]).isEmpty)
        }
    }

    // What the conditions read is counted, and only what the name and the entry kept is read.
    @Test func onlyWhatTheNameAndEntryKeptIsRead() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeTree(top)
            let (sized, _) = try runWalk(
                runtime,
                SearchRequest(rootPath: top, query: "", conditions: [.kind([.pdf]), SearchCondition.sizeDefault]))
            #expect(sized.itemsRead == 2)
            let (byName, _) = try runWalk(runtime, SearchRequest(rootPath: top, query: "", conditions: [.kind([.pdf])]))
            #expect(byName.itemsRead == 0)
        }
    }
}
