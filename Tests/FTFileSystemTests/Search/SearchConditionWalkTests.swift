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

    // Only the conditions that need an item's details have the walk read them: its size, the dates modified and
    // created, the flag that locks it, a file's size for "empty".
    @Test func onlyWhatNeedsTheItemsDetailsHasThemRead() {
        let needs: [SearchCondition] = [
            .size(SearchSizeRule(comparison: .larger, value: 1, unit: .megabytes)), .date(.modified, .today),
            .date(.created, .thisWeek), .attribute(.locked, is: true), .attribute(.readOnly, is: false),
            .attribute(.empty, is: true),
        ]
        let needsNot: [SearchCondition] = [
            .tags(["red"], all: false), .date(.added, .today), .date(.lastOpened, .today),
            .attribute(.executable, is: true), .attribute(.alias, is: true), .attribute(.hidden, is: true),
            .kind([.pdf]), .fileExtension(["txt"]),
            .skipFolders(["build"]),
        ]
        for condition in needs { #expect(SearchConditionCheck([condition]).needsStat, "\(condition)") }
        for condition in needsNot { #expect(!SearchConditionCheck([condition]).needsStat, "\(condition)") }
        #expect(SearchConditionCheck([.tags(["red"], all: false), .date(.modified, .today)]).needsStat)
    }

    // The walk's own read of an item, a read of the check's own, and none where no condition needs one: each condition
    // keeps the same items.
    @Test func theWalksReadAndTheChecksOwnAgree() throws {
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeTree(top)
            let conditions: [[SearchCondition]] = [
                [.size(SearchSizeRule(comparison: .larger, value: 1, unit: .megabytes))],
                [.size(SearchSizeRule(comparison: .smaller, value: 10, unit: .bytes))],
                [.date(.modified, .moreThanAgo(1, .years))], [.date(.created, .today)], [.date(.added, .today)],
                [.attribute(.locked, is: true)], [.attribute(.readOnly, is: true)], [.attribute(.empty, is: true)],
                [.attribute(.empty, is: false)], [.attribute(.executable, is: true)], [.tags(["work"], all: false)],
                [.tags(["work", "red"], all: true)], [.tags(["work"], all: false), .attribute(.locked, is: false)],
            ]
            let items = try FileManager.default.subpathsOfDirectory(atPath: top).map { top + "/" + $0 }
            for condition in conditions {
                let check = SearchConditionCheck(condition)
                for path in items {
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    let isFolder = (info.st_mode & S_IFMT) == S_IFDIR
                    let isLink = (info.st_mode & S_IFMT) == S_IFLNK
                    let given = check.keepsByItem(
                        path: path, isFolder: isFolder, isHidden: false, isLink: isLink, info: info)
                    let own = check.keepsByItem(path: path, isFolder: isFolder, isHidden: false, isLink: isLink)
                    #expect(given == own, "\(condition) \(path)")
                }
            }
        }
    }

    // Not a kind leaves out what that kind finds, and only that: a folder named "x.pdf" is no PDF, so not PDF keeps
    // it; a package is its kind, not a folder.
    @Test func notAKindLeavesOutExactlyWhatTheKindFinds() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            try makeTree(top)
            let found = { (conditions: [SearchCondition]) in try names(runtime, top, conditions) }
            let everything = try found([.not(.kind([.audio]))])
            for kinds: Set<SearchKind> in [
                [.pdf], [.folder], [.application], [.presentation], [.picture, .pdf], [.text],
            ] {
                let of = try found([.kind(kinds)])
                let notOf = try found([.not(.kind(kinds))])
                #expect(of.isDisjoint(with: notOf), "\(kinds)")
                #expect(of.union(notOf) == everything, "\(kinds)")
            }
            #expect(try found([.not(.kind([.pdf]))]).contains("x.pdf"))
            #expect(try !found([.not(.kind([.pdf]))]).contains("small.pdf"))
            #expect(try found([.not(.kind([.folder]))]).contains("Deck.key"))
            #expect(try !found([.not(.kind([.presentation]))]).contains("Deck.key"))
            #expect(try !found([.not(.kind([.application]))]).contains("Tool.app"))
            // An extension, likewise: a folder isn't by its extension, a package is.
            for extensions in [["pdf"], ["key"], ["app"], ["txt", "sh"], ["swift"]] {
                let of = try found([.fileExtension(extensions)])
                let notOf = try found([.not(.fileExtension(extensions))])
                #expect(of.isDisjoint(with: notOf), "\(extensions)")
                #expect(of.union(notOf) == everything, "\(extensions)")
            }
            // Not a tag keeps what has none.
            let tagged = try found([.tags(["work"], all: false)])
            let untagged = try found([.not(.tags(["work"], all: false))])
            #expect(tagged.isDisjoint(with: untagged))
            #expect(tagged.union(untagged) == everything)
            #expect(untagged.contains("docs"))
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

    // A folder skipped is named as Plain Text names: whatever its capitals, and with its accents however the disk
    // stores them; a plain letter is the letter with or without one, and a name is taken whole.
    @Test func aFolderSkippedIsNamedAsPlainTextNames() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            let composed = "Caf\u{E9}"
            let decomposed = "Cafe\u{301} Two"
            for name in ["node_modules", composed, decomposed, "My Builds", "node_modules_old"] {
                try makeSearchFolder(top + "/" + name)
                try makeSearchFile(top + "/" + name + "/hit.txt")
            }
            func folders(_ skipped: [String]) throws -> Set<String> {
                let (update, items) = try runWalk(
                    runtime,
                    SearchRequest(
                        rootPath: top, query: "hit", conditions: skipped.isEmpty ? [] : [.skipFolders(skipped)]))
                #expect(update.status == .complete)
                return Set(items.map { NodePath.basename($0.parentPath) })
            }
            let all: Set<String> = ["node_modules", composed, decomposed, "My Builds", "node_modules_old"]
            #expect(try folders([]) == all)
            #expect(try folders(["Node_Modules"]) == all.subtracting(["node_modules"]))
            #expect(try folders(["NODE_MODULES", "my builds"]) == all.subtracting(["node_modules", "My Builds"]))
            // Typed composed or decomposed, the folder that has the accent; typed plain, it too.
            #expect(try folders(["caf\u{E9}"]) == all.subtracting([composed]))
            #expect(try folders(["cafe\u{301}"]) == all.subtracting([composed]))
            #expect(try folders(["cafe"]) == all.subtracting([composed]))
            #expect(try folders(["caf\u{E9} two"]) == all.subtracting([decomposed]))
            // A part of a name skips nothing.
            #expect(try folders(["node", "modules", "Builds"]) == all)
            // The folder itself isn't listed either.
            let (_, items) = try runWalk(
                runtime, SearchRequest(rootPath: top, query: "node", conditions: [.skipFolders(["NODE_modules"])]))
            #expect(items.map(\.name) == ["node_modules_old"])
        }
    }

    // The walk finds items deeper than one call by path reaches, and the conditions read them as they read any
    // other: a writable file there isn't read-only, and its tags are its own.
    @Test func itemsDeeperThanOnePathAreReadAsAnyOther() throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            let top = folder.path
            // Six folders of 250 letters each, made one inside the other from the one before.
            let name = String(repeating: "d", count: 250)
            var opened: [Int32] = [open(top, O_RDONLY | O_DIRECTORY)]
            defer {
                // Taken away from the deepest up: a path this long is no path to remove by.
                for (depth, descriptor) in opened.enumerated().reversed() {
                    if depth == opened.count - 1 {
                        for file in ["needle-plain.txt", "needle-tagged.txt", "needle-readonly.txt"] {
                            unlinkat(descriptor, file, 0)
                        }
                    } else {
                        unlinkat(descriptor, name, AT_REMOVEDIR)
                    }
                    close(descriptor)
                }
            }
            for _ in 0..<6 {
                let parent = try #require(opened.last)
                #expect(mkdirat(parent, name, 0o755) == 0)
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY)
                #expect(child >= 0)
                opened.append(child)
            }
            let deepest = try #require(opened.last)
            for (file, mode) in [
                ("needle-plain.txt", 0o644), ("needle-tagged.txt", 0o644), ("needle-readonly.txt", 0o444),
            ] {
                let made = openat(deepest, file, O_WRONLY | O_CREAT, mode_t(mode))
                #expect(made >= 0)
                if file == "needle-tagged.txt" {
                    let tags = try PropertyListSerialization.data(
                        fromPropertyList: ["Red\n6"], format: .binary, options: 0)
                    let set = tags.withUnsafeBytes {
                        fsetxattr(made, FinderTags.attribute, $0.baseAddress, $0.count, 0, 0)
                    }
                    #expect(set == 0)
                }
                close(made)
            }
            try makeSearchFile(top + "/needle-near.txt")
            func found(_ conditions: [SearchCondition]) throws -> Set<String> {
                let (update, items) = try runWalk(
                    runtime, SearchRequest(rootPath: top, query: "needle", conditions: conditions))
                #expect(update.status == .complete)
                #expect(items.filter { $0.name != "needle-near.txt" }.allSatisfy { $0.path.utf8.count > Int(PATH_MAX) })
                return Set(items.map(\.name))
            }
            #expect(try found([]).count == 4)
            #expect(try found([.attribute(.readOnly, is: true)]) == ["needle-readonly.txt"])
            #expect(
                try found([.attribute(.readOnly, is: false)]) == [
                    "needle-plain.txt", "needle-tagged.txt", "needle-near.txt",
                ])
            #expect(try found([.tags(["red"], all: false)]) == ["needle-tagged.txt"])
            #expect(
                try found([.not(.tags(["red"], all: false))]) == [
                    "needle-plain.txt", "needle-readonly.txt", "needle-near.txt",
                ])
            #expect(try found([.attribute(.empty, is: true)]).count == 4)
            #expect(try found([.date(.added, .today)]).count == 4)
            #expect(try found([.size(SearchSizeRule(comparison: .smaller, value: 1, unit: .kilobytes))]).count == 4)
        }
    }
}
