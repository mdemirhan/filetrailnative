// Port of the paste cases of packages/core/src/fs/writeService.test.ts
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// Port of createMockFileSystem (writeService.test.ts): items by path, with no ids or dates; writes add and remove
/// paths, and copies can be replaced.
private final class PathSetWriteFileSystem: WriteServiceFileSystem, @unchecked Sendable {
    private struct State {
        var existingPaths: Set<String>
        var directoryPaths: Set<String>
    }

    private let state: OSAllocatedUnfairLock<State>
    private let fileSizes: [String: Int64]
    private let childrenByDirectory: [String: [String]]
    var copyFileImpl: ((String, String, StopSignal?) throws -> Void)?
    var chmodImpl: ((String, UInt32) throws -> Void)?

    init(existingPaths: [String], directoryPaths: [String] = [], fileSizes: [String: Int64] = [:]) {
        state = OSAllocatedUnfairLock(
            initialState: State(existingPaths: Set(existingPaths), directoryPaths: Set(directoryPaths)))
        self.fileSizes = fileSizes
        var children: [String: [String]] = [:]
        for path in existingPaths {
            let segments = path.split(separator: "/").map(String.init)
            for index in 1..<max(segments.count, 1) {
                let parent = "/" + segments[0..<index].joined(separator: "/")
                if !(children[parent] ?? []).contains(segments[index]) {
                    children[parent, default: []].append(segments[index])
                }
            }
        }
        childrenByDirectory = children
    }

    private func stats(_ path: String) throws -> WriteServiceStats {
        let (exists, directory) = state.withLock { ($0.existingPaths.contains(path), $0.directoryPaths.contains(path)) }
        guard exists else { throw codedError("ENOENT", "ENOENT: \(path)") }
        return WriteServiceStats(
            type: directory ? .directory : .file, size: fileSizes[path] ?? 0, mode: directory ? 0o755 : 0o644)
    }

    func lstat(_ path: String) throws -> WriteServiceStats { try stats(path) }
    func stat(_ path: String) throws -> WriteServiceStats { try stats(path) }
    func realpath(_ path: String) throws -> String { path }
    func readdir(_ path: String) throws -> [String] { (childrenByDirectory[path] ?? []).sorted() }
    func readlink(_ path: String) throws -> String { throw codedError("EINVAL", "EINVAL: \(path)") }

    var chmod: ((String, UInt32) throws -> Void)? { { [self] in try chmodImpl?($0, $1) } }

    func mkdir(_ path: String) throws {
        state.withLock {
            $0.existingPaths.insert(path)
            $0.directoryPaths.insert(path)
        }
    }

    func rm(_ path: String, recursive: Bool, force: Bool) throws {
        state.withLock {
            $0.existingPaths.remove(path)
            $0.directoryPaths.remove(path)
        }
    }

    func rmdir(_ path: String) throws {
        try rm(path, recursive: false, force: false)
    }

    func renameExclusive(_ from: String, _ to: String) throws {
        try state.withLock { state in
            if state.existingPaths.contains(to) {
                throw codedError("EEXIST", "EEXIST: \(to)")
            }
            func moved(_ paths: Set<String>) -> Set<String> {
                Set(paths.map { $0 == from || $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0 })
            }
            state.existingPaths = moved(state.existingPaths)
            state.directoryPaths = moved(state.directoryPaths)
        }
    }

    func getFlags(_ path: String) throws -> UInt32 { 0 }
    func setFlags(_ path: String, _ flags: UInt32) throws {}

    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        if let copyFileImpl {
            return try copyFileImpl(source, destination, stop)
        }
        _ = state.withLock { $0.existingPaths.insert(destination) }
    }
}

/// Collects a service's events from any thread.
private final class Events: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [CopyPasteProgressEvent]())

    func record(_ event: CopyPasteProgressEvent) { state.withLock { $0.append(event) } }
    var all: [CopyPasteProgressEvent] { state.withLock { $0 } }

    func terminal(_ operationId: String) -> CopyPasteProgressEvent? {
        let ends: Set<CopyPasteOperationStatus> = [.completed, .failed, .cancelled, .partial]
        return all.last { $0.operationId == operationId && ends.contains($0.status) }
    }

    func waitForTerminal(_ operationId: String) async -> CopyPasteProgressEvent? {
        _ = await waitFor { self.terminal(operationId) != nil }
        return terminal(operationId)
    }
}

/// Analyzes a paste, then starts it with the default policy, as the window does.
private func startPaste(_ service: WriteService, _ mode: CopyPasteMode, _ sources: [String], into destination: String)
    async throws -> CopyPasteOperationHandle
{
    let analysisId = try service.startCopyPasteAnalysis(
        CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination)
    ).analysisId
    #expect(await waitFor { try service.getCopyPasteAnalysisUpdate(analysisId).done })
    return try service.startCopyPaste(CopyPasteExecutionRequest(analysisId: analysisId, policy: .defaultCopyPaste))
}

/// A service on the disk itself, its events collected.
private func nativeService(_ operationId: String) -> (WriteService, Events) {
    let service = WriteService(.init(fileSystem: NativeWriteFileSystem(), createOperationId: { operationId }))
    let events = Events()
    _ = service.subscribe { events.record($0) }
    return (service, events)
}

struct WriteServicePasteTests {
    // T-4ca2bce9 F-273 F-336
    @Test func copiesSymlinksAsLinksDuringExecution() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/actual.txt", "hello")
            try Disk.makeDirectories(root.path + "/target")
            try Disk.symlink("actual.txt", root.path + "/source/alias.txt")
            let (service, events) = nativeService("symlink-op")

            _ = try await startPaste(service, .copy, [root.path + "/source/alias.txt"], into: root.path + "/target")

            _ = await events.waitForTerminal("symlink-op")
            #expect(try PosixFileSystem().readlink(root.path + "/target/alias.txt") == "actual.txt")
        }
    }

    // T-37ddd66b F-461
    @Test func executesCutByCopyingFirstAndRemovingTheSourceAfterSuccess() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/notes.txt", "hello")
            try Disk.makeDirectories(root.path + "/target")
            let (service, events) = nativeService("cut-op")

            _ = try await startPaste(service, .cut, [root.path + "/source/notes.txt"], into: root.path + "/target")

            let terminal = await events.waitForTerminal("cut-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.read(root.path + "/target/notes.txt") == "hello")
            #expect(!Disk.exists(root.path + "/source/notes.txt"))
        }
    }

    // T-170d73ea F-466
    @Test func removesNestedSourceDirectoriesAfterASuccessfulCutOnTheRealFilesystem() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/nested/deeper/alpha.txt", "alpha")
            try Disk.write(root.path + "/source/beta.txt", "beta")
            try Disk.makeDirectories(root.path + "/target")
            let (service, events) = nativeService("cut-tree-op")

            _ = try await startPaste(service, .cut, [root.path + "/source"], into: root.path + "/target")

            let terminal = await events.waitForTerminal("cut-tree-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.read(root.path + "/target/source/nested/deeper/alpha.txt") == "alpha")
            #expect(Disk.read(root.path + "/target/source/beta.txt") == "beta")
            #expect(!Disk.exists(root.path + "/source"))
        }
    }

    // T-430afe8c F-257 F-280
    @Test func supportsCooperativeCancellationAndReportsPartialCompletion() async throws {
        let fileSystem = PathSetWriteFileSystem(
            existingPaths: ["/target", "/source/one.txt", "/source/two.txt"], directoryPaths: ["/target"],
            fileSizes: ["/source/one.txt": 5, "/source/two.txt": 7])
        fileSystem.copyFileImpl = { source, _, stop in
            if source.hasSuffix("one.txt") {
                return
            }
            waitUntilStopped(stop)
            try stop?.throwIfStopped()
        }
        let service = WriteService(.init(fileSystem: fileSystem, createOperationId: { "cancel-op" }))
        let events = Events()
        _ = service.subscribe { events.record($0) }

        _ = try await startPaste(service, .copy, ["/source/one.txt", "/source/two.txt"], into: "/target")

        #expect(await waitFor { events.all.contains { $0.operationId == "cancel-op" && $0.completedItemCount == 1 } })
        #expect(service.cancelOperation("cancel-op"))

        let terminal = await events.waitForTerminal("cancel-op")
        #expect(terminal?.status == .partial)
        #expect(terminal?.result?.summary.completedItemCount == 1)
    }

    // T-6adcf405 F-242
    @Test func rejectsStartingASecondWriteOperationWhileOneIsAlreadyActive() async throws {
        let fileSystem = PathSetWriteFileSystem(
            existingPaths: ["/target", "/source/one.txt", "/source/two.txt"], directoryPaths: ["/target"],
            fileSizes: ["/source/one.txt": 5, "/source/two.txt": 7])
        // The first paste is still copying when the second is asked for.
        fileSystem.copyFileImpl = { source, _, stop in
            if source.hasSuffix("one.txt") {
                waitUntilStopped(stop)
                try stop?.throwIfStopped()
            }
        }
        let index = OSAllocatedUnfairLock(initialState: 0)
        let service = WriteService(
            .init(
                fileSystem: fileSystem,
                createOperationId: {
                    index.withLock { value in
                        value += 1
                        return "op-\(value)"
                    }
                }))

        _ = try await startPaste(service, .copy, ["/source/one.txt"], into: "/target")

        await #expect(throws: (any Error).self) {
            _ = try await startPaste(service, .copy, ["/source/two.txt"], into: "/target")
        }
        do {
            _ = try await startPaste(service, .copy, ["/source/two.txt"], into: "/target")
        } catch {
            #expect(errorMessage(error) == WriteServiceMessages.writeOperationBusy)
        }
        service.cancelOperation("op-1")
    }

    // T-1dd3b541 F-447
    @Test func copiesNestedDirectoryTreesOnTheRealFilesystem() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/nested/alpha.txt", "alpha")
            try Disk.write(root.path + "/source/beta.txt", "beta")
            try Disk.makeDirectories(root.path + "/target")
            let (service, events) = nativeService("tree-op")

            _ = try await startPaste(service, .copy, [root.path + "/source"], into: root.path + "/target")

            let terminal = await events.waitForTerminal("tree-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.read(root.path + "/target/source/nested/alpha.txt") == "alpha")
            #expect(Disk.read(root.path + "/target/source/beta.txt") == "beta")
            #expect(Set(Disk.list(root.path + "/target/source")).isSuperset(of: ["nested", "beta.txt"]))
        }
    }

    // T-8227d576 F-452
    @Test func preservesFilePermissionsIncludingExecuteBitsWhenCopying() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/bin/run", "#!/bin/sh\necho hi")
            Disk.chmod(root.path + "/source/bin/run", 0o755)
            try Disk.write(root.path + "/source/data.txt", "hello")
            try Disk.makeDirectories(root.path + "/target")
            let (service, events) = nativeService("perms-op")

            _ = try await startPaste(service, .copy, [root.path + "/source"], into: root.path + "/target")

            let terminal = await events.waitForTerminal("perms-op")
            #expect(terminal?.result?.status == .completed)
            #expect((Disk.lstat(root.path + "/target/source/bin/run")?.mode ?? 0) & 0o777 == 0o755)
            #expect((Disk.lstat(root.path + "/target/source/data.txt")?.mode ?? 0) & 0o777 == 0o644)
        }
    }

    // T-250a2e62 F-271 F-452
    @Test func treatsUnsupportedChmodAsNonFatalDuringCopy() async throws {
        let fileSystem = PathSetWriteFileSystem(
            existingPaths: ["/target", "/source", "/source/run.sh"], directoryPaths: ["/target", "/source"],
            fileSizes: ["/source/run.sh": 11])
        fileSystem.chmodImpl = { _, _ in throw codedError("ENOTSUP", "Operation not supported") }
        let service = WriteService(.init(fileSystem: fileSystem, createOperationId: { "chmod-unsupported-op" }))
        let events = Events()
        _ = service.subscribe { events.record($0) }

        _ = try await startPaste(service, .copy, ["/source"], into: "/target")

        let terminal = await events.waitForTerminal("chmod-unsupported-op")
        #expect(terminal?.result?.status == .completed)
    }

    // The original's case guards Electron's fs, which takes .asar archives for folders: the app's own file system
    // sees one as the file it is.
    // T-3e4b85d5 F-447
    @Test func copiesAsarFilesAsRegularFilesNotAsVirtualDirectories() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/source/app.asar", "asar-archive-content")
            try Disk.makeDirectories(root.path + "/target")
            let (service, events) = nativeService("asar-copy-op")

            _ = try await startPaste(service, .copy, [root.path + "/source"], into: root.path + "/target")

            let terminal = await events.waitForTerminal("asar-copy-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.lstat(root.path + "/target/source/app.asar")?.type == .file)
            #expect(Disk.read(root.path + "/target/source/app.asar") == "asar-archive-content")
        }
    }

    // T-12a18238 F-447
    @Test func duplicatesAFileWhenCopyPasteTargetsTheSameDirectory() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/workspace/notes.txt", "hello")
            let (service, events) = nativeService("duplicate-file-op")

            _ = try await startPaste(
                service, .copy, [root.path + "/workspace/notes.txt"], into: root.path + "/workspace")

            let terminal = await events.waitForTerminal("duplicate-file-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.read(root.path + "/workspace/notes copy.txt") == "hello")
        }
    }

    // T-e7e30fd5 F-447
    @Test func duplicatesADirectoryTreeWhenCopyPasteTargetsTheSameDirectory() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/workspace/source/nested/alpha.txt", "alpha")
            let (service, events) = nativeService("duplicate-dir-op")

            _ = try await startPaste(service, .copy, [root.path + "/workspace/source"], into: root.path + "/workspace")

            let terminal = await events.waitForTerminal("duplicate-dir-op")
            #expect(terminal?.result?.status == .completed)
            #expect(Disk.read(root.path + "/workspace/source copy/nested/alpha.txt") == "alpha")
        }
    }
}
