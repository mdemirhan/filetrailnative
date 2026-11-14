// Open held down on the keyboard: an archive is extracted once per press, and a folder opens as it always did
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

            // The key is still down: its repeats open the archive again, which extracts nothing more.
            window.select(["Box.zip"])
            tab.currentEvent = { returnKey(repeating: true) }
            for _ in 0..<3 { tab.openSelection(nil) }
            try? await Task.sleep(for: .milliseconds(500))
            #expect(tab.writeActions?.session.activeOperationId == nil)
            #expect(try names(window).filter { $0.hasPrefix("Box") } == ["Box", "Box.zip"])
            await window.close()
        }

        @Test func aHeldKeyOpensAFolderAsBefore() async throws {
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
