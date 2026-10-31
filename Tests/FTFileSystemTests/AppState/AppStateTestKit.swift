// Test doubles for the state store: timers that run when the test says so, and a file system that counts writes.
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation

/// Timers that only run when the test says so.
final class ManualTimer: StateTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [Int: (action: @Sendable () -> Void, delay: Int)] = [:]
    private var nextID = 1

    func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        timers[id] = (action, delay)
        return { [self] in
            lock.lock()
            timers[id] = nil
            lock.unlock()
        }
    }

    /// The delays of the timers pending, in the order they were set.
    var pendingDelays: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return timers.keys.sorted().compactMap { timers[$0]?.delay }
    }

    /// Runs the pending timers; one cancelled by one that ran before it does not run.
    func run() {
        lock.lock()
        let ids = timers.keys.sorted()
        lock.unlock()
        for id in ids {
            lock.lock()
            let timer = timers.removeValue(forKey: id)
            lock.unlock()
            timer?.action()
        }
    }
}

/// The real file system, recording the files written (by name) and failing a write when told to.
final class RecordingFileSystem: StateFileSystem, @unchecked Sendable {
    struct Failure: Error, Equatable { let message: String }

    private let lock = NSLock()
    private let disk = DiskFileSystem()
    private var names: [String] = []
    var failWrites: Failure?
    var renamed = 0

    var written: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func exists(_ path: String) -> Bool { disk.exists(path) }
    func createDirectory(_ path: String) throws { try disk.createDirectory(path) }
    func read(_ path: String) throws -> Data { try disk.read(path) }

    func write(_ path: String, _ contents: String) throws {
        if let failWrites { throw failWrites }
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".tmp") { name.removeLast(4) }
        lock.lock()
        names.append(name)
        lock.unlock()
        try disk.write(path, contents)
    }

    func rename(_ from: String, _ to: String) throws {
        lock.lock()
        renamed += 1
        lock.unlock()
        try disk.rename(from, to)
    }
}

enum StateTestKit {
    static func json(_ text: String) -> JSONNode {
        (try? JSONNode.parse(Data(text.utf8))) ?? .null
    }

    /// A tab as the original's tests build one, as a patch value.
    static func tab(_ path: String) -> JSONNode {
        json(
            """
            {"path": "\(path)", "treeRootPath": "/Users/demo", "favoritePath": null, "viewMode": "list",
             "searchViewMode": "details", "sortBy": "name", "sortDirection": "asc", "includeHidden": false,
             "foldersFirst": true, "favoritesExpanded": true, "locationsExpanded": true}
            """)
    }

    static func tabs(_ paths: [String]) -> JSONNode { .array(paths.map(tab)) }

    static let bounds = StoredWindowState(width: 900, height: 600, maximized: false)

    /// A folder to keep the state files in; removed when `body` ends.
    static func withFolder<T>(_ body: (String) throws -> T) throws -> T {
        let folder = try TemporaryDirectory(prefix: "filetrail-app-state")
        defer { folder.remove() }
        return try body(folder.path)
    }

    static func statePath(_ folder: String) -> String { folder + "/app-state.json" }

    static func readFile(_ path: String) -> JSONNode {
        json((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    static func store(
        _ path: String, theme: ThemePreference = .dark, fileSystem: any StateFileSystem = DiskFileSystem(),
        timer: any StateTimer = ManualTimer(), onPersistError: (@Sendable (any Error) -> Void)? = nil
    ) -> AppStateStore {
        AppStateStore(
            filePath: path, defaultTheme: theme, fileSystem: fileSystem, timer: timer,
            onReadError: { _ in }, onPersistError: onPersistError)
    }
}
