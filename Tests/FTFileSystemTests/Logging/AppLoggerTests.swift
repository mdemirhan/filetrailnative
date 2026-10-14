// Port of apps/desktop/src/main/appLog.test.ts, plus the line format, rotation and timing rules of appLog.ts, logRotation.ts and withTiming
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

final class RecordingSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(LogLevel, String)] = []

    func emit(_ level: LogLevel, _ text: String) {
        lock.lock()
        items.append((level, text))
        lock.unlock()
    }

    func count(_ level: LogLevel) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return items.filter { $0.0 == level }.count
    }
}

struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

struct AppLoggerTests {
    func withLogFolder<T>(_ body: (String, String) throws -> T) throws -> T {
        try StateTestKit.withFolder { folder in try body(folder, folder + "/logs/app.log") }
    }

    func read(_ path: String) -> String { (try? readAppLogFile(path)) ?? "" }

    // T-191ab8cb F-001
    @Test func persistsRegularLogLinesToDisk() throws {
        try withLogFolder { _, path in
            let sink = RecordingSink()
            let logger = AppLogger(filePath: path, debugEnabled: false, sink: sink)
            logger.info("[filetrail] app start", .context(["pid": .number(1234), "platform": .string("darwin")]))
            logger.error("[filetrail] ipc directory:getSnapshot failed", .error(Boom()))
            logger.warn("[filetrail] renderer process unresponsive", .context(["windowId": .number(1)]))
            logger.flush()

            let raw = read(path)
            #expect(raw.contains("INFO [filetrail] app start { pid: 1234, platform: 'darwin' }"))
            #expect(raw.contains("ERROR [filetrail] ipc directory:getSnapshot failed"))
            #expect(raw.contains("WARN [filetrail] renderer process unresponsive { windowId: 1 }"))
            #expect(raw.contains("Boom: boom"))
            #expect(sink.count(.info) == 1)
            #expect(sink.count(.error) == 1)
            #expect(sink.count(.warn) == 1)
        }
    }

    // T-67340d39 F-001
    @Test func skipsDebugLogsUnlessDebugModeIsEnabled() throws {
        try withLogFolder { _, path in
            let sink = RecordingSink()
            let logger = AppLogger(filePath: path, debugEnabled: false, sink: sink)
            logger.debug("[filetrail] tree:getChildren /Users/demo 180ms")
            logger.info("[filetrail] app start")
            logger.flush()

            let raw = read(path)
            #expect(raw.contains("INFO [filetrail] app start"))
            #expect(!raw.contains("DEBUG"))
            #expect(sink.count(.debug) == 0)
        }
    }

    // T-37334d5f F-001
    @Test func persistsDebugLogsWhenDebugModeIsEnabled() throws {
        try withLogFolder { _, path in
            let sink = RecordingSink()
            let logger = AppLogger(filePath: path, debugEnabled: true, sink: sink)
            logger.debug("[filetrail] tree:getChildren /Users/demo 180ms")
            logger.flush()

            #expect(read(path).contains("DEBUG [filetrail] tree:getChildren /Users/demo 180ms"))
            #expect(sink.count(.debug) == 1)
        }
    }

    // T-84c5ec86 F-001
    @Test func rotatesThePersistedAppLogWhenTheFileExceedsTheSizeLimit() throws {
        try withLogFolder { folder, path in
            let logger = AppLogger(filePath: path, maxBytes: 140, maxFiles: 3, sink: RecordingSink())
            logger.info("[filetrail] first entry", .context(["path": .string("/Users/demo/first-long-path.txt")]))
            logger.info("[filetrail] second entry", .context(["path": .string("/Users/demo/second-long-path.txt")]))
            logger.info("[filetrail] third entry", .context(["path": .string("/Users/demo/third-long-path.txt")]))
            logger.flush()

            #expect(read(path).contains("third entry"))
            let rotated = read(folder + "/logs/app.1.log")
            #expect(!rotated.isEmpty)
            #expect(rotated.contains("second entry"))
            #expect(read(folder + "/logs/app.2.log").contains("first entry"))
        }
    }

    @Test func keepsTenFilesAtMostAndNamesThemAppNLog() throws {
        try withLogFolder { folder, path in
            #expect(AppLogger.defaultMaxBytes == 5 * 1024 * 1024)
            #expect(AppLogger.defaultMaxFiles == 10)
            let logger = AppLogger(filePath: path, maxBytes: 10, maxFiles: 10, sink: RecordingSink())
            for index in 0..<15 { logger.info(.text("entry \(index)")) }
            logger.flush()
            let names = try FileManager.default.contentsOfDirectory(atPath: folder + "/logs").sorted()
            #expect(
                names == [
                    "app.1.log", "app.2.log", "app.3.log", "app.4.log", "app.5.log", "app.6.log", "app.7.log",
                    "app.8.log", "app.9.log", "app.log",
                ])
            #expect(read(path).contains("entry 14"))
            #expect(read(folder + "/logs/app.9.log").contains("entry 5"))
        }
    }

    @Test func rotationMovesEachFileUpAndADropsTheOldest() throws {
        try StateTestKit.withFolder { folder in
            let path = folder + "/app.log"
            for (name, text) in [("app.log", "now"), ("app.1.log", "one"), ("app.2.log", "two")] {
                try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
            }
            LogRotation.rotate(path, maxFiles: 3)
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(read(folder + "/app.1.log") == "now")
            #expect(read(folder + "/app.2.log") == "one")
            LogRotation.rotate(path, maxFiles: 1)
            #expect(LogRotation.fileSize(folder + "/missing.log") == 0)
        }
    }

    @Test func aLineIsTheISOTimeTheLevelAndTheArguments() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.123)
        #expect(LogFormat.timestamp(date) == "2027-01-15T08:00:00.123Z")
        #expect(
            LogFormat.line(
                .warn,
                [
                    "[x] a",
                    .value(.object(["b": .array([.number(1), .string("it's")]), "a": .null, "c-d": .bool(true)])),
                ],
                at: date)
                == "2027-01-15T08:00:00.123Z WARN [x] a { a: null, b: [ 1, \"it's\" ], 'c-d': true }")
        #expect(LogFormat.arguments([.value(.string("raw")), .value(.object([:])), .value(.array([]))]) == "raw {} []")
    }

    @Test func debugFlagsAreOnlyOnForOne() {
        #expect(AppLogger.isDebugLoggingEnabled(environment: ["FILETRAIL_DEBUG": "1"]))
        #expect(AppLogger.isDebugLoggingEnabled(environment: ["FILETRAIL_DEBUG_TIMINGS": "1"]))
        #expect(!AppLogger.isDebugLoggingEnabled(environment: ["FILETRAIL_DEBUG": "true"]))
        #expect(!AppLogger.isDebugLoggingEnabled(environment: [:]))
        #expect(Timing.timingsEnabled(environment: ["FILETRAIL_DEBUG_TIMINGS": "1"]))
        #expect(!Timing.timingsEnabled(environment: ["FILETRAIL_DEBUG": "1"]))
    }

    @Test func structuredEntriesAreNamespaceMessageErrorContext() throws {
        try withLogFolder { _, path in
            let logger = AppLogger(filePath: path, debugEnabled: false, sink: RecordingSink())
            logger.write(
                level: .error, namespace: "explorer", message: "open failed", error: Boom(),
                context: ["path": .string("/a")])
            logger.write(level: .info, namespace: "explorer", message: "done")
            logger.flush()
            let lines = read(path).split(separator: "\n")
            #expect(lines[0].hasSuffix("ERROR [explorer] open failed Boom: boom { path: '/a' }"))
            #expect(lines[1].hasSuffix("INFO [explorer] done"))
        }
    }

    @Test func slowCallsAreLoggedAtDebugLevelAndFastOnesOnlyWithTheTimingsFlag() async throws {
        let sink = RecordingSink()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let logger = AppLogger(filePath: folder.path + "/app.log", debugEnabled: true, sink: sink)
        let times = TimeBox([0, 119.4, 200, 320.5, 500, 502])

        _ = await withTiming("tree:getChildren", "/a", logger: logger, timingsEnabled: false, clock: { times.next() }) {
            1
        }
        logger.flush()
        #expect(sink.count(.debug) == 0)

        _ = await withTiming("tree:getChildren", "/b", logger: logger, timingsEnabled: false, clock: { times.next() }) {
            1
        }
        logger.flush()
        #expect(sink.count(.debug) == 1)
        #expect(
            Timing.line(label: "tree:getChildren", path: "/b", elapsedMilliseconds: 120.5)
                == "[filetrail] tree:getChildren /b 121ms")

        _ = await withTiming("path:resolve", "/c", logger: logger, timingsEnabled: true, clock: { times.next() }) { 1 }
        logger.flush()
        #expect(sink.count(.debug) == 2)
        #expect(
            try String(contentsOfFile: folder.path + "/app.log", encoding: .utf8).contains(
                "DEBUG [filetrail] path:resolve /c 2ms"))
    }
}

/// A clock that gives the times in turn.
final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double]
    init(_ times: [Double]) { self.times = times }
    func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return times.isEmpty ? 0 : times.removeFirst()
    }
}

struct TemporaryFolder {
    let path: String
    init() throws {
        path = NSTemporaryDirectory() + "filetrail-log-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
