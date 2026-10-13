// Port of apps/desktop/src/renderer/lib/selectionSize.ts (with FolderSizeEntry from hooks/useFolderSizeCache.ts)
import Foundation

/// What is known of one folder's size (the folder size cache's entry).
public enum FolderSizeEntry: Equatable, Sendable {
    case idle
    case calculating(jobID: String)
    case ready(sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int)
    case error(message: String)
}

/// A selected item, as far as its size is concerned.
public struct SelectionItem: Equatable, Sendable {
    public var path: String
    /// A directory or a bundle: its size is calculated. A link to a folder is not, it counts as
    /// the link itself.
    public var isFolderSizeEligible: Bool

    public init(path: String, isFolderSizeEligible: Bool) {
        self.path = path
        self.isFolderSizeEligible = isFolderSizeEligible
    }
}

/// The size of several selected items, for the Info Row and the Info panel: known only once the size
/// of every one of them is, files from the list and folders from the folder size cache.
public struct SelectionSize: Equatable, Sendable {
    /// The total, when the size of every item is known.
    public var totalBytes: Int64?
    /// The selected folders and packages, whose sizes are calculated.
    public var folderPaths: [String]
    /// The selection's folder sizes as one, for the same controls as one folder's: calculating while
    /// any is, Calculate while any is not known, and the totals once all are. Nil when nothing is
    /// selected that is calculated, or while a file's size is still unknown.
    public var folderSizeEntry: FolderSizeEntry?

    public init(totalBytes: Int64?, folderPaths: [String], folderSizeEntry: FolderSizeEntry?) {
        self.totalBytes = totalBytes
        self.folderPaths = folderPaths
        self.folderSizeEntry = folderSizeEntry
    }
}

public enum SelectionSizing {
    public static func summarize(
        _ items: [SelectionItem],
        fileSize: (String) -> Int64?,
        folderSize: (String) -> FolderSizeEntry
    ) -> SelectionSize {
        var folderPaths: [String] = []
        var folderEntries: [FolderSizeEntry] = []
        var fileBytes: Int64 = 0
        var filesKnown = true
        var fileCount = 0
        for item in items {
            if item.isFolderSizeEligible {
                folderPaths.append(item.path)
                folderEntries.append(folderSize(item.path))
                continue
            }
            fileCount += 1
            if let size = fileSize(item.path) {
                fileBytes += size
            } else {
                filesKnown = false
            }
        }

        var sizeBytes = fileBytes
        // Files have no size on disk in the list: it is shown only for folders alone.
        var diskBytes: Int64? = fileCount == 0 ? 0 : nil
        var innerFileCount = 0
        var innerFolderCount = 0
        var foldersKnown = true
        var anyCalculating = false
        for folder in folderEntries {
            if case .calculating = folder {
                anyCalculating = true
            }
            guard case .ready(let size, let disk, let files, let folders) = folder else {
                foldersKnown = false
                continue
            }
            sizeBytes += size
            if let current = diskBytes {
                diskBytes = current + disk
            }
            innerFileCount += files
            innerFolderCount += folders
        }

        let totalBytes: Int64? = filesKnown && foldersKnown ? sizeBytes : nil
        var folderSizeEntry: FolderSizeEntry?
        if !folderPaths.isEmpty {
            if anyCalculating {
                folderSizeEntry = .calculating(jobID: "")
            } else if !foldersKnown {
                folderSizeEntry = .idle
            } else if let totalBytes {
                // Everything selected and everything inside it, as Finder counts a selection.
                folderSizeEntry = .ready(
                    sizeBytes: totalBytes,
                    diskBytes: diskBytes ?? totalBytes,
                    fileCount: fileCount + innerFileCount,
                    folderCount: folderPaths.count + innerFolderCount)
            }
        }
        return SelectionSize(totalBytes: totalBytes, folderPaths: folderPaths, folderSizeEntry: folderSizeEntry)
    }
}
