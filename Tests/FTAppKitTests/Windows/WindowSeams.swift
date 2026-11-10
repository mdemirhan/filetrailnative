import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Testing

@testable import FTAppKit

/// The window's static seams a test may replace (the visited folders' store, the dialogs' timers, the folder picker,
/// the batch rename runner), as they were before each test, put back after it whether it passed or threw.
@MainActor
enum WindowSeams {
    private struct Saved {
        var visitStore: @MainActor () -> AppStateStore?
        var dialogTimers: any TimerScheduling
        var pickDirectory: @MainActor (_ defaultPath: String?, _ window: NSWindow?) async -> String?
        var runBatchRename: @MainActor (WindowWriteActions, BatchRenameRequest) async -> Void
    }

    private static var saved: [Int: Saved] = [:]
    private static var next = 0

    static func save() -> Int {
        next += 1
        saved[next] = Saved(
            visitStore: MainWindowController.visitStore, dialogTimers: MainWindowController.dialogTimers,
            pickDirectory: MainWindowController.pickDirectory, runBatchRename: MainWindowController.runBatchRename)
        return next
    }

    static func restore(_ id: Int) {
        guard let seams = saved.removeValue(forKey: id) else { return }
        MainWindowController.visitStore = seams.visitStore
        MainWindowController.dialogTimers = seams.dialogTimers
        MainWindowController.pickDirectory = seams.pickDirectory
        MainWindowController.runBatchRename = seams.runBatchRename
    }
}

struct WindowSeamsTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let id = await WindowSeams.save()
        do {
            try await function()
        } catch {
            await WindowSeams.restore(id)
            throw error
        }
        await WindowSeams.restore(id)
    }
}

extension Trait where Self == WindowSeamsTrait {
    /// For a test that replaces one of the window's static seams: they are as they were once it ends, also when it
    /// throws before putting them back.
    static var restoresWindowSeams: Self { WindowSeamsTrait() }
}

@MainActor
struct WindowSeamsTests {
    struct Thrown: Error {}

    // A test that replaced a seam and threw before putting it back leaves it as it was.
    @Test func aTestThatThrowsLeavesTheSeamsAsTheyWere() async throws {
        let before = MainWindowController.dialogTimers
        let test = try #require(Test.current)
        await #expect(throws: Thrown.self) {
            try await WindowSeamsTrait().provideScope(for: test, testCase: Test.Case.current) {
                await MainActor.run { MainWindowController.dialogTimers = ManualTimers() }
                throw Thrown()
            }
        }
        #expect(type(of: MainWindowController.dialogTimers) == type(of: before))
        #expect(!(MainWindowController.dialogTimers is ManualTimers))
    }
}
