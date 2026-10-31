// Port of what apps/desktop/src/renderer/App.tsx hands the content pane's path bar (:2395-2432): navigation, new tabs,
// folder children and path suggestions
import FTFileSystem
import FTFoundation
import Foundation

extension MainWindowController {
    /// Connects the path bar to the window: what it opens, and the folders and suggestions it asks for.
    func wirePathBar() {
        let bar = content.contentShell.pathBarRow
        bar.path = folder.path
        bar.onNavigate = { [weak self] path in
            guard let self else { return }
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
        bar.onFocusContent = { [weak self] in self?.perform(.focusContentPane) }
        bar.requestFolders = { [weak self] path in
            guard let self else { return [] }
            let hidden = self.viewState.includeHidden
            let children = try await self.services.directoryService.treeChildren(path: path, includeHidden: hidden)
            return children.children.map { PathbarFolder(path: $0.path, name: $0.name) }
        }
        bar.requestSuggestions = { [weak self] input in
            guard let self else { return [] }
            let hidden = self.viewState.includeHidden
            let answer = try? await self.services.directoryService.pathSuggestions(
                inputPath: input, includeHidden: hidden, limit: InfoMetrics.suggestionLimit)
            return (answer?.suggestions ?? []).map { PathSuggestionRow(path: $0.path, name: $0.name) }
        }
        bar.editor.homePath = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `selectedEntry` while results show: the selection's lead, or else the first selected.
    private var selectedSearchResult: DirectoryEntry? {
        guard searchRootPath != nil else { return nil }
        let selected = content.selectedEntries
        return selected.first { $0.path == content.selection.leadPath } ?? selected.first
    }

    /// The path bar shows the folder on screen; in search mode where the one selected result is, as Finder's does, or
    /// else the folder the search runs from (`pathbarPath`, B-SRCH-111).
    func updatePathBar() {
        let bar = content.contentShell.pathBarRow
        guard let searchRootPath else {
            bar.path = shownFolderPath
            return
        }
        let selected = content.selectedEntries
        bar.path = content.selection.paths.count == 1 && selected.count == 1 ? selected[0].path : searchRootPath
    }
}
