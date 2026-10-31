// Port of openLocationSheet, the places read on open, forgetPlace and goToPath (apps/desktop/src/renderer/App.tsx
// 2119-2205, 2977-2998), submitLocationPath (hooks/useExplorerNavigationController.ts 2049-2066) and openMoveDialog,
// submitMoveDialog and browseForDirectoryPath (hooks/useExplorerActions.ts 3570-3647): the Go To and Move To boxes of a
// tab
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// How a Go To ended (`submitLocationPath`'s answer).
enum GoToOutcome: Equatable {
    case opened
    /// The folder couldn't be read: the read's message.
    case failed(String)
    /// Another navigation replaced it.
    case superseded
}

extension MainWindowController {
    /// Where the opened folders are kept (the app's state store); a window in a test names its own.
    static var visitStore: @MainActor () -> AppStateStore? = { (NSApp.delegate as? AppDelegate)?.store }
    /// The timers of the boxes' completion requests; a test moves them by hand.
    static var dialogTimers: any TimerScheduling = TaskTimerScheduler()
    /// The system's folder picker (`system:pickDirectory`), from a path; nil when it was cancelled.
    static var pickDirectory: @MainActor (_ defaultPath: String?, _ window: NSWindow?) async -> String? = {
        path, window in
        let choice = await SystemPickers.pickDirectory(defaultPath: path, window: window)
        return choice.canceled ? nil : choice.path
    }

    // MARK: Dialogs up

    /// The dialogs drawn over the tab's window, the one in front last.
    var dialogs: [DialogScrim] { DialogScrim.all(in: window) }
    /// The Go To or Move To box, while it is up.
    var goToBox: GoToFolderBox? { dialogs.lazy.compactMap { $0.panel as? GoToFolderBox }.first }
    /// The alert in front, while one is up.
    var frontAlert: AlertCard? { dialogs.last?.panel as? AlertCard }
    /// Whether a box or an alert is up: the tab's commands and keys wait (B-DLG-064, B-NAV-112).
    var isDialogOpen: Bool { !dialogs.isEmpty }

    // MARK: Go To

    /// `openLocationSheet` (⌘K, ⇧⌘G, the toolbar's Go To): the box opens empty over the explorer, and no pane has the
    /// keyboard while it is up.
    func openLocationSheet() {
        guard let window, !isDialogOpen else { return }
        AppMenuPresenter.shared.close()
        let box = presentGoToBox(.goTo, in: window)
        box.onSubmit = { [weak self, weak box] path in
            guard let self, let box else { return }
            self.submitGoTo(path, box: box)
        }
    }

    /// Shows a Go To box over `window`, its places read and ranked as of now (B-DLG-016).
    @discardableResult
    func presentGoToBox(_ options: GoToBoxOptions, in window: NSWindow) -> GoToFolderBox {
        let box = GoToFolderBox(
            places: placesNow(), options: options, timers: Self.dialogTimers,
            requestCompletions: { [weak self] input in await self?.pathCompletions(input) })
        let scrim = DialogScrim(panel: box, placement: .sheet)
        scrim.onScrimPress = { [weak box] in box?.onClose() }
        scrim.onWindowClose = { [weak box] in box?.closed() }
        box.onClose = { [weak box, weak scrim] in
            box?.closed()
            scrim?.dismiss()
        }
        box.onForget = { path in Self.visitStore()?.forgetVisitedFolder(path) }
        scrim.present(in: window)
        box.opened(in: window)
        return box
    }

    /// The `places` memo: the opened folders and the favorites, ranked as of now.
    private func placesNow() -> [Place] {
        Places.build(
            visitedFolders: Self.visitStore()?.folders() ?? [], favoritePaths: preferences.favorites.map(\.path),
            currentPath: shownFolderPath, homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            now: AppClock.now.timeIntervalSince1970 * 1000)
    }

    /// `requestPathSuggestions`: the typed text trimmed, `~` expanded, hidden folders only when the tab shows them,
    /// 12 at most.
    func pathCompletions(_ input: String) async -> [GoToCompletion]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = PathCompletionRequests.requestPath(input, homePath: home)
        let hidden = includeHidden
        guard
            let answer = try? await services.directoryService.pathSuggestions(
                inputPath: path, includeHidden: hidden, limit: PathCompletionRequests.limit)
        else { return nil }
        return answer.suggestions.map { GoToCompletion(path: $0.path, name: $0.name) }
    }

    /// `goToPath` with `submitLocationPath`: trimmed, `~` expanded, a push counted as a Go To visit. The box closes
    /// only if the folder opened; otherwise it shows the read's message. An opened folder chosen from the list that is
    /// gone is forgotten; one that only couldn't be opened is kept (B-DLG-039).
    func submitGoTo(_ path: String, box: GoToFolderBox) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = PathText2.expandHome(GoToBoxState.trim(path), homePath: home)
        let wasVisited = box.state.places.contains { $0.isVisited && $0.path == path }
        box.setError(nil)
        box.setSubmitting(true)
        Task { @MainActor [weak self, weak box] in
            guard let self else { return }
            let outcome = await self.goToFolder(URL(fileURLWithPath: expanded))
            guard let box else { return }
            box.setSubmitting(false)
            switch outcome {
            case .opened:
                box.onClose()
                return
            case .failed(let message): box.setError(message)
            case .superseded: break
            }
            guard wasVisited else { return }
            let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
            // `forgetPlace`: the folder leaves the list of the box, still up with the error (B-DLG-038).
            guard !exists else { return }
            Self.visitStore()?.forgetVisitedFolder(path)
            if self.goToBox === box { box.setPlaces(self.placesNow()) }
        }
    }

    /// Opens `url` for Go To: the folder on screen stays when it can't be read.
    func goToFolder(_ url: URL) async -> GoToOutcome {
        var failure: String?
        let timing = await navigate(to: url, history: .push, goToFailure: { failure = $0 })
        if timing != nil { return .opened }
        return failure.map(GoToOutcome.failed) ?? .superseded
    }

    // MARK: Move To

    /// `openMoveDialog`: the Move To box, on the folder shown now. The busy notice was said before it opens.
    func openMoveDialog(_ paths: [String], _ actions: WindowWriteActions) {
        guard !paths.isEmpty, let window, !isDialogOpen else { return }
        AppMenuPresenter.shared.close()
        let current = shownFolderPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let options = GoToBoxOptions.moveTo(currentPath: current) { [weak window] path in
            // `browseForDirectoryPath`: the picker starts at the path, `~` expanded.
            await Self.pickDirectory(path.isEmpty ? nil : PathText2.expandHome(path, homePath: home), window)
        }
        let box = presentGoToBox(options, in: window)
        box.onSubmit = { [weak self, weak box] destination in
            guard let self, let box else { return }
            self.submitMoveDialog(destination, paths: paths, actions: actions, box: box)
        }
    }

    /// `submitMoveDialog`: queued or sent to the review, the box closes; cancelled, it stays as it was; refused, it
    /// says why under the field.
    func submitMoveDialog(_ destination: String, paths: [String], actions: WindowWriteActions, box: GoToFolderBox) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let resolved = PathText2.expandHome(GoToBoxState.trim(destination), homePath: home)
        box.setError(nil)
        box.setSubmitting(true)
        Task { @MainActor [weak self, weak box] in
            guard let self else { return }
            let outcome = await self.startMoveFromDialog(paths, to: resolved, actions)
            guard let box else { return }
            switch outcome {
            case .queued, .review:
                box.onClose()
                actions.reviewIfAsked(outcome, action: .moveTo)
            case .cancelled:
                box.setSubmitting(false)
            case .blocked(let message), .error(let message):
                box.setSubmitting(false)
                box.setError(message)
            }
        }
    }

    /// `startMoveToDestination` with `validateDestinationBeforeAnalyze`, from the Move To box.
    private func startMoveFromDialog(_ paths: [String], to destination: String, _ actions: WindowWriteActions) async
        -> CopyLikeOutcome
    {
        if paths.isEmpty || destination.isEmpty { return .blocked(message: "Choose a destination folder.") }
        if actions.session.isWriteLocked { return .blocked(message: WriteDialogs.busyMessage) }
        if let refusal = await TabDragDrop.destinationRefusal(destination, services.directoryService) {
            return .blocked(message: refusal)
        }
        return await actions.copyLike(
            mode: .cut, sources: paths, destination: destination, action: .moveTo, initiator: .moveDialog,
            reportsRefusals: false)
    }

    // MARK: Alerts

    /// A notice with one OK over the tab's window (`showModalNotice`), its detail list under the message.
    func showNotice(title: String, message: String, detailLines: [String] = []) {
        guard let window else { return }
        InWindowAlerts.notice(title: title, message: message, detailLines: detailLines, in: window)
    }

    /// Finder's question about a name that hides the item, word for word. Cancel is the default.
    func askDotName() async -> Bool {
        guard let window else { return false }
        return await InWindowAlerts.confirm(LocalWriteRules.dotNameQuestion, in: window)
    }
}
