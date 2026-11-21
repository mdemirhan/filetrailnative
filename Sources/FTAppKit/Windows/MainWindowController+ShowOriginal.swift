import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// Show Original: the original of a symbolic link or an alias is selected in its folder and scrolled to, and the
    /// list has the keyboard. Its folder opens in the pane, as a step of Back, unless it is the folder on screen.
    func showOriginal(of linkPath: String) {
        AppMenuPresenter.shared.close()
        Task {
            guard let original = await BlockingWork.run({ Links.original(of: linkPath) }) else {
                return showOriginalMissing(linkPath)
            }
            revealOriginal(original)
        }
    }

    /// `original` selected in its folder: Show Original, and the Original row of Show Info. The original is spelled as
    /// its disk spells it (`Links.original`, `realpath`), which is how the folder on screen and its rows are known.
    func revealOriginal(_ original: String) {
        // A disk has no folder to be selected in: it opens.
        if original == "/" || VolumePaths.isVolumeRootPath(original) {
            go(to: original)
            return
        }
        let parent = DiskPath(original).parent.string
        let onScreen =
            searchRootPath == nil && !activePane.folderLetGo && activePane.viewer == nil
            && samePath(parent, folderPath)
        guard !onScreen else {
            selectOriginal(original)
            return
        }
        Task {
            guard await navigate(to: parent, history: .push) else { return }
            selectOriginal(original)
        }
    }

    private func selectOriginal(_ original: String) {
        // The row spelled exactly so; one whose name is spelled so only when no row's path is (the folder listed under
        // another spelling of its path).
        let name = NodePath.basename(original)
        guard
            let row = content.listedEntry(at: original)
                ?? content.listed.first(where: { $0.name.utf16.elementsEqual(name.utf16) })
        else {
            // Hidden while hidden items aren't shown: what is selected couldn't be seen.
            notifications?.toasts.push(
                .info, title: "The Original Is Hidden",
                message: "\u{201C}\(name)\u{201D} is hidden. View \u{25B8} Hidden Files shows it.")
            content.focusList()
            return
        }
        // A filter that leaves it out gives the whole list back, so it can be seen.
        if !content.entryPaths.contains(where: { samePath($0, row.path) }) { content.clearFilter() }
        content.select(paths: [row.path])
        content.focusList()
    }
}
