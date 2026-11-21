import FTFileSystem
import FTFoundation
import Foundation

/// What the selected aliases lead to, so the menus offer for an alias of a folder what opens a folder (Open in New
/// Tab), and for an alias of a file what they offer for a link to a file (Open in Viewer, Edit in).
///
/// A folder's listing says which of its files are aliases; search results don't, so a selected result is looked at
/// too. They are looked up again each time the selection changes, away from the main thread and without mounting
/// anything, so an alias whose original moved or went is seen as it is now; what was known stays until the new answer.
@MainActor
final class AliasOriginals {
    static let shared = AliasOriginals()

    private enum Known { case notAlias, folder, file, missing }

    /// By each path's bytes, as two names that differ only in how an accent is spelled are two items.
    private var known: [DiskPath: Known] = [:]
    private var asked: Set<DiskPath> = []

    /// At most this many of a selection are looked up: past it, the menus show what they show for any alias.
    static let lookupLimit = 20

    /// The kind the command rules take `entry` as: an alias as a link to a folder or to a file once it is known which.
    func commandKind(_ entry: DirectoryEntry) -> FTFoundation.EntryKind {
        let kind = FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other
        guard kind == .alias || kind == .aliasDirectory || kind == .file else { return kind }
        switch known[DiskPath(entry.path)] {
        case .folder: return .aliasDirectory
        case .file: return .symlinkFile
        case .missing: return .alias
        case .notAlias, nil: return kind
        }
    }

    /// Looks up the aliases among `entries`: those the listing marked, and, with `filesMayBeAliases` (search results),
    /// any file. `changed` is called once when what is known of any of them changed.
    func lookUp(_ entries: [DirectoryEntry], filesMayBeAliases: Bool, changed: @escaping @MainActor () -> Void) {
        let paths = entries.prefix(Self.lookupLimit).compactMap { entry -> String? in
            guard entry.kind.isAlias || (filesMayBeAliases && entry.kind == .file) else { return nil }
            return asked.contains(DiskPath(entry.path)) ? nil : entry.path
        }
        guard !paths.isEmpty else { return }
        asked.formUnion(paths.map(DiskPath.init))
        Task {
            let found = await BlockingWork.run {
                paths.map { path -> (String, Known) in
                    guard Links.isFinderAlias(path) else { return (path, .notAlias) }
                    guard let original = Links.originalItem(of: path) else { return (path, .missing) }
                    return (path, original.isFolder ? .folder : .file)
                }
            }
            var anyChanged = false
            for (path, kind) in found.map({ (DiskPath($0.0), $0.1) }) {
                asked.remove(path)
                if (known[path] ?? .notAlias) != kind { anyChanged = true }
                known[path] = kind == .notAlias ? nil : kind
            }
            if anyChanged { changed() }
        }
    }
}
