// What the review finds out before a paste, where the disk doesn't answer plainly: whether it tells letter case apart,
// what a Replace would delete when part of it can't be read, and how a very long name gets " copy".
import FTFoundation
import Foundation
import Testing

@testable import FTOperations

private func analyze(_ fileSystem: MockAnalysisFileSystem, _ sourcePaths: [String]) throws -> CopyPasteAnalysisReport {
    try buildCopyPasteAnalysisReport(
        analysisId: "analysis-review",
        request: CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sourcePaths, destinationDirectoryPath: "/target"),
        fileSystem: fileSystem)
}

private func withoutNativeAnswer(_ fileSystem: MockAnalysisFileSystem) -> MockAnalysisFileSystem {
    fileSystem.answersCase = false
    return fileSystem
}

struct CopyPasteReviewEdgesTests {
    // MARK: Telling whether the destination minds letter case

    @Test func caseLooksForItselfWhenAskingTheVolumeFails() {
        let fileSystem = MockAnalysisFileSystem([("/target/Readme", .file())])
        fileSystem.isCaseSensitiveImpl = { _ in throw OperationError("pathconf failed") }

        #expect(detectCaseSensitivity(fileSystem, in: "/target") == false)
    }

    @Test func caseUsesTheFoldersOwnNameWhenTheFolderIsEmptyOrCantBeListed() {
        let sensitive = withoutNativeAnswer(MockAnalysisFileSystem([("/Target", .directory())]))
        sensitive.caseSensitive = true
        sensitive.readdirImpl = { _ in throw codedError(.errno(EACCES)) }
        #expect(detectCaseSensitivity(sensitive, in: "/Target") == true)

        let insensitive = withoutNativeAnswer(MockAnalysisFileSystem([("/Target", .directory())]))
        #expect(detectCaseSensitivity(insensitive, in: "/Target") == false)
    }

    @Test func caseSkipsNamesWithNoLettersAndAssumesTheMacOSDefaultWhenNothingAnswers() {
        let fileSystem = withoutNativeAnswer(MockAnalysisFileSystem([("/2024/123.456", .file())]))

        #expect(detectCaseSensitivity(fileSystem, in: "/2024") == false)
    }

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
                throw codedError(.errno(EIO))
            }
            return try failingBase.lstat(path)
        }
        #expect(detectCaseSensitivity(failing, in: "/target") == false)
    }

    // MARK: What the review says a Replace would delete

    @Test func replaceCantSayWhenAFolderInsideTheExistingOneCantBeRead() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target/Docs/a.txt", .file(size: 1)),
            ("/target/Docs/Private/secret.txt", .file(size: 1)),
        ])
        let base = fileSystem.base
        fileSystem.readdirImpl = { path in
            if path == "/target/Docs/Private" {
                throw codedError(.errno(EACCES))
            }
            return try base.readdir(path)
        }

        let report = try analyze(fileSystem, ["/source/Docs"])

        #expect(report.nodes.first?.destinationOnly == nil)
        #expect(report.nodes.first?.destinationTotalNodeCount == nil)
    }

    // Finder writes .DS_Store into a folder just by showing it; it isn't anyone's item.
    @Test func replaceDoesntCountFindersDSStoreAsAnItemItWouldDelete() throws {
        let fileSystem = MockAnalysisFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target/Docs/.DS_Store", .file(size: 1)),
            ("/target/Docs/a.txt", .file(size: 1)), ("/target/Docs/Old/.DS_Store", .file(size: 1)),
        ])

        let report = try analyze(fileSystem, ["/source/Docs"])

        #expect(report.nodes.first?.destinationTotalNodeCount == 2)
        #expect(report.nodes.first?.destinationOnly == CopyPasteDestinationOnlySummary(count: 1, samplePaths: ["Old"]))
    }

    // MARK: Fitting a name

    @Test func keepsAnAbsurdlyLongExtensionAsPartOfTheName() {
        let ext = "." + String(repeating: "x", count: 260)
        let name = CopyPasteNames.fitName("report", suffix: " copy", extension: ext)

        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" copy"))
    }
}
