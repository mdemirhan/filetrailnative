// Port of packages/core/src/fs/copyPasteAnalysis.realfs.test.ts, copyPasteReviewData.realfs.test.ts and the review
// cases of copyPastePackages.realfs.test.ts: what the review finds on the real disk.
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private func write(_ path: String, _ content: String) throws {
    try Data(content.utf8).write(to: URL(fileURLWithPath: path))
}

private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func analyze(_ sourcePaths: [String], into destination: String) throws -> CopyPasteAnalysisReport {
    try buildCopyPasteAnalysisReport(
        analysisId: "analysis-review",
        request: CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sourcePaths, destinationDirectoryPath: destination),
        fileSystem: PosixFileSystem(),
        thresholds: .init(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
}

private func findNode(_ nodes: [CopyPasteAnalysisNode], _ name: String) -> CopyPasteAnalysisNode? {
    for node in nodes {
        if node.sourcePath.hasSuffix("/\(name)") {
            return node
        }
        if let nested = findNode(node.children, name) {
            return nested
        }
    }
    return nil
}

struct CopyPasteAnalysisRealFSTests {
    /// The data volume, where the firmlinked folders (/Users, /private) really are.
    private static let dataVolume = "/System/Volumes/Data"

    // The temporary folder is under /private (or /Users), a firmlink: its real path keeps whichever spelling it is
    // given.
    // T-a58143a5 F-421 F-310
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data")))
    func refusesToPasteAFolderIntoItsOwnInsideSpelledThroughTheDataVolume() throws {
        try withTemporaryDirectory(prefix: "filetrail-analysis") { directory in
            guard FileManager.default.fileExists(atPath: Self.dataVolume + directory.path) else { return }
            try makeFolder(directory.path + "/A/sub")
            let destination = Self.dataVolume + directory.path + "/A/sub"
            // The case this is about: the two real paths don't show one holds the other.
            #expect(try PosixFileSystem().realpath(destination) == destination)

            let report = try buildCopyPasteAnalysisReport(
                analysisId: "analysis-1",
                request: CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: [directory.path + "/A"], destinationDirectoryPath: destination),
                fileSystem: PosixFileSystem(),
                thresholds: .init(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))

            #expect(report.issues.map(\.code) == [.parentIntoChild])
            #expect(report.nodes.isEmpty)
        }
    }
}

struct CopyPasteReviewDataTests {
    private struct Places {
        let source: String
        let target: String
    }

    private func withPlaces(_ body: (Places) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "filetrail-review-data") { directory in
            let places = Places(source: directory.path + "/source", target: directory.path + "/target")
            try makeFolder(places.source)
            try makeFolder(places.target)
            try body(places)
        }
    }

    // T-e7e10177 F-433 F-319
    @Test func namesTheKeepBothCopyOfEveryConflictReservingNamesAcrossThePaste() throws {
        try withPlaces { places in
            try write(places.source + "/a.txt", "a")
            try write(places.source + "/a copy.txt", "a copy")
            try write(places.target + "/a.txt", "existing")
            try makeFolder(places.source + "/photos")
            try makeFolder(places.target + "/photos")
            try write(places.source + "/photos/x.jpg", "x")
            try write(places.target + "/photos/x.jpg", "old x")

            let report = try analyze(
                ["a.txt", "a copy.txt", "photos"].map { places.source + "/" + $0 }, into: places.target)

            #expect(findNode(report.nodes, "a.txt")?.keepBothDestinationPath == places.target + "/a copy 2.txt")
            #expect(findNode(report.nodes, "a copy.txt")?.keepBothDestinationPath == nil)
            #expect(findNode(report.nodes, "photos")?.keepBothDestinationPath == places.target + "/photos copy")
            // Inside a folder that will be merged, nested conflicts get their names too.
            #expect(findNode(report.nodes, "x.jpg")?.keepBothDestinationPath == places.target + "/photos/x copy.jpg")
        }
    }

    // T-19fe0166 F-433 F-317
    @Test func listsWhatExistsOnlyInTheExistingFolderNestedItemsIncluded() throws {
        try withPlaces { places in
            try makeFolder(places.source + "/photos/2025")
            try write(places.source + "/photos/a.jpg", "a")
            try write(places.source + "/photos/2025/b.jpg", "b")
            try makeFolder(places.target + "/photos/2025")
            try makeFolder(places.target + "/photos/raw")
            try write(places.target + "/photos/a.jpg", "old a")
            try write(places.target + "/photos/d.jpg", "d")
            try write(places.target + "/photos/2025/old.jpg", "old")
            try write(places.target + "/photos/raw/1.dng", "1")
            try write(places.target + "/photos/raw/2.dng", "2")

            let report = try analyze([places.source + "/photos"], into: places.target)

            // d.jpg, 2025/old.jpg, raw, raw/1.dng, raw/2.dng
            #expect(
                findNode(report.nodes, "photos")?.destinationOnly
                    == CopyPasteDestinationOnlySummary(count: 5, samplePaths: ["2025/old.jpg", "d.jpg", "raw"]))
        }
    }

    // T-fa481367 F-433 F-317
    @Test func countsAFolderThatAPastedFileWouldReplaceAsLostEntirely() throws {
        try withPlaces { places in
            try write(places.source + "/config", "file")
            try makeFolder(places.target + "/config")
            try write(places.target + "/config/settings.ini", "x")

            let report = try analyze([places.source + "/config"], into: places.target)

            let node = findNode(report.nodes, "config")
            #expect(node?.conflictClass == .typeMismatch)
            #expect(node?.destinationOnly == CopyPasteDestinationOnlySummary(count: 1, samplePaths: ["settings.ini"]))
            #expect(node?.replaceBlockedReason == nil)
        }
    }

    // T-0c5958cd F-433 F-318
    @Test func marksAnItemThatCantBeReplacedBecauseItContainsThePastedItem() throws {
        try withPlaces { places in
            try makeFolder(places.target + "/foo/foo")

            let report = try analyze([places.target + "/foo/foo"], into: places.target)

            #expect(report.nodes.first?.replaceBlockedReason == "It contains the item being pasted.")
        }
    }

    // The paste that follows (a.txt replaced, b.txt kept, "c copy.txt" made) is checked with the engine (P3-03).
    // T-394e8556 F-433 F-323
    @Test func appliesPerItemChoicesOverThePolicyForTheirKind() throws {
        try withPlaces { places in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try write(places.source + "/" + name, "new \(name)")
                try write(places.target + "/" + name, "old \(name)")
            }
            let report = try analyze(
                ["a.txt", "b.txt", "c.txt"].map { places.source + "/" + $0 }, into: places.target)
            let id = { (name: String) in findNode(report.nodes, name)?.id ?? "" }

            let resolved = try resolveAnalysisWithPolicy(
                report: report, policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip),
                overrides: [
                    CopyPasteNodeOverride(nodeId: id("a.txt"), action: .overwrite),
                    CopyPasteNodeOverride(nodeId: id("b.txt"), action: .skip),
                    // "merge" makes no sense for a file and is ignored.
                    CopyPasteNodeOverride(nodeId: id("c.txt"), action: .merge),
                ], fileSystem: PosixFileSystem())

            #expect(resolved.map(\.action) == [.overwrite, .skip, .keepBoth])
            #expect(resolved.last?.destinationPath == places.target + "/c copy.txt")
        }
    }
}

struct CopyPastePackageReviewTests {
    private func makeApp(_ folder: String, _ version: String, _ extraFile: String) throws {
        try makeFolder(folder + "/Foo.app/Contents")
        try write(folder + "/Foo.app/Contents/Info.plist", version)
        try write(folder + "/Foo.app/Contents/" + extraFile, extraFile)
    }

    // T-8cb73442 F-314 F-315
    @Test func aPackageThatClashesWithOneAlreadyThereIsReviewedAsOneItem() throws {
        try withTemporaryDirectory(prefix: "filetrail-packages") { directory in
            let source = directory.path + "/src"
            let destination = directory.path + "/dst"
            try makeApp(source, "v2", "new.png")
            try makeApp(destination, "v1", "old.png")

            let report = try analyze([source + "/Foo.app"], into: destination)

            #expect(report.nodes.first?.conflictClass == .fileConflict)
            #expect(report.nodes.first?.destinationOnly == nil)
            #expect(report.summary.fileConflictCount == 1)
            #expect(report.summary.directoryConflictCount == 0)
        }
    }

    // T-fa3c5111 F-314
    @Test func isPackageFolderAsksMacOSAndKnowsAFolderWithoutAPackageExtensionIsntOne() throws {
        try withTemporaryDirectory(prefix: "filetrail-packages") { directory in
            try makeFolder(directory.path + "/Foo.app")
            try makeFolder(directory.path + "/plain.d")

            #expect(isPackageFolder(PosixFileSystem(), directory.path + "/Foo.app"))
            #expect(!isPackageFolder(PosixFileSystem(), directory.path + "/plain.d"))
        }
    }

    /// The disk without macOS's package answer, with one that doesn't know, or with one that fails.
    private struct PackageAnswer: AnalysisFileSystem {
        enum Answer { case none, unknown, failing }

        let answer: Answer
        private let disk = PosixFileSystem()

        init(_ answer: Answer) {
            self.answer = answer
        }

        func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
        func stat(_ path: String) throws -> WriteServiceStats { try disk.stat(path) }
        func realpath(_ path: String) throws -> String { try disk.realpath(path) }
        func readdir(_ path: String) throws -> [String] { try disk.readdir(path) }
        func readlink(_ path: String) throws -> String { try disk.readlink(path) }

        func isPackage(_ path: String) throws -> Bool? {
            switch answer {
            case .none, .unknown: return nil
            case .failing: throw OperationError("Launch Services didn't answer")
            }
        }
    }

    // T-ec63ba2e F-314
    @Test func isPackageFolderGoesByTheExtensionWhenMacOSCantBeAskedOrDoesntKnow() throws {
        try withTemporaryDirectory(prefix: "filetrail-packages") { directory in
            for fileSystem in [PackageAnswer(.none), PackageAnswer(.unknown), PackageAnswer(.failing)] {
                #expect(isPackageFolder(fileSystem, directory.path + "/Talk.key"))
                #expect(!isPackageFolder(fileSystem, directory.path + "/Notes"))
            }
        }
    }
}
