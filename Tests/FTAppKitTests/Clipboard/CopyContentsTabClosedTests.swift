// Copy Contents of a file slow to read, in a tab closed before the read ends
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct CopyContentsTabClosedTests {
        /// A read the test holds until it lets it go.
        private final class HeldRead: Sendable {
            private let state = OSAllocatedUnfairLock(initialState: (asked: false, released: false, ended: false))
            var asked: Bool { state.withLock { $0.asked } }
            var ended: Bool { state.withLock { $0.ended } }
            func release() { state.withLock { $0.released = true } }
            func ask() async {
                state.withLock { $0.asked = true }
                while !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(5)) }
            }
            func end() { state.withLock { $0.ended = true } }
        }

        // The copier asks the tab for its window and its toasts once the file is read: the tab is still there then,
        // though it was closed meanwhile. Let go of before the copy ended, the app went down here.
        @Test func aSlowReadEndingAfterItsTabIsClosedStillCopies() async throws {
            let harness = try ExplorerHarness.windowless()
            let held = HeldRead()
            // The test keeps no hold on the tab itself: the copy under way is what holds it.
            weak var closed: MainWindowController?
            do {
                let tab = try await harness.open()
                let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
                tab.contentsCopier.read = { path, guess in
                    await held.ask()
                    let result = await FileContents.read(path, guess: guess)
                    held.end()
                    return result
                }
                tab.content.select(paths: [note])
                tab.perform(.copyContents)
                #expect(await waitUntil { held.asked })
                closed = tab
            }
            await harness.close()
            await settle()
            #expect(closed != nil)
            held.release()
            #expect(await waitUntil { held.ended })
            // What follows the read (the tab's window and toasts are asked for) runs on the main actor; the tab
            // goes once it has.
            #expect(await waitUntil { closed == nil })
        }
    }
}
