// Port of packages/core/src/fs/copyPasteReviewEdges.test.ts: what the review finds out before a paste, where the disk
// doesn't answer plainly: whether it tells letter case apart, what a Replace would delete when part of it can't be
// read, and how a very long name gets " copy".
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

private func analyze(_ fileSystem: MockAnalysisFileSystem, _ sourcePaths: [String]) throws -> CopyPasteAnalysisReport {
    try buildCopyPasteAnalysisReport(
        analysisId: "analysis-review",
        request: CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sourcePaths, destinationDirectoryPath: "/target"),
        fileSystem: fileSystem, thresholds: .init(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 100))
}

private func withoutNativeAnswer(_ fileSystem: MockAnalysisFileSystem) -> MockAnalysisFileSystem {
    fileSystem.answersCase = false
    return fileSystem
}

struct CopyPasteReviewEdgesTests {
    // MARK: Telling whether the destination minds letter case

    // T-f233c298 F-430
    @Test func caseLooksForItselfWhenAskingTheVolumeFails() {
        let fileSystem = MockAnalysisFileSystem([("/target/Readme", .file())])
        fileSystem.isCaseSensitiveImpl = { _ in throw OperationError("pathconf failed") }

        #expect(detectCaseSensitivity(fileSystem, in: "/target") == false)
    }

    // T-cea1d1d6 F-430
    @Test func caseUsesTheFoldersOwnNameWhenTheFolderIsEmptyOrCantBeListed() {
        let sensitive = withoutNativeAnswer(MockAnalysisFileSystem([("/Target", .directory())]))
        sensitive.caseSensitive = true
        sensitive.readdirImpl = { _ in throw codedError("EACCES") }
        #expect(detectCaseSensitivity(sensitive, in: "/Target") == true)

        let insensitive = withoutNativeAnswer(MockAnalysisFileSystem([("/Target", .directory())]))
        #expect(detectCaseSensitivity(insensitive, in: "/Target") == false)
    }

    // T-425febe7 F-430
    @Test func caseSkipsNamesWithNoLettersAndAssumesTheMacOSDefaultWhenNothingAnswers() {
        let fileSystem = withoutNativeAnswer(MockAnalysisFileSystem([("/2024/123.456", .file())]))

        #expect(detectCaseSensitivity(fileSystem, in: "/2024") == false)
    }

    // T-c8c360e6 F-430
    @Test func caseCantTellFromALookupThatGivesNoFileIdsNorFromOneThatFails() {
        let noIds = withoutNativeAnswer(MockAnalysisFileSystem([("/target/Readme", .file())]))
        let noIdsBase = noIds.base
        noIds.lstatImpl = { path in
            var stats = try noIdsBase.lstat(path)
            stats.ino = nil
            return stats
        }
        #expect(detectCaseSensitivity(noIds, in: "/target") == false)

        let failing = withoutNativeAnswer(MockAnalysisFileSystem([("/target/Readme", .file())]))
        let failingBase = failing.base
        failing.lstatImpl = { path in
            if path.hasSuffix("rEADME") {
                throw codedError("EIO")
            }
            return try failingBase.lstat(path)
        }
        #expect(detectCaseSensitivity(failing, in: "/target") == false)
    }

    // MARK: What the review says a Replace would delete

    // T-ef9f2f23 F-431 F-317
    @Test func replaceCantSayWhenAFolderInsideTheExistingOneCantBeRead() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target/Docs/a.txt", .file(size: 1)),
            ("/target/Docs/Private/secret.txt", .file(size: 1)),
        ])
        let base = fileSystem.base
        fileSystem.readdirImpl = { path in
            if path == "/target/Docs/Private" {
                throw codedError("EACCES")
            }
            return try base.readdir(path)
        }

        let report = try analyze(fileSystem, ["/source/Docs"])

        #expect(report.nodes.first?.destinationOnly == nil)
        #expect(report.nodes.first?.destinationTotalNodeCount == nil)
    }

    // Finder writes .DS_Store into a folder just by showing it; it isn't anyone's item.
    // T-4004f3be F-431 F-926
    @Test func replaceDoesntCountFindersDSStoreAsAnItemItWouldDelete() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target/Docs/.DS_Store", .file(size: 1)),
            ("/target/Docs/a.txt", .file(size: 1)), ("/target/Docs/Old/.DS_Store", .file(size: 1)),
        ])

        let report = try analyze(fileSystem, ["/source/Docs"])

        #expect(report.nodes.first?.destinationTotalNodeCount == 2)
        #expect(report.nodes.first?.destinationOnly == CopyPasteDestinationOnlySummary(count: 1, samplePaths: ["Old"]))
    }

    // T-2cf74644 F-426 F-320
    @Test func warnsAboutAPasteThatIsLargeBySizeNotOnlyByCount() throws {
        let fileSystem = MockAnalysisFileSystem([("/source/big.bin", .file(size: 500)), ("/target", .directory())])

        let report = try analyze(fileSystem, ["/source/big.bin"])

        #expect(report.warnings.map(\.code).contains(.largeBatch))
    }

    // MARK: Fitting a name

    // T-e63c16b4 F-432
    @Test func keepsAnAbsurdlyLongExtensionAsPartOfTheName() {
        let ext = "." + String(repeating: "x", count: 260)
        let name = CopyPasteNames.fitName("report", suffix: " copy", extension: ext)

        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" copy"))
    }
}
