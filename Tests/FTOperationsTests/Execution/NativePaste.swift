// Port of packages/core/src/fs/testNativePaste.ts: the paste engine as the app runs it, for real-disk tests (the
// native copy, exclusive rename, lock flags, and a Trash that keeps what goes into it), and the mock helpers of
// copyPasteExecution.test.ts (createResolvedOperation)
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import os

@testable import FTOperations

/// A file system with any call replaced, as the original's tests spread one (`{ ...nativeFileSystem, copyFile }`).
/// The optional calls are copied from `base`, so a test can also take one away.
final class TestFileSystem: WriteServiceFileSystem, @unchecked Sendable {
    let base: any WriteServiceFileSystem
    var lstatImpl: ((String) throws -> WriteServiceStats)?
    var statImpl: ((String) throws -> WriteServiceStats)?
    var realpathImpl: ((String) throws -> String)?
    var readdirImpl: ((String) throws -> [String])?
    var readlinkImpl: ((String) throws -> String)?
    var renameExclusiveImpl: ((String, String) throws -> Void)?
    var mkdirImpl: ((String) throws -> Void)?
    var rmImpl: ((String, Bool, Bool) throws -> Void)?
    var rmdirImpl: ((String) throws -> Void)?
    var copyFileImpl: ((String, String, StopSignal?, (@Sendable (Int64) -> Void)?) throws -> Void)?
    var getFlagsImpl: ((String) throws -> UInt32)?
    var setFlagsImpl: ((String, UInt32) throws -> Void)?
    var isPackageImpl: ((String) throws -> Bool?)?
    var isAppleDoubleImpl: ((String) -> Bool)?
    var isCaseSensitiveImpl: ((String) throws -> Bool?)?
    var chmod: ((String, UInt32) throws -> Void)?
    var utimes: ((String, Double, Double) throws -> Void)?
    var copyMetadata: ((String, String) throws -> Void)?
    var setAcl: ((String, String?) throws -> Void)?
    var trash: ((String) throws -> String?)?
    var canModifyFolder: ((String) throws -> Void)?

    init(_ base: any WriteServiceFileSystem = NativeWriteFileSystem()) {
        self.base = base
        chmod = base.chmod
        utimes = base.utimes
        copyMetadata = base.copyMetadata
        setAcl = base.setAcl
        trash = base.trash
        canModifyFolder = base.canModifyFolder
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try lstatImpl?(path) ?? base.lstat(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try statImpl?(path) ?? base.stat(path) }
    func realpath(_ path: String) throws -> String { try realpathImpl?(path) ?? base.realpath(path) }
    func readdir(_ path: String) throws -> [String] { try readdirImpl?(path) ?? base.readdir(path) }
    func readlink(_ path: String) throws -> String { try readlinkImpl?(path) ?? base.readlink(path) }
    func isCaseSensitive(_ path: String) throws -> Bool? {
        if let isCaseSensitiveImpl { return try isCaseSensitiveImpl(path) }
        return try base.isCaseSensitive(path)
    }
    func isPackage(_ path: String) throws -> Bool? {
        if let isPackageImpl { return try isPackageImpl(path) }
        return try base.isPackage(path)
    }
    func isAppleDouble(_ path: String) -> Bool { isAppleDoubleImpl?(path) ?? base.isAppleDouble(path) }
    func renameExclusive(_ from: String, _ to: String) throws {
        if let renameExclusiveImpl { return try renameExclusiveImpl(from, to) }
        try base.renameExclusive(from, to)
    }
    func mkdir(_ path: String) throws {
        if let mkdirImpl { return try mkdirImpl(path) }
        try base.mkdir(path)
    }
    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        if let rmImpl { return try rmImpl(path, recursive, force) }
        try base.rm(path, recursive: recursive, force: force)
    }
    func rmdir(_ path: String) throws {
        if let rmdirImpl { return try rmdirImpl(path) }
        try base.rmdir(path)
    }
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        if let copyFileImpl { return try copyFileImpl(source, destination, stop, onProgress) }
        try base.copyFile(source, destination, stop: stop, onProgress: onProgress)
    }
    func getFlags(_ path: String) throws -> UInt32 { try getFlagsImpl?(path) ?? base.getFlags(path) }
    func setFlags(_ path: String, _ flags: UInt32) throws {
        if let setFlagsImpl { return try setFlagsImpl(path, flags) }
        try base.setFlags(path, flags)
    }
}

enum NativePaste {
    static let replaceAll = CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite)
    static let keepExisting = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)

    /// `nativeFileSystemWithTrash(trashDir)`: the native file system with a Trash, a folder items are moved into
    /// as "<n>-<name>", so a test can see what a Replace removed.
    static func withTrash(_ trashDir: String) -> NativeWriteFileSystem {
        let count = OSAllocatedUnfairLock(initialState: 0)
        return NativeWriteFileSystem(trash: { path in
            let number = count.withLock { value in
                value += 1
                return value
            }
            let inTrash = trashDir + "/\(number)-\(NodePath.basename(path))"
            if Darwin.rename(path, inTrash) != 0 {
                throw NativeError.errno(errno, syscall: "rename", path: path, dest: inTrash)
            }
            return inTrash
        })
    }

    /// `asOnAnotherDisk(sourceFolder, fileSystem)`: what is in `sourceFolder` seems to be on a disk of its own,
    /// and can't be renamed out of it (EXDEV), so a move copies it and removes the originals.
    static func asOnAnotherDisk(_ sourceFolder: String, _ base: any WriteServiceFileSystem = NativeWriteFileSystem())
        -> TestFileSystem
    {
        let fileSystem = TestFileSystem(base)
        let isOnIt = { (path: String) in sameText(path, sourceFolder) || path.hasPrefix(sourceFolder + "/") }
        let onItsDisk = { (path: String, stats: WriteServiceStats) -> WriteServiceStats in
            var stats = stats
            if isOnIt(path), let dev = stats.dev {
                stats.dev = dev + 1
            }
            return stats
        }
        fileSystem.lstatImpl = { path in onItsDisk(path, try base.lstat(path)) }
        fileSystem.statImpl = { path in onItsDisk(path, try base.stat(path)) }
        fileSystem.renameExclusiveImpl = { from, to in
            if isOnIt(from) != isOnIt(to) {
                throw NativeError(message: "EXDEV: \(from)", code: "EXDEV", path: from)
            }
            try base.renameExclusive(from, to)
        }
        return fileSystem
    }
}

/// A copy that takes its time: waits until `stop` is stopped (or `timeout` passes), as a copy still running when
/// Stop is pressed does, whatever the machine's load.
func waitUntilStopped(_ stop: StopSignal?, timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while stop?.isStopped == false && Date() < deadline {
        usleep(1000)
    }
}

/// What a test paste did: its review, its result (nil when the review refused it), the questions it asked and
/// its events.
struct PasteRun {
    var report: CopyPasteAnalysisReport
    var result: CopyPasteOperationResult?
    var conflicts: [CopyPasteRuntimeConflict]
    var events: [CopyPasteProgressEvent]
}

/// Collects what a paste sends, from whichever thread sends it.
final class PasteRecorder: Sendable {
    private struct State {
        var events: [CopyPasteProgressEvent] = []
        var conflicts: [CopyPasteRuntimeConflict] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ event: CopyPasteProgressEvent) {
        state.withLock { $0.events.append(event) }
    }

    func asked(_ conflict: CopyPasteRuntimeConflict) {
        state.withLock { $0.conflicts.append(conflict) }
    }

    var events: [CopyPasteProgressEvent] { state.withLock { $0.events } }
    var conflicts: [CopyPasteRuntimeConflict] { state.withLock { $0.conflicts } }
    var result: CopyPasteOperationResult? { events.last { $0.result != nil }?.result }
}

/// `runPaste`: reviews and pastes as the write service would, answering each question with `resolve` ("skip"
/// without one).
func runPaste(
    mode: CopyPasteMode, sources: [String], into destination: String,
    policy: CopyPastePolicy = NativePaste.keepExisting,
    fileSystem: any WriteServiceFileSystem = NativeWriteFileSystem(), signal: StopSignal = StopSignal(),
    writeJournal: (any WriteJournal)? = nil, beforeExecute: (() throws -> Void)? = nil,
    resolve: (@Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?)? = nil,
    onEvent: (@Sendable (CopyPasteProgressEvent) -> Void)? = nil
) async throws -> PasteRun {
    let request = normalizeCopyPasteAnalysisRequest(
        CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination))
    let report = try await WriteService.withRoomForDepth(name: "test review") {
        try buildCopyPasteAnalysisReport(
            analysisId: "analysis-test", request: request, fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100_000, largeBatchByteThreshold: 1 << 40))
    }
    let recorder = PasteRecorder()
    if !report.issues.isEmpty {
        return PasteRun(report: report, result: nil, conflicts: [], events: [])
    }
    let resolvedNodes = try await WriteService.withRoomForDepth(name: "test plan") {
        try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem)
    }
    try beforeExecute?()
    await executeCopyPasteFromAnalysis(
        CopyPasteRun(
            operationId: "op-test", report: report, mode: mode, policy: policy, fileSystem: fileSystem,
            signal: signal, resolvedNodes: resolvedNodes,
            emit: { event in
                recorder.record(event)
                onEvent?(event)
            },
            requestResolution: { conflict in
                recorder.asked(conflict)
                return .immediate(resolve?(conflict) ?? .skip)
            }, writeJournal: writeJournal))
    return PasteRun(report: report, result: recorder.result, conflicts: recorder.conflicts, events: recorder.events)
}

/// `createResolvedOperation`: the review of a paste on a mock disk (thresholds 100 items, 1000 bytes) and its
/// resolution with `policy`.
func createResolvedOperation(
    _ fileSystem: some WriteServiceFileSystem, mode: CopyPasteMode = .copy, sources: [String], into destination: String,
    policy: CopyPastePolicy = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip),
    overrides: [CopyPasteNodeOverride] = []
) throws -> (report: CopyPasteAnalysisReport, resolvedNodes: [ResolvedCopyPasteNode]) {
    let report = try buildCopyPasteAnalysisReport(
        analysisId: "analysis-1",
        request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
        fileSystem: fileSystem,
        thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1000))
    let resolvedNodes = try resolveAnalysisWithPolicy(
        report: report, policy: policy, overrides: overrides, fileSystem: fileSystem)
    return (report, resolvedNodes)
}

/// `executeCopyPasteFromAnalysis` on a reviewed paste, with the test's answers; returns its events.
@discardableResult
func execute(
    _ fileSystem: any WriteServiceFileSystem,
    _ operation: (report: CopyPasteAnalysisReport, resolvedNodes: [ResolvedCopyPasteNode]),
    mode: CopyPasteMode? = nil, operationId: String = "copy-op-1",
    policy: CopyPastePolicy = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip),
    overrides: [CopyPasteNodeOverride] = [], signal: StopSignal = StopSignal(),
    writeJournal: (any WriteJournal)? = nil, recorder: PasteRecorder = PasteRecorder(),
    onEvent: (@Sendable (CopyPasteProgressEvent) -> Void)? = nil,
    requestResolution: (@Sendable (CopyPasteRuntimeConflict) -> RuntimeAnswer)? = nil,
    autoResolve: (@Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?)? = nil
) async -> [CopyPasteProgressEvent] {
    await executeCopyPasteFromAnalysis(
        CopyPasteRun(
            operationId: operationId, report: operation.report, mode: mode ?? operation.report.mode, policy: policy,
            overrides: overrides, fileSystem: fileSystem, now: { Date(timeIntervalSince1970: 1_773_187_200) },
            signal: signal, resolvedNodes: operation.resolvedNodes,
            emit: { event in
                recorder.record(event)
                onEvent?(event)
            },
            requestResolution: { conflict in
                recorder.asked(conflict)
                return requestResolution?(conflict) ?? .immediate(nil)
            }, autoResolve: autoResolve ?? { _ in nil }, writeJournal: writeJournal))
    return recorder.events
}

/// A journal in memory, as the original's tests keep one: each add and remove, in order.
final class MemoryJournal: WriteJournal {
    enum Write: Equatable {
        case add(WriteJournalEntry)
        case remove(String)
    }

    private struct State {
        var entries: [WriteJournalEntry] = []
        var writes: [Write] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Fails the n-th call (1-based) of add or remove when set.
    let failOn: (@Sendable (Write) -> (any Error)?)?

    init(failOn: (@Sendable (Write) -> (any Error)?)? = nil) {
        self.failOn = failOn
    }

    func add(_ entry: WriteJournalEntry) throws {
        if let error = failOn?(.add(entry)) { throw error }
        state.withLock { state in
            state.writes.append(.add(entry))
            if let index = state.entries.firstIndex(where: { $0.id == entry.id }) {
                state.entries[index] = entry
            } else {
                state.entries.append(entry)
            }
        }
    }

    func remove(_ id: String) throws {
        if let error = failOn?(.remove(id)) { throw error }
        state.withLock { state in
            state.writes.append(.remove(id))
            state.entries.removeAll { $0.id == id }
        }
    }

    var entries: [WriteJournalEntry] { state.withLock { $0.entries } }
    var writes: [Write] { state.withLock { $0.writes } }
}

/// Files and folders for real-disk tests, made as Node's fs makes them.
enum Disk {
    static func write(_ path: String, _ content: String) throws {
        let parent = NodePath.dirname(path)
        try makeDirectories(parent)
        guard ExecScenarioFiles.writeFile(path, content) else {
            throw NativeError.errno(errno, syscall: "open", path: path)
        }
    }

    static func makeDirectories(_ path: String) throws {
        var made = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            made += "/" + part
            if Darwin.mkdir(made, 0o777) != 0 && errno != EEXIST {
                throw NativeError.errno(errno, syscall: "mkdir", path: made)
            }
        }
    }

    static func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    static func exists(_ path: String) -> Bool {
        var info = Darwin.stat()
        return Darwin.lstat(path, &info) == 0
    }

    /// The names in a folder, sorted as JavaScript sorts strings; [] when it can't be read.
    static func list(_ path: String) -> [String] {
        ((try? PosixFileSystem().readdir(path)) ?? []).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    static func symlink(_ target: String, _ path: String) throws {
        if Darwin.symlink(target, path) != 0 {
            throw NativeError.errno(errno, syscall: "symlink", path: path)
        }
    }

    static func chmod(_ path: String, _ mode: mode_t) {
        _ = Darwin.chmod(path, mode)
    }

    static func lock(_ path: String) {
        _ = lchflags(path, UInt32(UF_IMMUTABLE))
    }

    static func flags(_ path: String) -> UInt32 {
        (try? NativeFS.getFlags(path)) ?? 0
    }

    static func lstat(_ path: String) -> WriteServiceStats? {
        try? PosixFileSystem().lstat(path)
    }
}

/// `writeFileSync`: opens, truncates and writes in place, so an existing file keeps its inode.
enum ExecScenarioFiles {
    static func writeFile(_ path: String, _ content: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(content.utf8)
        return bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == bytes.count
    }
}
