// Port of apps/desktop/src/main/appLog.ts
import FTFoundation
import Foundation
import os

public enum LogLevel: String, Sendable, CaseIterable {
    case debug, info, warn, error
}

/// Where a line is also echoed: the original's console, here `os.Logger`.
public protocol LogSink: Sendable {
    func emit(_ level: LogLevel, _ text: String)
}

/// Mirrors lines to the unified log.
public struct OSLogSink: LogSink {
    private let logger: Logger

    public init(subsystem: String = AppStatePaths.bundleID, category: String = "app") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func emit(_ level: LogLevel, _ text: String) {
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warn: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
}

/// The app log: `<ISO time> <LEVEL> <args…>`, one line per entry, appended to `logs/app.log`. Writes are serialized on
/// one queue and `flush()` waits for them. Before an append that would take the file past `maxBytes` the files rotate,
/// keeping `maxFiles`. Debug lines are dropped (here and in the sink) unless debug is on.
public final class AppLogger: @unchecked Sendable {
    public static let defaultMaxBytes = 5 * 1024 * 1024
    public static let defaultMaxFiles = 10

    /// `isDebugLoggingEnabled`: `FILETRAIL_DEBUG` or `FILETRAIL_DEBUG_TIMINGS` is `1`.
    public static func isDebugLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["FILETRAIL_DEBUG"] == "1" || environment["FILETRAIL_DEBUG_TIMINGS"] == "1"
    }

    private let filePath: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let debugEnabled: Bool
    private let sink: any LogSink
    private let onError: @Sendable (any Error) -> Void
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "filetrail.app-log")

    public init(
        filePath: String, maxBytes: Int = AppLogger.defaultMaxBytes, maxFiles: Int = AppLogger.defaultMaxFiles,
        debugEnabled: Bool = AppLogger.isDebugLoggingEnabled(), sink: any LogSink = OSLogSink(),
        onError: (@Sendable (any Error) -> Void)? = nil, now: @escaping @Sendable () -> Date = { AppClock.now }
    ) {
        self.filePath = filePath
        self.maxBytes = maxBytes
        self.maxFiles = max(1, maxFiles)
        self.debugEnabled = debugEnabled
        self.sink = sink
        self.onError =
            onError ?? { error in
                Logger(subsystem: AppStatePaths.bundleID, category: "app-log")
                    .error("[filetrail] app log failed \(String(describing: error), privacy: .public)")
            }
        self.now = now
    }

    public var isDebugEnabled: Bool { debugEnabled }

    public func debug(_ args: LogArg...) { emit(.debug, args) }
    public func info(_ args: LogArg...) { emit(.info, args) }
    public func warn(_ args: LogArg...) { emit(.warn, args) }
    public func error(_ args: LogArg...) { emit(.error, args) }

    public func log(_ level: LogLevel, _ args: [LogArg]) { emit(level, args) }

    /// `writeStructuredAppLogEntry`: `[namespace] message`, then the error, then the context when it has anything.
    public func write(
        level: LogLevel, namespace: String, message: String, error: (any Error)? = nil,
        context: [String: JSONNode] = [:]
    ) {
        var args: [LogArg] = [.text("[\(namespace)] \(message)")]
        if let error { args.append(.error(error)) }
        if !context.isEmpty { args.append(.context(context)) }
        emit(level, args)
    }

    /// Waits for the lines written so far to reach the file.
    public func flush() {
        queue.sync {}
    }

    private func emit(_ level: LogLevel, _ args: [LogArg]) {
        guard level != .debug || debugEnabled else { return }
        let date = now()
        sink.emit(level, LogFormat.arguments(args))
        queue.async { [self] in
            do {
                try append(LogFormat.line(level, args, at: date) + "\n")
            } catch {
                onError(error)
            }
        }
    }

    private func append(_ line: String) throws {
        let data = Data(line.utf8)
        try FileManager.default.createDirectory(
            atPath: (filePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let size = LogRotation.fileSize(filePath)
        if size > 0 && size + data.count > maxBytes {
            LogRotation.rotate(filePath, maxFiles: maxFiles)
        }
        if !FileManager.default.fileExists(atPath: filePath) {
            guard FileManager.default.createFile(atPath: filePath, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

/// `readAppLogFile`.
public func readAppLogFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}
