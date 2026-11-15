// Open held down on the keyboard: an archive is extracted and a disk image mounted once per press, and a folder or a
// file opens as it always did
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct OpenKeyRepeatTests {
        /// Return pressed, or held down.
        private func returnKey(repeating: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeating, keyCode: 36)
        }

        private func names(_ window: WritingWindow) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: window.folder.path).sorted()
        }

        @Test func aHeldKeyExtractsAnArchiveOnce() async throws {
            // A folder of its own, holding the archive before the window reads it.
            let maker = try TemporaryDirectory(prefix: "filetrail-zip-maker")
            defer { maker.remove() }
            try FileManager.default.createDirectory(atPath: "\(maker.path)/Box", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: "\(maker.path)/Shown", withIntermediateDirectories: false)
            try Data("x".utf8).write(to: URL(fileURLWithPath: "\(maker.path)/Box/inside.txt"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-r", "Shown/Box.zip", "Box"]
            process.currentDirectoryURL = URL(fileURLWithPath: maker.path)
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let window = try await WritingWindow.open("\(maker.path)/Shown")
            let tab = window.tab
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "Box.zip" } })

            window.select(["Box.zip"])
            tab.currentEvent = { returnKey(repeating: false) }
            tab.openSelection(nil)
            #expect(await waitUntil { (try? names(window))?.contains("Box") == true })
            #expect(await waitUntil { tab.writeActions?.session.activeOperationId == nil })

            // The key is still down, and what came out is selected now: its repeats don't open that.
            #expect(await waitUntil { tab.content.selectedEntries.map(\.name) == ["Box"] })
            let shown = tab.shownFolderPath
            tab.currentEvent = { returnKey(repeating: true) }
            for _ in 0..<3 { tab.openSelection(nil) }
            // Nor do they open the archive again, which would extract it once more.
            window.select(["Box.zip"])
            for _ in 0..<3 { tab.openSelection(nil) }
            try? await Task.sleep(for: .milliseconds(500))
            #expect(tab.shownFolderPath == shown)
            #expect(tab.writeActions?.session.activeOperationId == nil)
            #expect(try names(window).filter { $0.hasPrefix("Box") } == ["Box", "Box.zip"])

            // Let go and pressed again, the key opens the folder that came out.
            window.select(["Box"])
            tab.currentEvent = { returnKey(repeating: false) }
            tab.openSelection(nil)
            #expect(await waitUntil { tab.shownFolderPath == shown + "/Box" })
            await window.close()
        }

        // Each repeat would open the disk in another window.
        @Test func aHeldKeyMountsADiskImageOnce() async throws {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("image.dmg"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            let image = try #require(tab.content.listed.first { $0.name == "image.dmg" })
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .handedOff)
            }
            var handedToMacOS: [URL] = []
            tab.openFile = { handedToMacOS.append($0) }

            tab.currentEvent = { returnKey(repeating: false) }
            tab.open([image])
            #expect(await waitUntil { mounted == [image.path] })
            tab.currentEvent = { returnKey(repeating: true) }
            for _ in 0..<3 { tab.open([image]) }
            try? await Task.sleep(for: .milliseconds(300))
            #expect(mounted == [image.path])

            // The key let go of and pressed again opens it again.
            tab.currentEvent = { returnKey(repeating: false) }
            tab.open([image])
            #expect(await waitUntil { mounted == [image.path, image.path] })
            #expect(handedToMacOS.isEmpty)
            await harness.close()
        }

        @Test func aHeldKeyMountsADiskImageALinkLeadsToOnce() async throws {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("image.dmg"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: harness.folder.appending("Link"), withDestinationURL: harness.folder.appending("image.dmg"))
            let tab = try await harness.open()
            let link = try #require(tab.content.listed.first { $0.name == "Link" })
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .handedOff)
            }
            let image = harness.folder.appending("image.dmg").path
            tab.currentEvent = { returnKey(repeating: false) }
            tab.open([link])
            #expect(await waitUntil { mounted == [image] })
            tab.currentEvent = { returnKey(repeating: true) }
            for _ in 0..<3 { tab.open([link]) }
            try? await Task.sleep(for: .milliseconds(300))
            #expect(mounted == [image])
            await harness.close()
        }

        // macOS is given the file on every repeat, as before: an open document or app comes to the front.
        @Test func aHeldKeyOpensAFileAsBefore() async throws {
            // No key held since an earlier test's took an archive apart.
            MainWindowController.heldKeyTookApart = false
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("notes.txt"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            let file = try #require(tab.content.listed.first { $0.name == "notes.txt" })
            var handedToMacOS: [URL] = []
            tab.openFile = { handedToMacOS.append($0) }
            tab.currentEvent = { returnKey(repeating: false) }
            tab.open([file])
            tab.currentEvent = { returnKey(repeating: true) }
            for _ in 0..<2 { tab.open([file]) }
            #expect(handedToMacOS.map(\.path) == Array(repeating: file.path, count: 3))
            await harness.close()
        }

        @Test func aHeldKeyOpensAFolderAsBefore() async throws {
            // No key held since an earlier test's took an archive apart.
            MainWindowController.heldKeyTookApart = false
            let window = try await WritingWindow.open()
            let tab = window.tab
            window.select(["Alpha"])
            tab.currentEvent = { returnKey(repeating: true) }
            tab.openSelection(nil)
            #expect(await waitUntil { tab.shownFolderPath == window.folder.appendingPathComponent("Alpha").path })
            await window.close()
        }
    }
}
