// Port of the optional questions of WriteServiceFileSystem (packages/core/src/fs/writeServiceTypes.ts), and of
// isPackageFolder, resolveDuplicateName, detectCaseSensitivity and isPathAvailable (packages/core/src/fs/copyPasteNames.ts),
// which ask them of the disk
import Darwin
import FTFoundation
import Foundation

/// What the review asks of the disk: the reading calls, and the questions a disk may not answer. Each question's
/// default is the original's answer when its file system leaves the call out.
public protocol AnalysisFileSystem: IdentityFileSystem {
    /// Whether the volume holding `path` tells names apart by letter case (`pathconf(_PC_CASE_SENSITIVE)`), or
    /// nil when it doesn't say. Without it, an existing name is looked up with its case swapped.
    func isCaseSensitive(_ path: String) throws -> Bool?
    /// Whether macOS shows the folder as one item, a package (`NSURLIsPackageKey`); nil when it can't tell.
    /// Without it, the folder's extension decides.
    func isPackage(_ path: String) throws -> Bool?
    /// Whether a "._name" file is AppleDouble metadata that macOS reads as "name"'s own attributes. Without it,
    /// every "._name" file is an ordinary item.
    func isAppleDouble(_ path: String) -> Bool
}

extension AnalysisFileSystem {
    public func isCaseSensitive(_ path: String) throws -> Bool? { nil }
    public func isPackage(_ path: String) throws -> Bool? { nil }
    public func isAppleDouble(_ path: String) -> Bool { false }
}

/// The disk itself, asked as the app's native file system asks it.
extension PosixFileSystem: AnalysisFileSystem {
    public func isCaseSensitive(_ path: String) throws -> Bool? {
        try NativeFS.isCaseSensitive(path)
    }

    /// `nativeIsPackage(path)`: `NSURLIsPackageKey`, true for folders Finder shows as one item, by their type or
    /// by the folder's own package bit; nil when it can't be told (the item is gone, say).
    public func isPackage(_ path: String) throws -> Bool? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey])
        return values?.isPackage
    }

    public func isAppleDouble(_ path: String) -> Bool {
        NativeFS.isAppleDoubleOnItsVolume(path)
    }
}

/// `isPackageFolder`: whether a folder is a package, which is pasted whole: never merged with another, as mixing
/// two versions of an app or a document breaks it. macOS is asked when it can be; otherwise the extension tells.
public func isPackageFolder(_ fileSystem: some AnalysisFileSystem, _ path: String) -> Bool {
    CopyPasteNames.isPackage(folderAt: path) { (try? fileSystem.isPackage($0)) ?? nil }
}

/// `isPathAvailable`: free only when lstat says nothing is there (ENOENT); any other failure counts as taken, so
/// a name is never reused by mistake.
public func isPathTaken(_ fileSystem: some IdentityFileSystem, _ path: String) -> Bool {
    do {
        _ = try fileSystem.lstat(path)
        return true
    } catch {
        return errorCode(error) != "ENOENT"
    }
}

/// `resolveDuplicateName` on a disk: Finder-style "name copy.ext", "name copy 2.ext", … that is free on disk and
/// not already claimed by another item of the same paste (`reserved`, keyed by `NameKeys.exactDestinationKey`).
public func resolveDuplicateName(
    _ sourceName: String, in directory: String, _ fileSystem: some IdentityFileSystem,
    reserved: Set<NameKeys.Exact>? = nil, options: CopyPasteNames.Options = .init()
) throws -> String {
    try CopyPasteNames.resolveDuplicateName(
        sourceName: sourceName, in: directory, reserved: reserved, options: options,
        exists: { isPathTaken(fileSystem, $0) })
}

/// `resolveKeepBothDestinationPath` on a disk: the Keep Both path for a source pasted at `destinationPath`.
public func resolveKeepBothDestinationPath(
    sourcePath: String, destinationPath: String, _ fileSystem: some AnalysisFileSystem,
    options: CopyPasteNames.Options = .init()
) throws -> String {
    try CopyPasteNames.resolveKeepBothDestinationPath(
        sourcePath: sourcePath, destinationPath: destinationPath, options: options,
        isPackageFolder: { (try? fileSystem.isPackage($0)) ?? nil }, exists: { isPathTaken(fileSystem, $0) })
}

/// `detectCaseSensitivity` on a disk: whether the volume holding `directory` tells names apart by letter case.
public func detectCaseSensitivity(_ fileSystem: some AnalysisFileSystem, in directory: String) -> Bool {
    CopyPasteNames.detectCaseSensitivity(CaseProbe(fileSystem: fileSystem), in: directory)
}

/// What the case probe sees of the disk. A lookup without ids (or devices) gives values that no probe takes for
/// an id, as `fileIdOf` gives nothing for them.
private struct CaseProbe<FileSystem: AnalysisFileSystem>: CopyPasteNames.CaseProbingFileSystem {
    let fileSystem: FileSystem

    func isCaseSensitive(_ directory: String) -> Bool? {
        (try? fileSystem.isCaseSensitive(directory)) ?? nil
    }

    func entries(_ directory: String) -> [String] {
        (try? fileSystem.readdir(directory)) ?? []
    }

    func lookup(_ path: String) -> CopyPasteNames.Lookup {
        do {
            let stats = try fileSystem.lstat(path)
            return .found(dev: stats.dev.map { UInt64(bitPattern: $0) } ?? .max, ino: stats.ino ?? .max)
        } catch {
            return errorCode(error) == "ENOENT" ? .missing : .failed
        }
    }
}
