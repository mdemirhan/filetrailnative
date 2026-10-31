// Port of the capture report format shared with tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import Foundation

    /// What happened to each step of a scenario, written to `<out>/report.json`.
    struct AutomationReport: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            /// Done.
            case ok
            /// Done in part; `message` lists what this app can't do yet.
            case partial
            /// Not done: this app has nothing to do it with yet.
            case unsupported
            /// Tried and failed.
            case failed
            /// Didn't settle within the watchdog's time.
            case timeout
        }

        struct Entry: Codable, Equatable, Sendable {
            var index: Int
            var step: String
            var status: Status
            var message: String?
            var milliseconds: Int
            /// An `expect` step's soft assertion: recorded, never stopping the run.
            var check: Check?
            /// A snapshot taken with the app not in front or the window not key: its colors don't compare.
            var unfocused: Bool?
        }

        struct Check: Codable, Equatable, Sendable {
            var passed: Bool
            /// What was expected and what was found.
            var detail: String
        }

        var scenario: String
        var side = "swift"
        var steps: [Entry] = []
        /// Set when the run couldn't start (unreadable scenario) or was cut short.
        var error: String?

        var unsupportedCount: Int { steps.filter { $0.status == .unsupported || $0.status == .partial }.count }
        var failedCount: Int { steps.filter { $0.status == .failed || $0.status == .timeout }.count }
        var failedChecks: Int { steps.filter { $0.check?.passed == false }.count }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    /// The report, shared with the watchdog thread so that it can write it if the main thread hangs.
    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var report: AutomationReport
        private let file: URL

        init(_ report: AutomationReport, file: URL) {
            self.report = report
            self.file = file
        }

        func update(_ change: (inout AutomationReport) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            change(&report)
        }

        var current: AutomationReport {
            lock.lock()
            defer { lock.unlock() }
            return report
        }

        func write() {
            try? current.encoded().write(to: file, options: .atomic)
        }
    }
#endif
