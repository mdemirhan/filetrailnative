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
        bar.path = pane.folder.path
        // The bar acts in its own pane, which it makes the active one.
        bar.onNavigate = { [weak self, weak pane] path in
            guard let self, let pane else { return }
            self.activate(pane)
            // In search results the bar ends with the selected result, which opens as a double-click would open it.
            if let result = self.selectedSearchResult, result.path == path {
                self.open([result])
                return
            }
            self.navigate(to: URL(fileURLWithPath: path), target: .push)
        }
        bar.onOpenInNewTab = { [weak self] path in
            guard let self else { return }
            self.navigate(to: URL(fileURLWithPath: path), target: .newTab)
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
        bar.editor.homePath = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// The selected search result while results show: the selection's lead, or else the first selected.
    private var selectedSearchResult: DirectoryEntry? {
        guard searchRootPath != nil else { return nil }
        let selected = content.selectedEntries
        return selected.first { $0.path == content.selection.leadPath } ?? selected.first
    }

    /// The active pane's path bar (`BrowserPane.updatePathBar`).
    func updatePathBar() {
        activePane.updatePathBar()
    }
}
