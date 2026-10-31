// Checks the hard watchdog of AutomationRunner, the port's own step runner; no TypeScript source.
#if DEBUG
    import AppKit
    import Foundation
    import Testing

    @testable import FTAppKit

    /// How the process would have ended, as the watchdog's queue says it.
    private final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var code: Int32?

        func set(_ value: Int32) {
            lock.lock()
            defer { lock.unlock() }
            code = value
        }

        var value: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return code
        }
    }

    @MainActor
    @Suite struct AutomationWatchdogTests {
        // A hung step is reported: the timer's closure runs on the watchdog's queue, where a closure the compiler took as
        // the main actor's would trap (crash report 2026-10-31) and leave no report.
        @Test func aStepThatHangsIsReportedFromTheWatchdogsQueue() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let runner = AutomationRunner(
                options: .init(scenario: folder.appendingPathComponent("hang.json"), out: folder, elements: nil),
                controller: { nil })
            let exited = ExitBox()
            runner.hardTimeout = 0.05
            runner.exitProcess = { exited.set($0) }
            runner.armHardWatchdog(index: 4, step: .open(path: "/"))
            #expect(await waitUntil { exited.value != nil })
            #expect(exited.value == 3)
            let written = try String(contentsOf: folder.appendingPathComponent("report.json"), encoding: .utf8)
            #expect(written.contains("stopped at step 4: main thread hung"))
            #expect(written.contains("the main thread stopped responding"))
        }
    }
#endif
