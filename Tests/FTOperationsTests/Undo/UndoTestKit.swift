// Port of apps/desktop/src/main/bootstrap/undoRealDisk.testkit.ts: Undo and Redo on a real disk, through the write
// coordinator as the app runs them
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import os

@testable import FTOperations

/// The disk itself (the app's native file system) with a Trash that is a plain folder, every call of which a test may
/// answer for instead (`fsOverrides`). Each override is given the disk to pass the call on to.
final class UndoTestFileSystem: UndoFileSystem, @unchecked Sendable {
    let base: NativeWriteFileSystem
    private let lock = NSRecursiveLock()

    var lstatImpl: ((String) throws -> WriteServiceStats)?
    var statImpl: ((String) throws -> WriteServiceStats)?
    var readdirImpl: ((String) throws -> [String])?
    var renameImpl: ((String, String) throws -> Void)?
    var renameExclusiveImpl: ((String, String) throws -> Void)?
    var trashImpl: ((String) throws -> String?)?
    var getFlagsImpl: ((String) throws -> UInt32)?
    var setFlagsImpl: ((String, UInt32) throws -> Void)?
    var chmodImpl: ((String, UInt32) throws -> Void)?
    var getAclImpl: ((String) throws -> String?)?
    var setAclImpl: ((String, String?) throws -> Void)?
    var isPackageImpl: ((String) throws -> Bool?)?
    var rmImpl: ((String, Bool, Bool) throws -> Void)?
    var itemSizeImpl: ((String) throws -> ItemSize)?

    /// `createOriginalWriteOperationFs(folderTrash(trashDir))`.
    init(trashDir: String) {
        base = NativeWriteFileSystem(trash: UndoTestFileSystem.folderTrash(trashDir))
    }

    /// `folderTrash`: a Trash that is a plain folder: each item gets a number in front of its name there.
    static func folderTrash(_ trashDir: String) -> @Sendable (String) throws -> String? {
        let count = OSAllocatedUnfairLock(initialState: 0)
        return { path in
            let number = count.withLock { value -> Int in
                value += 1
                return value
            }
            let destination = "\(trashDir)/\(number)-\(NodePath.basename(path))"
            if Darwin.rename(path, destination) != 0 {
                throw NativeError.errno(errno, syscall: "rename", path: path, dest: destination)
            }
            return destination
        }
    }

    private func impl<T>(_ keyPath: KeyPath<UndoTestFileSystem, T?>) -> T? {
        lock.withLock { self[keyPath: keyPath] }
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try impl(\.lstatImpl)?(path) ?? base.lstat(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try impl(\.statImpl)?(path) ?? base.stat(path) }
    func realpath(_ path: String) throws -> String { try base.realpath(path) }
    func readdir(_ path: String) throws -> [String] { try impl(\.readdirImpl)?(path) ?? base.readdir(path) }
    func readlink(_ path: String) throws -> String { try base.readlink(path) }
    func isCaseSensitive(_ path: String) throws -> Bool? { try base.isCaseSensitive(path) }
    func isPackage(_ path: String) throws -> Bool? {
        if let isPackageImpl = impl(\.isPackageImpl) { return try isPackageImpl(path) }
        return try base.isPackage(path)
    }
    func isAppleDouble(_ path: String) -> Bool { base.isAppleDouble(path) }
    func rename(_ from: String, _ to: String) throws {
        if let renameImpl = impl(\.renameImpl) { return try renameImpl(from, to) }
        try base.rename(from, to)
    }
    func renameExclusive(_ from: String, _ to: String) throws {
        if let renameExclusiveImpl = impl(\.renameExclusiveImpl) { return try renameExclusiveImpl(from, to) }
        try base.renameExclusive(from, to)
    }
    func mkdir(_ path: String) throws { try base.mkdir(path) }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        if let rmImpl = impl(\.rmImpl) { return try rmImpl(path, recursive, force) }
        try base.rm(path, recursive: recursive, force: force)
    }
    func rmdir(_ path: String) throws { try base.rmdir(path) }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        try base.copyFile(source, destination, stop: stop, onProgress: onProgress)
    }
    func getFlags(_ path: String) throws -> UInt32 { try impl(\.getFlagsImpl)?(path) ?? base.getFlags(path) }
    func setFlags(_ path: String, _ flags: UInt32) throws {
        if let setFlagsImpl = impl(\.setFlagsImpl) { return try setFlagsImpl(path, flags) }
        try base.setFlags(path, flags)
    }
    var chmod: ((String, UInt32) throws -> Void)? {
        { [self] path, mode in
            if let chmodImpl = impl(\.chmodImpl) { return try chmodImpl(path, mode) }
            try base.chmod?(path, mode)
        }
    }
    var utimes: ((String, Double, Double) throws -> Void)? { base.utimes }
    var copyMetadata: ((String, String) throws -> Void)? { base.copyMetadata }
    var setAcl: ((String, String?) throws -> Void)? {
        { [self] path, acl in
            if let setAclImpl = impl(\.setAclImpl) { return try setAclImpl(path, acl) }
            try base.setAcl?(path, acl)
        }
    }
    var getAcl: ((String) throws -> String?)? {
        { [self] path in
            if let getAclImpl = impl(\.getAclImpl) { return try getAclImpl(path) }
            return try base.getAcl?(path) ?? nil
        }
    }
    var trash: ((String) throws -> String?)? {
        { [self] path in
            if let trashImpl = impl(\.trashImpl) { return try trashImpl(path) }
            return try base.trash?(path) ?? nil
        }
    }
    var canModifyFolder: ((String) throws -> Void)? { base.canModifyFolder }
    var itemSize: ((String) throws -> ItemSize)? {
        if let itemSizeImpl = impl(\.itemSizeImpl) { return itemSizeImpl }
        return base.itemSize
    }
}

/// `setUpUndo`: a coordinator with a history, its Trash in `trashDir`, and helpers that run each operation to its end.
@MainActor
final class UndoTest {
    let root: String
    let trashDir: String
    let history: UndoHistory
    let fileSystem: UndoTestFileSystem
    let coordinator: WriteCoordinator
    let window = TestWindow()
    let log = LogRecorder()

    init(
        root: String, trashDir: String, configure: (UndoTestFileSystem) -> Void = { _ in },
        diskHasTrash: (@Sendable (String) throws -> Bool)? = nil,
        undoCheckWithinMs: Double = WriteCoordinator.undoCheckWithinMs
    ) {
        self.root = root
        self.trashDir = trashDir
        let history = UndoHistory()
        self.history = history
        fileSystem = UndoTestFileSystem(trashDir: trashDir)
        configure(fileSystem)
        let log = log
        coordinator = WriteCoordinator(
            writeService: StubWriteService(), fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: root, recordUndo: { history.record($0) }, diskHasTrash: diskHasTrash, undoHistory: history,
                undoCheckWithinMs: undoCheckWithinMs, logError: { log.log($0, $1) }))
    }

    /// Waits for the end of `handle`'s operation, told by the window when it comes. The original polls for it until a
    /// 10 s deadline; here other suites can keep the main actor waiting for longer than that in a full run, and the
    /// poll then woke past the deadline before the end it had been waiting for was delivered. A hang is caught by the
    /// suite's time limit (`localOperationHang`).
    func finish(_ handle: WriteOperationHandle) async throws -> WriteOperationEvent {
        await window.ended(handle.operationId)
    }

    @discardableResult
    func rename(_ path: String, _ name: String) async throws -> WriteOperationEvent {
        try await finish(coordinator.rename(sourcePath: path, destinationName: name, window: window))
    }

    @discardableResult
    func newFolder(_ parent: String, _ name: String) async throws -> WriteOperationEvent {
        try await finish(coordinator.createFolder(parentDirectoryPath: parent, folderName: name, window: window))
    }

    @discardableResult
    func trash(_ paths: String...) async throws -> WriteOperationEvent {
        try await finish(coordinator.trash(paths: paths, window: window))
    }

    /// `batchRename`: each item to its name (a folder when said so), a taken name numbered with a space.
    @discardableResult
    func batchRename(_ pairs: [(String, String, Bool)]) async throws -> WriteOperationEvent {
        try await batchRename(
            BatchRenameRequest(
                items: pairs.map { .init(sourcePath: $0.0, destinationName: $0.1, isFolder: $0.2) },
                onConflict: .number, numberSeparator: " "))
    }

    @discardableResult
    func batchRename(_ pairs: [(String, String)]) async throws -> WriteOperationEvent {
        try await batchRename(pairs.map { ($0.0, $0.1, false) })
    }

    /// `writeOperation:batchRename` with the request as it is.
    @discardableResult
    func batchRename(_ request: BatchRenameRequest) async throws -> WriteOperationEvent {
        try await finish(coordinator.batchRename(request, window: window))
    }

    func prepare(_ direction: UndoDirection = .undo) async throws -> UndoPrepared {
        try await coordinator.prepareUndo(direction)
    }

    /// Looks first, then undoes (or redoes) all of it, as when what it asked was agreed to.
    @discardableResult
    func undo(_ direction: UndoDirection = .undo) async throws -> WriteOperationEvent {
        let prepared = try await prepare(direction)
        guard let ticket = prepared.ticket else {
            throw OperationError("Nothing to \(direction.rawValue): \(prepared.refusal?.rawValue ?? "")")
        }
        return try await finish(coordinator.startUndo(ticket: ticket, window: window))
    }

    /// `paste`: a paste through the copy engine, recorded as the coordinator records one.
    @discardableResult
    func paste(
        _ mode: CopyPasteMode, _ sources: [String], into destination: String,
        policy: CopyPastePolicy = NativePaste.keepExisting, fileSystem: (any WriteServiceFileSystem)? = nil,
        action: WriteOperationAction = .paste
    ) async throws -> CopyPasteOperationResult {
        let run = try await runPaste(
            mode: mode, sources: sources, into: destination, policy: policy,
            fileSystem: fileSystem ?? NativeWriteFileSystem())
        guard let result = run.result, let undoLog = result.undoLog else {
            throw OperationError("The paste recorded nothing.")
        }
        history.record(
            FinishedWrite(action: .write(action), log: undoLog, items: result.items.map(WriteOperationItem.init)))
        return result
    }

    /// `snapshotOf`: every item under `root` but the Trash: path, kind and id.
    func snapshot() -> [String] {
        UndoDisk.snapshot(root, skipping: trashDir)
    }

    /// The names in the Trash, sorted.
    func inTrash() -> [String] {
        UndoDisk.names(trashDir)
    }

    func shutDown() async {
        await coordinator.shutDown()
    }

    /// Stop pressed on the running operation, from a disk thread (a test's own disk call): the main actor is free
    /// then, waiting for the operation.
    nonisolated func pressStop() {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                if let operationId = coordinator.activeOperationId {
                    coordinator.cancel(operationId, window: window)
                }
            }
        }
    }

    /// Every progress event the window was sent, in order.
    var events: [WriteOperationEvent] { window.progress }
}

/// A fresh folder with a Trash in it (`root`, `trashDir`), removed afterwards.
@MainActor
func withUndoFolder(
    _ body: @MainActor (_ root: String, _ trashDir: String) async throws -> Void
) async throws {
    let directory = try TemporaryDirectory(prefix: "filetrail-undo")
    defer { directory.remove() }
    let trashDir = directory.path + "/.Trash"
    try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: false)
    try await body(directory.path, trashDir)
}

/// The disk as the undo tests read and change it (node:fs's sync calls).
enum UndoDisk {
    static func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    static func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    static func move(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: from, dest: to)
        }
    }

    static func exists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func ino(_ path: String) -> UInt64? {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    static func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted {
            $0.utf16.lexicographicallyPrecedes($1.utf16)
        }
    }

    /// `snapshotOf`.
    static func snapshot(_ root: String, skipping trashDir: String) -> [String] {
        var lines: [String] = []
        func walk(_ folder: String) {
            for name in names(folder) {
                let path = folder + "/" + name
                if path == trashDir { continue }
                var info = Darwin.stat()
                guard Darwin.lstat(path, &info) == 0 else { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                let relative = String(path.dropFirst(root.count + 1))
                lines.append("\(relative) \(isDirectory ? "dir" : "file") \(info.st_ino)")
                if isDirectory { walk(path) }
            }
        }
        walk(root)
        return lines
    }
}

/// An error with a Node code, as the original's tests throw them (`Object.assign(new Error(code), { code })`).
func codedError(_ code: String, _ message: String? = nil, cause: (any Error)? = nil) -> OperationError {
    OperationError(message ?? code, code: code, cause: cause)
}

/// `noTrash`: the Trash failing on a disk macOS says has none.
func noTrashError() -> OperationError {
    codedError("ENOTRASH", "no Trash", cause: codedError("ENOTSUP", "not supported"))
}
