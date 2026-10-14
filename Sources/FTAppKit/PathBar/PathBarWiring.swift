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

    /// The path bar shows the folder on screen (the search results' path is P5-07's).
    func updatePathBar() {
        content.contentShell.pathBarRow.path = searchRootPath == nil ? folder.path : (searchRootPath ?? folder.path)
    }
}
