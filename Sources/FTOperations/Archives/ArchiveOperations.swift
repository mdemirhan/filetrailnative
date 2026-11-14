import FTFileSystem
import FTFoundation
import Foundation

// Compress and Extract: write operations of their own, in the write slot, with a progress card, Stop and Undo. What
// they make is made out of sight first (in the disk's folder for items being saved, or a hidden folder next to where
// it goes) and then given its place with a rename that never replaces anything.

extension WriteCoordinator {
    /// Extract: takes each of `archivePaths` apart into `destinationFolder`, or, nil, into the archive's own folder.
    /// An archive holding one item at its top gives that item; one holding several gives a folder named after the
    /// archive ("Photos.zip" → "Photos"). A name already taken gets the next number. Undo moves what was made to
    /// the Trash. An archive that fails doesn't stop the others.
    @discardableResult
    public func extractArchives(
        _ archivePaths: [String], into destinationFolder: String? = nil, window: any WriteOperationWindow
    ) async throws -> WriteOperationHandle {
        guard !archivePaths.isEmpty else { throw WriteCoordinatorError("Choose an archive to extract.") }
        for folder in Set(archivePaths.map { destinationFolder ?? NodePath.dirname($0) }) {
            try WriteGuards.assertNotIntoTrash(folder, verb: "extracted into", homePath: homePath)
        }
        let fileSystem = self.fileSystem
        let undoable: @MainActor (String) -> Bool = { [weak self] folder in
            self?.canBeTrashed(in: folder) ?? false
        }
        return try queueLocalWriteOperation(action: .extract, window: window) { operation in
            await Self.executeExtract(
                archivePaths, into: destinationFolder, operation, fileSystem, undoable: undoable)
        }
    }

    /// Compress: one zip of `paths`, items of one folder, next to them, as Finder's Compress makes it
    /// ("Photos.zip", "Archive.zip" for several; the next number when taken). Undo moves it to the Trash.
    @discardableResult
    public func compress(_ paths: [String], window: any WriteOperationWindow) async throws -> WriteOperationHandle {
        guard let first = paths.first else { throw WriteCoordinatorError("Choose the items to compress.") }
        let folder = NodePath.dirname(first)
        guard paths.allSatisfy({ NodePath.dirname($0).utf16.elementsEqual(folder.utf16) }) else {
            throw WriteCoordinatorError("Compress items from one folder at a time.")
        }
        try WriteGuards.assertNotIntoTrash(folder, verb: "compressed in", homePath: homePath)
        let fileSystem = self.fileSystem
        let undoable: @MainActor () -> Bool = { [weak self] in self?.canBeTrashed(in: folder) ?? false }
        return try queueLocalWriteOperation(action: .compress, window: window) { operation in
            await Self.executeCompress(paths, in: folder, operation, fileSystem, undoable: undoable)
        }
    }

    // MARK: Extract

    static func executeExtract(
        _ archivePaths: [String], into destinationFolder: String?, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, undoable: @MainActor (String) -> Bool
    ) async {
        let startedAt = Date()
        let sizes = await LocalOperations.onDisk { archivePaths.map { (try? fileSystem.lstat($0))?.size ?? 0 } }
        let totalBytes = sizes.reduce(0, +)
        var doneBytes: Int64 = 0
        var items: [WriteOperationItem] = []
        var steps: [UndoStep] = []
        var stopped = false
        for (index, archivePath) in archivePaths.enumerated() {
            if operation.signal.isStopped {
                stopped = true
                items += LocalWriteResults.notStartedItems(Array(archivePaths[index...]))
                break
            }
            let folder = destinationFolder ?? NodePath.dirname(archivePath)
            let before = doneBytes
            do {
                let placed = try await runWithProgress(
                    operation, completedItemCount: index, totalItemCount: archivePaths.count,
                    totalBytes: totalBytes, currentSourcePath: archivePath, currentDestinationPath: folder,
                    doneBefore: before
                ) { control in
                    try extractOne(archivePath, into: folder, fileSystem, control)
                }
                items.append(
                    WriteOperationItem(
                        sourcePath: archivePath, destinationPath: placed.path, status: .completed,
                        error: placed.skipped > 0 ? skippedNote(placed.skipped) : nil, note: placed.skipped > 0))
                if undoable(folder) {
                    steps.append(await createdStep(placed.path, fileSystem))
                }
            } catch {
                if error is StopError || operation.signal.isStopped {
                    stopped = true
                    items.append(
                        WriteOperationItem(
                            sourcePath: archivePath, destinationPath: nil, status: .cancelled,
                            error: "Operation cancelled."))
                    items += LocalWriteResults.notStartedItems(Array(archivePaths[(index + 1)...]))
                    break
                }
                items.append(
                    WriteOperationItem(
                        sourcePath: archivePath, destinationPath: nil, status: .failed,
                        error: describeArchiveError(error)))
            }
            doneBytes = before + sizes[index]
        }
        let completed = items.filter { $0.status == .completed }.count
        let failed = items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: stopped, completedItemCount: completed, failedItemCount: failed)
        let error: String? =
            switch status {
            case .cancelled: LocalWriteResults.stoppedMessage(completed, "extracted")
            case .partial where stopped: LocalWriteResults.stoppedMessage(completed, "extracted")
            case .failed where archivePaths.count == 1: items.first?.error
            default: nil
            }
        emitEnd(
            operation, startedAt: startedAt, targetPath: destinationFolder ?? archivePaths.first.map(NodePath.dirname),
            items: items, totalItemCount: archivePaths.count, status: status, error: error,
            undoLog: endUndoLog(steps, anyMade: completed > 0))
    }

    /// One archive taken apart in a hidden folder and its result put in `folder`: its path, and how many of its
    /// items were left out.
    nonisolated static func extractOne(
        _ archivePath: String, into folder: String, _ fileSystem: any LocalWriteFileSystem,
        _ control: NativeArchive.Control
    ) throws -> (path: String, skipped: Int64) {
        let archiveName = NodePath.basename(archivePath)
        let kind = ArchiveNames.kind(of: archiveName) ?? .items
        let rawName = kind == .singleFile ? ArchiveNames.extractedName(archiveName) : nil
        let staging = try Staging(near: folder, fileSystem)
        defer { staging.remove(fileSystem) }
        try NativeArchive.extract(
            archivePath, into: staging.work, rawName: rawName, quarantine: true, control: control)
        let children = try fileSystem.readdir(staging.work)
        let placed: String
        if children.count == 1, let only = children.first {
            let source = NodePath.join(staging.work, only)
            let isFolder = (try? fileSystem.lstat(source))?.type == .directory
            placed = try place(source, in: folder, named: only, isFolder: isFolder, fileSystem)
        } else {
            placed = try place(
                staging.work, in: folder, named: ArchiveNames.extractedName(archiveName), isFolder: true, fileSystem)
        }
        return (placed, control.skipped)
    }

    // MARK: Compress

    static func executeCompress(
        _ paths: [String], in folder: String, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, undoable: @MainActor () -> Bool
    ) async {
        let startedAt = Date()
        let names = paths.map(NodePath.basename)
        let zipName = ArchiveNames.zipName(for: names)
        do {
            let placed = try await runWithProgress(
                operation, completedItemCount: 0, totalItemCount: paths.count, totalBytes: nil,
                currentSourcePath: paths.count == 1 ? paths[0] : nil,
                currentDestinationPath: NodePath.join(folder, zipName), doneBefore: 0
            ) { control in
                let staging = try Staging(near: folder, fileSystem)
                defer { staging.remove(fileSystem) }
                let partial = NodePath.join(staging.work, zipName)
                try NativeArchive.compressZip(names, in: folder, to: partial, control: control)
                let placed = try place(partial, in: folder, named: zipName, isFolder: false, fileSystem)
                return (path: placed, skipped: control.skipped)
            }
            let item = WriteOperationItem(
                sourcePath: nil, destinationPath: placed.path, status: .completed,
                error: placed.skipped > 0 ? skippedNote(placed.skipped) : nil, note: placed.skipped > 0)
            let steps = undoable() ? [await createdStep(placed.path, fileSystem)] : []
            emitEnd(
                operation, startedAt: startedAt, targetPath: folder, items: [item], totalItemCount: 1,
                status: .completed, error: nil, undoLog: endUndoLog(steps, anyMade: true))
        } catch {
            let cancelled = error is StopError || operation.signal.isStopped
            let message = cancelled ? "Operation cancelled." : describeArchiveError(error)
            emitEnd(
                operation, startedAt: startedAt, targetPath: folder,
                items: [
                    WriteOperationItem(
                        sourcePath: nil, destinationPath: NodePath.join(folder, zipName),
                        status: cancelled ? .cancelled : .failed, error: message)
                ], totalItemCount: 1, status: cancelled ? .cancelled : .failed, error: message, undoLog: nil)
        }
    }

    // MARK: Helpers

    /// Runs `work` on the disk's queue with a fresh control, Stop wired to it, and the card told how far it has come
    /// every quarter of a second. No progress is sent once this returns.
    static func runWithProgress<T: Sendable>(
        _ operation: LocalWriteOperation, completedItemCount: Int, totalItemCount: Int, totalBytes: Int64?,
        currentSourcePath: String?, currentDestinationPath: String?, doneBefore: Int64,
        _ work: @escaping @Sendable (NativeArchive.Control) throws -> T
    ) async throws -> T {
        try operation.signal.throwIfStopped()
        let control = NativeArchive.Control()
        let token = operation.signal.onStop { control.stop() }
        defer { operation.signal.removeHandler(token) }
        func send() {
            operation.emit(
                WriteOperationEvent(
                    operationId: operation.operationId, action: operation.action, status: .running,
                    completedItemCount: completedItemCount, totalItemCount: totalItemCount,
                    completedByteCount: doneBefore + control.done, totalBytes: totalBytes ?? control.total,
                    currentSourcePath: currentSourcePath, currentDestinationPath: currentDestinationPath))
        }
        send()
        let ticks = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: StoppableCopy.progressInterval)
                if Task.isCancelled { break }
                send()
            }
        }
        defer { ticks.cancel() }
        // A Stop pressed just as it starts would be missed by the handler registered after it.
        if operation.signal.isStopped { control.stop() }
        let outcome = await LocalOperations.onDisk { Result { try work(control) } }
        ticks.cancel()
        await ticks.value
        return try outcome.get()
    }

    /// Puts `source` in `folder` as `name`, or the next free name when it is taken, never replacing anything.
    nonisolated static func place(
        _ source: String, in folder: String, named name: String, isFolder: Bool,
        _ fileSystem: any LocalWriteFileSystem
    ) throws -> String {
        var destination = NodePath.join(folder, name)
        // Something may take the free name between the look and the rename: the next one is tried then.
        for _ in 0..<5 {
            if LocalOperations.lstatOrNull(fileSystem, destination) != nil {
                destination =
                    isFolder
                    ? try nextFreeFolderPath(folder, name, fileSystem) : try nextFreeFilePath(folder, name, fileSystem)
            }
            do {
                try fileSystem.renameExclusive(source, destination)
                return destination
            } catch {
                guard errorCode(error) == .errno(EEXIST) else { throw error }
            }
        }
        throw WriteCoordinatorError("An item named \u{201C}\(name)\u{201D} already exists.")
    }

    static func createdStep(_ path: String, _ fileSystem: any LocalWriteFileSystem) async -> UndoStep {
        await LocalOperations.onDisk { () -> UndoStep in
            .created(
                path: path, id: readItemId({ try fileSystem.lstat($0) }, path),
                stamp: readItemStamp(StampReader(fileSystem), path))
        }
    }

    static func endUndoLog(_ steps: [UndoStep], anyMade: Bool) -> UndoLog? {
        guard anyMade else { return nil }
        // As for a copy: undoing it would mean deleting it, on a disk without a Trash.
        return steps.isEmpty ? .notUndoable(reason: .noTrash) : .undoable(units: [UndoUnit(steps: steps)])
    }

    static func emitEnd(
        _ operation: LocalWriteOperation, startedAt: Date, targetPath: String?, items: [WriteOperationItem],
        totalItemCount: Int, status: WriteOperationStatus, error: String?, undoLog: UndoLog?
    ) {
        let completed = items.filter { $0.status == .completed }.count
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: operation.action, targetPath: targetPath,
            startedAt: startedAt, finishedAt: Date(), totalItemCount: totalItemCount, completedItemCount: completed,
            items: items, status: status, error: error)
        operation.emit(
            operation.progress(
                status, completedItemCount: completed, totalItemCount: totalItemCount, result: result),
            undoLog: undoLog)
    }

    nonisolated static func skippedNote(_ count: Int64) -> String {
        count == 1
            ? "1 item was left out: its name reached outside the folder, it was already there, or it can\u{2019}t be kept here."
            : "\(count) items were left out: their names reached outside the folder, they were already there, or they can\u{2019}t be kept here."
    }

    nonisolated static func describeArchiveError(_ error: any Error) -> String {
        if let archive = error as? ArchiveError { return archive.message }
        return LocalOperations.describeWriteError(error)
    }
}

/// A hidden folder on the destination's disk that an archive is taken apart or a zip made in: the disk's own folder
/// for items being saved (`NSItemReplacementDirectory`, which macOS empties), or, where it has none on that disk, a
/// hidden folder in the destination.
struct Staging {
    /// What is removed afterwards, whatever is left in it.
    let root: String
    /// Where the work is done, inside `root`.
    let work: String

    init(near folder: String, _ fileSystem: any LocalWriteFileSystem) throws {
        let folderDisk = (try fileSystem.stat(folder)).dev
        if let url = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: folder),
            create: true)
        {
            let work = NodePath.join(url.path, "Extracted")
            let sameDisk = folderDisk != nil && (try? fileSystem.stat(url.path))?.dev == folderDisk
            if sameDisk, (try? fileSystem.mkdir(work)) != nil {
                root = url.path
                self.work = work
                return
            }
            try? fileSystem.rm(url.path, recursive: true, force: true)
        }
        root = NodePath.join(folder, ".\(UUID().uuidString).filetrail-partial")
        work = root
        try fileSystem.mkdir(root)
    }

    func remove(_ fileSystem: any LocalWriteFileSystem) {
        try? fileSystem.rm(root, recursive: true, force: true)
    }
}
