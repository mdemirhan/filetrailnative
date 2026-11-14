import FTFileSystem
import FTFoundation
import Foundation

/// How converting one picture went, on the disk.
private enum ConvertedImage: Sendable {
    case made(String)
    case failed(String)
}

extension WriteCoordinator {
    /// What makes a picture's new bytes: ImageIO's, unless a test gives its own.
    public typealias ImageEncoder = @Sendable (String, ImageConversionOptions) throws -> Data

    /// Makes a converted copy of each picture beside it, under its name with the new format's extension, numbered
    /// when that is taken; nothing is replaced and the originals are left as they are. One picture that can't be
    /// converted doesn't keep the others from it; only stopping stops the rest. One Undo moves the new files to the
    /// Trash.
    @discardableResult
    public func convertImages(
        paths requested: [String], options: ImageConversionOptions, window: any WriteOperationWindow,
        encode: @escaping ImageEncoder = { path, options in try ImageConverter.convert(path, options) }
    ) async throws -> WriteOperationHandle {
        let paths = requested.map(NodePath.resolve)
        guard !paths.isEmpty else { throw WriteCoordinatorError("There are no images to convert.") }
        var folders: [String] = []
        for folder in paths.map(NodePath.dirname) where !folders.contains(folder) {
            try WriteGuards.assertNotIntoTrash(folder, verb: "made in", homePath: homePath)
            folders.append(folder)
        }
        // The folder the new files are selected in once they are made, when they are all in one.
        let targetPath = folders.count == 1 ? folders[0] : nil
        return try await prepareWithReservedSlot {
        } then: { _, reservation in
            let fileSystem = self.fileSystem
            // As for a copy: undoing it would mean deleting them, on a disk without a Trash.
            let undoable: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return folders.allSatisfy { self.canBeTrashed(in: $0) }
            }
            return try queueLocalWriteOperation(action: .convertImages, window: window, reservation: reservation) {
                local in
                await Self.executeConvertImages(
                    paths, options, targetPath: targetPath, local, fileSystem, encode: encode, undoable: undoable)
            }
        }
    }

    static func executeConvertImages(
        _ paths: [String], _ options: ImageConversionOptions, targetPath: String?, _ operation: LocalWriteOperation,
        _ fileSystem: any LocalWriteFileSystem, encode: @escaping ImageEncoder, undoable: @MainActor () -> Bool
    ) async {
        let startedAt = Date()
        var items: [WriteOperationItem] = []
        var completedItemCount = 0
        var cancelled = false
        // One unit per new file, so one that changed since doesn't keep the others from the Trash.
        var units: [UndoUnit] = []
        for (index, path) in paths.enumerated() {
            if operation.signal.isStopped {
                cancelled = true
                items += LocalWriteResults.notStartedItems(Array(paths[index...]))
                break
            }
            operation.emit(
                operation.progress(
                    .running, completedItemCount: completedItemCount, totalItemCount: paths.count,
                    currentSourcePath: path))
            // On a queue of its own, never on Swift's cooperative threads: ImageIO's AV1 encoder (AVIF) does its work on
            // those, so holding one while it waits could leave it none.
            let outcome = await LocalOperations.onDisk { convertOne(path, options, fileSystem, encode) }
            switch outcome {
            case .failed(let message):
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: nil, status: .failed, error: message))
            case .made(let destinationPath):
                let created = await LocalOperations.onDisk { () -> UndoStep in
                    .created(
                        path: destinationPath, id: readItemId({ try fileSystem.lstat($0) }, destinationPath),
                        stamp: readItemStamp(StampReader(fileSystem), destinationPath))
                }
                units.append(UndoUnit(steps: [created]))
                completedItemCount += 1
                items.append(
                    WriteOperationItem(sourcePath: path, destinationPath: destinationPath, status: .completed))
            }
        }
        let failedItemCount = items.filter { $0.status == .failed }.count
        let status = LocalWriteResults.terminalStatus(
            cancelled: cancelled, completedItemCount: completedItemCount, failedItemCount: failedItemCount)
        let error: String? =
            cancelled
            ? LocalWriteResults.stoppedMessage(completedItemCount, ConvertImagesText.stoppedDone)
            : failedItemCount > 0 ? items.first { $0.status == .failed }?.error : nil
        let result = LocalWriteResults.result(
            operationId: operation.operationId, action: .convertImages, targetPath: targetPath, startedAt: startedAt,
            finishedAt: Date(), totalItemCount: paths.count, completedItemCount: completedItemCount, items: items,
            status: status, error: error)
        let undoLog: UndoLog? =
            units.isEmpty ? nil : undoable() ? .undoable(units: units) : .notUndoable(reason: .noTrash)
        operation.emit(
            operation.progress(
                status, completedItemCount: completedItemCount, totalItemCount: paths.count, result: result),
            undoLog: undoLog)
    }

    /// One picture converted, on the disk: filled under a hidden name, then given the first free one of its own.
    private nonisolated static func convertOne(
        _ path: String, _ options: ImageConversionOptions, _ fileSystem: any LocalWriteFileSystem,
        _ encode: ImageEncoder
    ) -> ConvertedImage {
        let data: Data
        do {
            data = try encode(path, options)
        } catch let failure as ImageConverter.Failure {
            return .failed(message(failure, options.format))
        } catch {
            return .failed(LocalOperations.describeWriteError(error, missing: NodePath.basename(path)))
        }
        let folder = NodePath.dirname(path)
        let name = ImageConversion.newName(for: NodePath.basename(path), format: options.format)
        let partial = partialFilePath(for: NodePath.join(folder, name))
        var destinationPath = NodePath.join(folder, name)
        do {
            if LocalOperations.lstatOrNull(fileSystem, destinationPath) != nil {
                destinationPath = try nextFreeFilePath(folder, name, fileSystem)
            }
            try fileSystem.writeNewFile(partial, data)
        } catch {
            return .failed(LocalOperations.describeWriteError(error, missing: NodePath.basename(folder)))
        }
        do {
            try fileSystem.renameExclusive(partial, destinationPath)
        } catch {
            try? fileSystem.rm(partial, recursive: false, force: true)
            return .failed(
                LocalOperations.describeWriteError(
                    error, missing: NodePath.basename(folder), existing: NodePath.basename(destinationPath)))
        }
        return .made(destinationPath)
    }

    private nonisolated static func message(_ failure: ImageConverter.Failure, _ format: ImageFormat) -> String {
        switch failure {
        case .unreadable(let reason): reason
        case .notAnImage: ConvertImagesText.notAnImage
        case .tooSmall(let size): ConvertImagesText.tooSmall(size)
        case .notWritten: ConvertImagesText.notWritten(format)
        }
    }
}
