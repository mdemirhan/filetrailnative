// Navigation, new tabs, folder children and path suggestions
import FTFileSystem
import FTFoundation
import Foundation

extension MainWindowController {
    /// Connects the path bar to the window: what it opens, and the folders and suggestions it asks for.
    func wirePathBar(_ pane: BrowserPane) {
        let bar = pane.content.contentShell.pathBarRow
        bar.startupDiskName = { [weak self] in self?.services.startupDisk.name ?? VolumePaths.defaultStartupDiskName }
        bar.namesChanged()
        bar.path = pane.folderPath
        // The bar acts in its own pane, which it makes the active one.
        let navigate: @MainActor (String) -> Void = { [weak self, weak pane] path in
            guard let self, let pane else { return }
            self.activate(pane)
            // In search results the bar ends with the selected result, which opens as a double-click would open it.
            if let result = self.selectedSearchResult, result.path == path {
                self.open([result])
                return
            }
            self.navigate(to: path, target: .push)
        }
        bar.onNavigate = navigate
        // A path typed in the bar comes from no listing: "~" is the home folder, a path that doesn't start at the top
        // starts where the app was started, and the folder is gone to by its path as the disk spells it.
        bar.onTyped = { [weak bar] typed in
            var path = PathText2.expandHome(typed, homePath: bar?.editor.homePath ?? "")
            if !path.hasPrefix("/") { path = NodePath.join(FileManager.default.currentDirectoryPath, path) }
            Task { navigate(await Self.typedPlaceAsOnDisk(path)) }
        }
        bar.onOpenInNewTab = { [weak self] path in
            guard let self else { return }
            self.navigate(to: path, target: .newTab)
        }
        bar.onFocusContent = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane)
            self.perform(.focusContentPane)
        }
        bar.requestFolders = { [weak self, weak pane] path in
            guard let self, let pane else { return [] }
            let hidden = pane.includeHidden
            let children = try await self.services.directoryService.treeChildren(path: path, includeHidden: hidden)
            return children.children.map { PathbarFolder(path: $0.path, name: $0.name) }
        }
        bar.requestSuggestions = { [weak self, weak pane] input in
            guard let self, let pane else { return [] }
            let hidden = pane.includeHidden
            let answer = try? await self.services.directoryService.pathSuggestions(
                inputPath: input, includeHidden: hidden, limit: InfoMetrics.suggestionLimit)
            return (answer?.suggestions ?? []).map { PathSuggestionRow(path: $0.path, name: $0.name) }
        }
        bar.editor.homePath = DiskPath.home.string
    }

    /// The selected search result while results show: the selection's lead, or else the first selected.
    private var selectedSearchResult: DirectoryEntry? {
        guard searchRootPath != nil else { return nil }
        let selected = content.selectedEntries
        let lead = content.selection.leadPath.map(DiskPath.init)
        return selected.first { DiskPath($0.path) == lead } ?? selected.first
    }

    /// The active pane's path bar (`BrowserPane.updatePathBar`).
    func updatePathBar() {
        activePane.updatePathBar()
    }
}
