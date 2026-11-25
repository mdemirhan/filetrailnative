import Foundation

public enum AutoFolderSize {
    /// How long a folder stays selected, or in the Info panel, before it is measured. The
    /// Info panel and the Info Row both wait it out: they share one measurement.
    public static let delayMilliseconds = 500.0

    /// The folder the Info panel or the Info Row measures by itself: the item Get Info put in the panel (`showInfoPath`,
    /// once the panel shows it as `infoItem`), else the one item selected, else, with nothing selected, the folder on
    /// screen (`shownFolder`), however it was opened. It is measured when it is the home folder, a folder in it, or a
    /// bundle anywhere. The row shows the selection, never Get Info's item; with both open, the panel's item is measured.
    public static func path(
        infoPanelOpen: Bool, infoRowOpen: Bool = false, selectedPaths: [String],
        selected: (path: String, kind: EntryKind)?, shownFolder: (path: String, kind: EntryKind)? = nil,
        showInfoPath: String? = nil, infoItem: (path: String, kind: EntryKind)? = nil, homePath: String
    ) -> String? {
        guard infoPanelOpen || infoRowOpen else { return nil }
        let item: (path: String, kind: EntryKind)?
        if infoPanelOpen, let showInfoPath {
            item = infoItem?.path == showInfoPath ? infoItem : nil
        } else if selectedPaths.isEmpty {
            item = shownFolder
        } else {
            item = selectedPaths.count == 1 && selected?.path == selectedPaths[0] ? selected : nil
        }
        guard let item, isMeasured(item, homePath: homePath) else { return nil }
        return item.path
    }

    /// The folders the Info panel or the Info Row measures by themselves, one after another: what `path` names, or,
    /// with several items selected and nothing from Get Info in the panel, those of `selection` (the selected items
    /// shown, in the list's order) measured by the same rules, the home folder, folders in it and bundles anywhere.
    public static func paths(
        infoPanelOpen: Bool, infoRowOpen: Bool = false, selectedPaths: [String],
        selected: (path: String, kind: EntryKind)?, selection: [(path: String, kind: EntryKind)] = [],
        shownFolder: (path: String, kind: EntryKind)? = nil, showInfoPath: String? = nil,
        infoItem: (path: String, kind: EntryKind)? = nil, homePath: String
    ) -> [String] {
        guard infoPanelOpen || infoRowOpen else { return [] }
        if selectedPaths.count > 1, !(infoPanelOpen && showInfoPath != nil) {
            return selection.filter { isMeasured($0, homePath: homePath) }.map(\.path)
        }
        let one = path(
            infoPanelOpen: infoPanelOpen, infoRowOpen: infoRowOpen, selectedPaths: selectedPaths, selected: selected,
            shownFolder: shownFolder, showInfoPath: showInfoPath, infoItem: infoItem, homePath: homePath)
        return one.map { [$0] } ?? []
    }

    /// Whether the app measures `item` by itself: a bundle anywhere, else a folder that is the home folder or in it.
    private static func isMeasured(_ item: (path: String, kind: EntryKind), homePath: String) -> Bool {
        guard item.kind.isFolderSizeEligible else { return false }
        if item.kind == .bundle { return true }
        var home = homePath
        while home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty else { return false }
        return item.path == home || item.path.hasPrefix(home + "/")
    }
}
