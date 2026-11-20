// The Rename sheet on items whose paths differ only in how an accent is stored
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// "café.txt" with its "é" as one scalar, and as an "e" with the accent after it: two files on a disk that keeps
    /// both. They are listed by hand: a Mac's own disk holds only one.
    @MainActor
    @Suite struct BatchRenameAccentTwinsTests {
        private let composed = "caf\u{E9}.txt"
        private let decomposed = "cafe\u{301}.txt"

        private func bytes(_ paths: [String]) -> [[UInt8]] { paths.map { Array($0.utf8) } }

        private func target(_ name: String) -> BatchRenameTarget {
            BatchRenameTarget(path: "/f/" + name, name: name, isFolder: false)
        }

        private func model(_ box: BatchRenameInspectBox) -> BatchRenameSheetModel {
            let saved = BatchRenameSavedRecord()
            saved.settings = BatchRenameSettings(mode: .format, customName: "x")
            return makeBatchRenameModel(box, saved)
        }

        // Rename on one of the two and another item: the sheet has those two, and they are what is renamed.
        @Test func theSheetOpenedOnOneOfTheTwoLeavesTheOtherOut() async throws {
            let listed = [composed, decomposed, "plain.txt"].map { ContentModelTests.entry($0) }
            #expect(bytes(listed.map(\.path)) == bytes(["/f/" + composed, "/f/" + decomposed, "/f/plain.txt"]))

            let targets = MainWindowController.batchRenameTargets(for: [listed[2], listed[0]], listed: listed)

            #expect(bytes(targets.map(\.path)) == bytes(["/f/" + composed, "/f/plain.txt"]))
            let box = BatchRenameInspectBox()
            let model = model(box)
            model.open(targets)
            #expect(await waitUntil { model.sheet?.inspect != nil })
            #expect(bytes(box.requests.flatMap(\.paths)) == bytes(targets.map(\.path)))
            let request = try #require(model.request)
            #expect(bytes(request.items.map(\.sourcePath)) == bytes(targets.map(\.path)))
            #expect(request.items.count == targets.count)
        }

        // Both in the sheet: what the checks found of each is its own.
        @Test func eachOfTheTwoHasItsOwnChecks() async throws {
            let box = BatchRenameInspectBox(mode: .hold)
            let model = model(box)
            model.open([target(composed), target(decomposed)])
            await box.resolve(
                0,
                BatchRenameInspection(
                    items: [
                        .init(
                            path: "/f/" + composed, createdAt: nil, modifiedAt: nil, takenAt: nil,
                            cannotRename: "The first is locked."),
                        .init(
                            path: "/f/" + decomposed, createdAt: nil, modifiedAt: nil, takenAt: nil,
                            cannotRename: "The second is locked."),
                    ],
                    folders: [.init(path: "/f", names: [composed, decomposed], caseSensitive: true)]))
            #expect(await waitUntil { model.sheet?.inspect != nil })
            let problems = (model.plan?.items ?? []).map { item -> String in
                if case .problem(_, _, .cannotRename(let message)) = item { return message }
                return "renamed"
            }
            #expect(problems == ["The first is locked.", "The second is locked."])
        }

        // Try Again knows which of the two was a folder.
        @Test func tryAgainKnowsWhichOfTheTwoWasAFolder() {
            let folders = [DiskPath("/f/" + composed): true, DiskPath("/f/" + decomposed): false]
            let items = [
                WriteOperationItem(sourcePath: "/f/" + composed, destinationPath: nil, status: .failed),
                WriteOperationItem(sourcePath: "/f/" + decomposed, destinationPath: nil, status: .failed),
            ]
            let result = WriteOperationResult(
                operationId: "rename-1", action: .batchRename, status: .partial, targetPath: nil, startedAt: Date(),
                finishedAt: Date(),
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 2, totalItemCount: 2, completedItemCount: 0, failedItemCount: 2,
                    skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
                items: items, error: nil)
            let targets = MainWindowController.retryTargets(result, folders: folders)
            #expect(targets.map(\.isFolder) == [true, false])
        }
    }
}
