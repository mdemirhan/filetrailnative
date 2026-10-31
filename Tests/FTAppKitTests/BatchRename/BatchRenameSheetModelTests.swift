// Port of apps/desktop/src/renderer/hooks/useBatchRename.test.tsx: the sheet's state over a stand-in for the items'
// checks and a record of the saved preferences
import AppKit
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

private let targets = [
    BatchRenameTarget(path: "/trip/IMG_1.jpg", name: "IMG_1.jpg", isFolder: false),
    BatchRenameTarget(path: "/trip/IMG_2.jpg", name: "IMG_2.jpg", isFolder: false),
]

private let takenSettings = BatchRenameSettings(
    mode: .format, nameFormat: .date, separator: .underscore, dateSource: .taken)

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct BatchRenameSheetModelTests {
        /// A model whose checks answer as `setup` of the original does: the dates, the dates taken when asked, and
        /// the folder holding the two items.
        private func setup(
            settings: BatchRenameSettings? = nil, presets: [BatchRenamePreset]? = nil,
            inspect: BatchRenameInspectBox.Mode = .answer
        ) -> (BatchRenameSheetModel, BatchRenameInspectBox, BatchRenameSavedRecord) {
            let box = BatchRenameInspectBox(mode: inspect)
            box.folderNames = ["IMG_1.jpg", "IMG_2.jpg"]
            box.takenAt = "2026-05-14T18:02:11"
            let saved = BatchRenameSavedRecord()
            saved.settings = settings.map(BatchRenamePresetList.node(of:))
            saved.presets = presets.map(BatchRenamePresetList.node(of:))
            return (makeBatchRenameModel(box, saved), box, saved)
        }

        private func answered(_ model: BatchRenameSheetModel) async -> Bool {
            await waitUntil { model.sheet?.inspect != nil }
        }

        // B-DLG-077 B-DLG-085 B-DLG-086
        // T-7517206e
        @Test func opensWithTheSettingsLastUsedAndThePresetsSavedAndChecksTheItems() async throws {
            let (model, box, _) = setup(
                settings: BatchRenameSettings(find: "IMG_", replaceWith: "x"),
                presets: [BatchRenamePreset(name: "Saved", settings: .defaults)])
            model.open(targets)
            #expect(model.settings.find == "IMG_")
            #expect(model.presets.map(\.name) == ["Saved"])
            #expect(await answered(model))
            #expect(box.requests == [.init(paths: ["/trip/IMG_1.jpg", "/trip/IMG_2.jpg"], includeDateTaken: false)])
            #expect(model.plan?.renameCount == 2)
            #expect(
                model.request
                    == BatchRenameRequest(
                        items: [
                            .init(sourcePath: "/trip/IMG_1.jpg", destinationName: "x1.jpg", isFolder: false),
                            .init(sourcePath: "/trip/IMG_2.jpg", destinationName: "x2.jpg", isFolder: false),
                        ], onConflict: .number, numberSeparator: " "))
        }

        // B-DLG-082 B-DLG-086
        // T-dd4acfd2
        @Test func asksForTheDatesTakenOnceTheyAreUsedAndOnlyThen() async throws {
            let (model, box, _) = setup()
            model.open(targets)
            #expect(await answered(model))
            model.setSettings(takenSettings)
            #expect(await waitUntil { model.sheet?.inspectHasDatesTaken == true })
            #expect(box.requests.map(\.includeDateTaken) == [false, true])
            #expect(model.request?.items.first?.destinationName == "File_2026-05-14.jpg")
            // A clash would be numbered with Format's separator.
            #expect(model.request?.numberSeparator == "_")
        }

        // B-DLG-082 B-DLG-086
        // T-759edbf6
        @Test func asksForTheDatesTakenAtOnceWhenTheSettingsOpenedWithAlreadyUseThem() async throws {
            var settings = takenSettings
            settings.separator = .none
            let (model, box, _) = setup(settings: settings)
            model.open(targets)
            #expect(await answered(model))
            #expect(box.requests.map(\.includeDateTaken) == [true])
            // No separator in Format: a number added to a taken name gets a space.
            #expect(model.request?.numberSeparator == " ")
        }

        // B-DLG-081 B-DLG-085
        // T-40de0695
        @Test func sendsNothingWhileCheckingWithANameToFixOrWithNothingToRename() async throws {
            let (model, box, _) = setup(
                settings: BatchRenameSettings(find: "IMG_1", onConflict: .block), inspect: .hold)
            model.open(targets)
            #expect(model.request == nil)
            await box.resolve(
                0,
                BatchRenameInspectBox.answer(
                    paths: targets.map(\.path), folderNames: ["IMG_1.jpg", "IMG_2.jpg", ".jpg"], created: nil,
                    modified: nil))
            #expect(await answered(model))
            // "IMG_1.jpg" without "IMG_1" is only an extension: that must be fixed first.
            #expect(model.plan?.blockingCount == 1)
            #expect(model.request == nil)
            model.setSettings(BatchRenameSettings(find: "nothing"))
            #expect(model.request == nil)
        }

        // B-DLG-089 B-DLG-121
        // T-a477a68b
        @Test func keepsTheSettingsForNextTimeWhenItCloses() async throws {
            let (model, _, saved) = setup()
            model.open(targets)
            model.setSettings(BatchRenameSettings(mode: .changeCase))
            model.close()
            #expect(model.sheet == nil)
            #expect(saved.savedSettings == BatchRenameSettings(mode: .changeCase))
        }

        // B-DLG-119 B-DLG-121
        // T-acbedec1
        @Test func savesPresetsByNameReplacingOneOfTheSameNameAndDeletesThem() async throws {
            let (model, _, saved) = setup(presets: [BatchRenamePreset(name: "Photos", settings: .defaults)])
            model.open(targets)
            model.setSettings(BatchRenameSettings(mode: .add))
            model.savePreset("  photos ")
            #expect(model.presets == [BatchRenamePreset(name: "photos", settings: BatchRenameSettings(mode: .add))])
            model.savePreset("   ")
            #expect(model.presets.count == 1)
            model.deletePreset("photos")
            #expect(model.presets.isEmpty)
            #expect(saved.patches.last == ["batchRenamePresets": .array([])])
        }

        // B-DLG-084
        // T-eae80eb6
        @Test func saysWhenTheItemsCouldntBeCheckedAndRenamesNothing() async throws {
            let (model, _, _) = setup(settings: BatchRenameSettings(find: "IMG"), inspect: .fail)
            model.open(targets)
            #expect(
                await waitUntil {
                    model.sheet?.inspectError == "File Trail couldn\u{2019}t read the items to check their new names."
                })
            #expect(model.request == nil)
        }

        // B-DLG-076 B-DLG-077
        // T-8abbca64
        @Test func opensWithTheDefaultsWhenThePreferencesCantBeReadAndNotAtAllForNothing() async throws {
            let (model, _, saved) = setup()
            saved.fails = true
            model.open([])
            #expect(model.sheet == nil)
            model.open(targets)
            #expect(model.sheet != nil)
            #expect(model.settings == .defaults)
        }

        // B-DLG-083
        // T-1e58856e
        @Test func forgetsAnAnswerThatComesAfterTheSheetClosed() async throws {
            let (model, box, _) = setup(inspect: .hold)
            model.open(targets)
            model.close()
            await box.resolve(0, BatchRenameInspection(items: [], folders: []))
            for _ in 0..<5 { await Task.yield() }
            #expect(model.sheet == nil)
        }

        // B-DLG-085 B-DLG-086
        // T-d4ab4379
        @Test func sendsOnlyTheItemsToRenameWithTheNumberedNamesAndLeavesOutWhatCantBeRenamed() async throws {
            let mixed = [
                BatchRenameTarget(path: "/trip/x locked.jpg", name: "x locked.jpg", isFolder: false),
                BatchRenameTarget(path: "/trip/same.jpg", name: "same.jpg", isFolder: false),
                BatchRenameTarget(path: "/trip/x.jpg", name: "x.jpg", isFolder: false),
                BatchRenameTarget(path: "/trip/x2", name: "x2", isFolder: true),
            ]
            let (model, box, _) = setup(settings: BatchRenameSettings(find: "x", replaceWith: "Lisbon"))
            box.folderNames = mixed.map(\.name) + ["Lisbon.jpg"]
            box.cannotRename = ["/trip/x locked.jpg": "\u{201C}x locked.jpg\u{201D} is locked."]
            model.open(mixed)
            #expect(await answered(model))
            let plan = try #require(model.plan)
            #expect(
                plan.items.map {
                    switch $0 {
                    case .unchanged: "unchanged"
                    case .rename: "rename"
                    case .problem: "problem"
                    }
                } == ["problem", "unchanged", "rename", "rename"])
            if case .problem(_, _, let problem) = plan.items[0] {
                #expect(problem == .cannotRename(message: "\u{201C}x locked.jpg\u{201D} is locked."))
            }
            // A locked item is left as it is: it doesn't stop the others.
            #expect(plan.renameCount == 2 && plan.unchangedCount == 1 && plan.skippedCount == 1)
            #expect(plan.blockingCount == 0)
            #expect(
                model.request
                    == BatchRenameRequest(
                        items: [
                            .init(sourcePath: "/trip/x.jpg", destinationName: "Lisbon 2.jpg", isFolder: false),
                            .init(sourcePath: "/trip/x2", destinationName: "Lisbon2", isFolder: true),
                        ], onConflict: .number, numberSeparator: " "))
        }

        // B-DLG-083
        // T-379e2696
        @Test func doesntTakeTheAnswerForASheetClosedBeforeItCameIntoTheNextOne() async throws {
            let (model, box, _) = setup(settings: BatchRenameSettings(find: "IMG"), inspect: .hold)
            let other = [BatchRenameTarget(path: "/home/IMG_9.jpg", name: "IMG_9.jpg", isFolder: false)]
            model.open(targets)
            model.close()
            model.open(other)
            // The first sheet's answer comes late: it says nothing of the second sheet's items.
            await box.resolve(
                0,
                BatchRenameInspectBox.answer(
                    paths: targets.map(\.path), folderNames: ["IMG_1.jpg"],
                    cannotRename: Dictionary(uniqueKeysWithValues: targets.map { ($0.path, "locked") })))
            for _ in 0..<5 { await Task.yield() }
            #expect(model.sheet?.targets == other)
            #expect(model.sheet?.inspect == nil)
            #expect(model.request == nil)
            await box.resolve(1, BatchRenameInspectBox.answer(paths: other.map(\.path), folderNames: ["IMG_9.jpg"]))
            #expect(await answered(model))
            #expect(
                model.request?.items == [
                    .init(sourcePath: "/home/IMG_9.jpg", destinationName: "_9.jpg", isFolder: false)
                ])
        }

        // B-DLG-082 B-DLG-083
        // T-659e657d
        @Test func asksForTheDatesTakenOnceAndKeepsTheNewestSheetsAnswerWhenAnswersCross() async throws {
            let (model, box, _) = setup(inspect: .hold)
            let paths = targets.map(\.path)
            model.open(targets)
            // Dates taken are wanted before the first answer comes: they are asked for after it.
            model.setSettings(takenSettings)
            #expect(await waitUntil { box.requests.count == 1 })
            await box.resolve(0, BatchRenameInspectBox.answer(paths: paths))
            #expect(await waitUntil { box.requests.count == 2 })
            #expect(box.requests[1].includeDateTaken)
            #expect(model.sheet?.inspect == nil)
            // Switching away and back while they are read asks no more.
            model.setSettings(.defaults)
            model.setSettings(takenSettings)
            #expect(box.requests.count == 2)

            // The sheet is closed and opened again before the dates come. The new sheet asks on its own (it opens on
            // Replace Text, then Format by date taken is chosen): the old sheet's dates, coming last, are not taken.
            model.close()
            model.open(targets)
            #expect(await waitUntil { box.requests.count == 3 })
            #expect(box.requests.map(\.includeDateTaken) == [false, true, false])
            model.setSettings(takenSettings)
            await box.resolve(2, BatchRenameInspectBox.answer(paths: paths))
            #expect(await waitUntil { box.requests.count == 4 })
            await box.resolve(3, BatchRenameInspectBox.answer(paths: paths, takenAt: "2026-05-14T18:02:11"))
            #expect(await waitUntil { model.sheet?.inspectHasDatesTaken == true })
            await box.resolve(1, BatchRenameInspectBox.answer(paths: paths, takenAt: "1999-01-01T00:00:00"))
            for _ in 0..<5 { await Task.yield() }
            #expect(model.sheet?.inspectHasDatesTaken == true)
            #expect(model.request?.items.map(\.destinationName) == ["File_2026-05-14.jpg", "File_2026-05-14_2.jpg"])
        }

        // B-DLG-119
        // T-40af10cc
        @Test func keepsTheNewestPresetsDroppingTheOldestWhenThereAreTooMany() async throws {
            let many = (1...BatchRename.maxPresets).map { BatchRenamePreset(name: "Preset \($0)", settings: .defaults) }
            let (model, _, saved) = setup(presets: many)
            model.open(targets)
            #expect(model.presets.count == BatchRename.maxPresets)
            // Saved again under a name it has: replaced, and moved to the end; nothing dropped.
            model.savePreset("preset 1")
            #expect(model.presets.count == BatchRename.maxPresets)
            #expect(model.presets.first?.name == "Preset 2")
            #expect(model.presets.last?.name == "preset 1")
            // A new one: the oldest goes.
            model.savePreset("New")
            let names = model.presets.map(\.name)
            #expect(names.count == BatchRename.maxPresets)
            #expect(names.first == "Preset 3")
            #expect(Array(names.suffix(2)) == ["preset 1", "New"])
            #expect(saved.savedPresets?.map(\.name) == names)
        }
    }
}
