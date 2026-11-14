import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.restoresWindowSeams) struct ConvertImagesInWindowTests {
        /// What the sheet asked to convert, in order.
        final class Requests {
            var all: [(paths: [String], options: ImageConversionOptions)] = []
        }

        struct Opened {
            var harness: ExplorerHarness
            var tab: MainWindowController
            var operations: AppWriteOperations
            var requests: Requests
            var folder: String

            func path(_ name: String) -> String { folder + "/" + name }
        }

        /// A tab on a folder of `names`, the conversions only recorded and every picture read as 2400 × 1600.
        private func open(names: [String] = ["a.jpg", "b.png", "notes.txt"]) async throws -> Opened {
            let harness = try ExplorerHarness.windowless()
            for name in names {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            let requests = Requests()
            MainWindowController.runConvertImages = { _, paths, options in requests.all.append((paths, options)) }
            MainWindowController.readImageInfos = { paths in
                paths.map { _ in ImageInfo(size: PixelSize(width: 2400, height: 1600)) }
            }
            let folder = tab.content.entries.first.map { NodePath.dirname($0.path) } ?? tab.folder.path
            return Opened(harness: harness, tab: tab, operations: operations, requests: requests, folder: folder)
        }

        private func close(_ opened: Opened) async {
            opened.tab.convertImagesSheet?.onCancel()
            withExtendedLifetime(opened.operations) {}
            await opened.harness.close()
        }

        private func select(_ opened: Opened, _ names: [String]) {
            opened.tab.content.applySelection(ContentSelection.of(names.map(opened.path)))
        }

        /// The sheet once the pictures' sizes are read.
        private func sheet(_ tab: MainWindowController) async throws -> ConvertImagesSheetView {
            #expect(await waitUntil { tab.convertImagesSheet.map { !$0.sheet.isReading } ?? false })
            let sheet = try #require(tab.convertImagesSheet)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return sheet
        }

        @Test func imagesOnlyAreConvertedAndTheMenuCountsThem() async throws {
            let opened = try await open()
            select(opened, ["a.jpg", "b.png"])
            #expect(!opened.tab.menuState.disabledCommands.contains(.convertImages))
            #expect(opened.tab.menuState.convertImagesCount == 2)
            // Anything else among them: none is converted.
            select(opened, ["a.jpg", "notes.txt"])
            #expect(opened.tab.menuState.disabledCommands.contains(.convertImages))
            await close(opened)
        }

        @Test func theSheetConvertsWhatWasSelectedAsChosenAndRemembersIt() async throws {
            let opened = try await open()
            select(opened, ["a.jpg", "b.png"])
            opened.tab.perform(.convertImages)
            let sheet = try await sheet(opened.tab)
            #expect(sheet.titleLabel.stringValue == "Convert 2 Images")
            sheet.formatPopUp.choose("HEIC")
            sheet.sizePopUp.choose("Fit Within 1280 px")
            #expect(sheet.summaryText == "2 images, each made smaller")
            sheet.convertButton.perform()
            #expect(await waitUntil { opened.requests.all.count == 1 })
            #expect(opened.tab.convertImagesSheet == nil)
            #expect(opened.requests.all.first?.paths == [opened.path("a.jpg"), opened.path("b.png")])
            #expect(opened.requests.all.first?.options.format == .heic)
            #expect(opened.requests.all.first?.options.size == .fitWithin(1280))
            #expect(opened.tab.preferences.convertImagesSettings.format == .heic)
            await close(opened)
        }

        @Test func forOneImageTheLargerSizesAreGrayed() async throws {
            let opened = try await open()
            select(opened, ["a.jpg"])
            opened.tab.perform(.convertImages)
            let sheet = try await sheet(opened.tab)
            #expect(sheet.titleLabel.stringValue == "Convert Image")
            #expect(sheet.sizePopUp.titles.contains("Fit Within 3840 px (This image is 2400 px)"))
            #expect(sheet.sizePopUp.enabledTitles.contains("Fit Within 1920 px"))
            #expect(!sheet.sizePopUp.enabledTitles.contains("Fit Within 2560 px (This image is 2400 px)"))
            await close(opened)
        }

        @Test func anExactSizeLargerThanAnImageGraysConvert() async throws {
            let opened = try await open()
            select(opened, ["a.jpg", "b.png"])
            opened.tab.perform(.convertImages)
            let sheet = try await sheet(opened.tab)
            sheet.sizePopUp.choose("Custom\u{2026}")
            sheet.proportionalCheck.toggle()
            batchRenameType(sheet.widthField, "3000")
            batchRenameType(sheet.heightField, "1000")
            #expect(!sheet.convertButton.isEnabled)
            #expect(sheet.warningTexts.first?.hasPrefix("2 of the images are smaller than 3000") == true)
            sheet.convertButton.perform()
            #expect(opened.requests.all.isEmpty)
            await close(opened)
        }

        @Test func escapeClosesTheSheetAndNothingIsConverted() async throws {
            let opened = try await open()
            select(opened, ["a.jpg"])
            opened.tab.perform(.convertImages)
            _ = try await sheet(opened.tab)
            DialogKeys.press(53, "\u{1B}", in: opened.tab.window)
            #expect(await waitUntil { opened.tab.convertImagesSheet == nil })
            #expect(opened.requests.all.isEmpty)
            await close(opened)
        }
    }
}
