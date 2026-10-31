// Port of the helpers of apps/desktop/src/main/bootstrap/writeOperations.test.ts the local operations run on:
// createWriteOperationFs (a disk the test answers for), createRealWriteOperationFs (the disk itself, with a stand-in
// Trash), inTrash and createStats
import Darwin
import FTFileSystem
import FTFoundation
import Foundation
import Testing
import os

@testable import FTOperations

/// `createWriteOperationFs` / `createRealWriteOperationFs`: every call goes through a closure the test can replace,
/// and is recorded. Calls come from the operations' disk threads.
final class TestLocalFileSystem: LocalWriteFileSystem, @unchecked Sendable {
    struct Calls {
        var lstat: [String] = []
        var stat: [String] = []
        var mkdir: [String] = []
        var rename: [(String, String)] = []
        var renameExclusive: [(String, String)] = []
        var rm: [(String, Bool, Bool)] = []
        var trash: [String] = []
        var readdir: [String] = []
    }

    private let lock = NSRecursiveLock()
    private var recorded = Calls()

    var lstatImpl: @Sendable (String) throws -> WriteServiceStats
    var statImpl: @Sendable (String) throws -> WriteServiceStats
    var mkdirImpl: @Sendable (String) throws -> Void
    var renameImpl: @Sendable (String, String) throws -> Void
    var renameExclusiveImpl: @Sendable (String, String) throws -> Void
    var rmImpl: @Sendable (String, Bool, Bool) throws -> Void
    var trashImpl: @Sendable (String) throws -> String?
    var readdirImpl: @Sendable (String) throws -> [String]
    var realpathImpl: @Sendable (String) throws -> String
    var getFlagsImpl: @Sendable (String) throws -> UInt32
    var itemSizeImpl: (@Sendable (String) throws -> ItemSize)?

    init(
        lstat: @escaping @Sendable (String) throws -> WriteServiceStats,
        stat: @escaping @Sendable (String) throws -> WriteServiceStats,
        mkdir: @escaping @Sendable (String) throws -> Void, rename: @escaping @Sendable (String, String) throws -> Void,
        renameExclusive: @escaping @Sendable (String, String) throws -> Void,
        rm: @escaping @Sendable (String, Bool, Bool) throws -> Void,
        trash: @escaping @Sendable (String) throws -> String?,
        readdir: @escaping @Sendable (String) throws -> [String],
        realpath: @escaping @Sendable (String) throws -> String,
        getFlags: @escaping @Sendable (String) throws -> UInt32
    ) {
        lstatImpl = lstat
        statImpl = stat
        mkdirImpl = mkdir
        renameImpl = rename
        renameExclusiveImpl = renameExclusive
        rmImpl = rm
        trashImpl = trash
        readdirImpl = readdir
        realpathImpl = realpath
        getFlagsImpl = getFlags
    }

    /// `createWriteOperationFs`: nothing is there (lstat fails, without a code), every folder exists, and every
    /// write works; the Trash says where an item went (`inTrash`).
    static func stub() -> TestLocalFileSystem {
        TestLocalFileSystem(
            lstat: { _ in throw OperationError("missing") }, stat: { _ in Stats.directory() }, mkdir: { _ in },
            rename: { _, _ in }, renameExclusive: { _, _ in }, rm: { _, _, _ in }, trash: { inTrash($0) },
            readdir: { path in throw NativeError.errno(ENOENT, syscall: "scandir", path: path) },
            realpath: { $0 }, getFlags: { _ in 0 })
    }

    /// `createRealWriteOperationFs`: the disk itself, with a Trash that only says where an item would have gone.
    static func real() -> TestLocalFileSystem {
        let disk = NativeWriteFileSystem()
        let fileSystem = TestLocalFileSystem(
            lstat: { try disk.lstat($0) }, stat: { try disk.stat($0) }, mkdir: { try disk.mkdir($0) },
            rename: { try disk.rename($0, $1) }, renameExclusive: { try disk.renameExclusive($0, $1) },
            rm: { try disk.rm($0, recursive: $1, force: $2) }, trash: { inTrash($0) },
            readdir: { try disk.readdir($0) }, realpath: { try disk.realpath($0) },
            getFlags: { try disk.getFlags($0) })
        fileSystem.itemSizeImpl = { try NativeItemSize.of($0) }
        return fileSystem
    }

    var calls: Calls { lock.withLock { recorded } }

    private func record(_ change: (inout Calls) -> Void) {
        lock.withLock { change(&recorded) }
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        record { $0.lstat.append(path) }
        return try lstatImpl(path)
    }

    func stat(_ path: String) throws -> WriteServiceStats {
        record { $0.stat.append(path) }
        return try statImpl(path)
    }

    func realpath(_ path: String) throws -> String { try realpathImpl(path) }

    func readdir(_ path: String) throws -> [String] {
        record { $0.readdir.append(path) }
        return try readdirImpl(path)
    }

    func readlink(_ path: String) throws -> String { try PosixFileSystem().readlink(path) }

    func rename(_ from: String, _ to: String) throws {
        record { $0.rename.append((from, to)) }
        try renameImpl(from, to)
    }

    func renameExclusive(_ from: String, _ to: String) throws {
        record { $0.renameExclusive.append((from, to)) }
        try renameExclusiveImpl(from, to)
    }

    func mkdir(_ path: String) throws {
        record { $0.mkdir.append(path) }
        try mkdirImpl(path)
    }

    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        record { $0.rm.append((path, recursive, force)) }
        try rmImpl(path, recursive, force)
    }

    func rmdir(_ path: String) throws { throw OperationError("rmdir isn't used by these operations") }

    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        throw OperationError("copyFile isn't used by these operations")
    }

    func getFlags(_ path: String) throws -> UInt32 { try getFlagsImpl(path) }
    func setFlags(_ path: String, _ flags: UInt32) throws {}

    var trash: ((String) throws -> String?)? {
        { [self] path in
            record { $0.trash.append(path) }
            return try trashImpl(path)
        }
    }

    var itemSize: ((String) throws -> ItemSize)? {
        guard let itemSizeImpl else { return nil }
        return { try itemSizeImpl($0) }
    }
}

/// `inTrash`: where a stand-in Trash says an item went.
func inTrash(_ path: String) -> String {
    "/Users/demo/.Trash/\(NodePath.basename(path))"
}

/// `createStats`.
enum Stats {
    static func file(dev: Int64? = nil, ino: UInt64? = nil, mtimeMs: Double? = nil) -> WriteServiceStats {
        WriteServiceStats(type: .file, mtimeMs: mtimeMs, ino: ino, dev: dev)
    }

    static func directory(dev: Int64? = nil, ino: UInt64? = nil, mtimeMs: Double? = nil) -> WriteServiceStats {
        WriteServiceStats(type: .directory, mtimeMs: mtimeMs, ino: ino, dev: dev)
    }
}

/// An error with a Node code (`Object.assign(new Error(message), { code })`).
func errorWithCode(_ message: String, _ code: String) -> OperationError {
    OperationError(message, code: code)
}

/// A disk call the test holds until it lets it go: the call says it has begun, then waits.
final class HeldCall: @unchecked Sendable {
    private struct State {
        var hasBegun = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())

    var hasBegun: Bool { state.withLock { $0.hasBegun } }

    /// Returns once the call has begun: told by the call itself, so a busy machine only makes it later.
    func begun() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let begun = state.withLock { state in
                if !state.hasBegun { state.waiters.append(continuation) }
                return state.hasBegun
            }
            if begun { continuation.resume() }
        }
    }

    /// From the disk thread.
    func hold() {
        let waiters = state.withLock { state in
            state.hasBegun = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}

extension WriteCoordinator {
    /// `createWriteOperationCoordinator(createWriteServiceStub(), fs, options)`.
    static func local(
        _ fileSystem: TestLocalFileSystem, homePath: String = NSHomeDirectory(),
        options: WriteCoordinatorOptions? = nil
    ) -> WriteCoordinator {
        var options = options ?? WriteCoordinatorOptions()
        options.homePath = homePath
        return WriteCoordinator(writeService: StubWriteService(), fileSystem: fileSystem, options: options)
    }
}

extension TestWindow {
    /// The statuses of everything it was sent.
    var statuses: [WriteOperationStatus] { progress.map(\.status) }

    /// `waitForTerminalEvent`, told by the window when the event comes rather than polled for until a deadline: in a
    /// full run the operation's disk thread and the main actor can both be kept waiting for seconds by other suites,
    /// which made a deadline fail operations that were only slow. A hang is caught by the suite's time limit.
    func ended(_ operationId: String) async -> WriteOperationEvent {
        if let end = end(of: operationId) { return end }
        return await withCheckedContinuation { continuation in
            var waiting = true
            let previous = onReceive
            onReceive = { message in
                previous?(message)
                guard waiting, case .progress(let event) = message, event.operationId == operationId,
                    event.status.isTerminal
                else { return }
                waiting = false
                continuation.resume(returning: event)
            }
        }
    }
}

extension Trait where Self == TimeLimitTrait {
    /// What a local operation test may take before it counts as hung: far beyond what any of them needs, even on a
    /// machine busy with the full run.
    static var localOperationHang: Self { .timeLimit(.minutes(2)) }
}
