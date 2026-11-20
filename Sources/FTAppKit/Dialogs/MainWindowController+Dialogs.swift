// The Go To, Move To and Extract To boxes of a tab
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// How a Go To ended.
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
    /// The system's folder picker, from a path; nil when it was cancelled.
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
    /// Whether a box or an alert is up: the tab's commands and keys wait.
    var isDialogOpen: Bool { !dialogs.isEmpty }

    // MARK: Command palette

    /// The command palette, while it is up.
    var commandPaletteBox: CommandPaletteBox? { dialogs.lazy.compactMap { $0.panel as? CommandPaletteBox }.first }

    /// Shows the command palette over the tab with `entries`; `run` is told the command chosen once the box has gone
    /// and the keyboard is back where it was. Nil when a dialog is up already.
    @discardableResult
    func presentCommandPalette(
        _ entries: [CommandPaletteEntry], recent: [String], ownKeys: [String],
        run: @escaping (CommandPaletteEntry) -> Void
    ) -> CommandPaletteBox? {
        guard let window, !isDialogOpen else { return nil }
        AppMenuPresenter.shared.close()
        let box = CommandPaletteBox(entries: entries, recent: recent, ownKeys: ownKeys)
        let scrim = DialogScrim(panel: box, placement: .sheet)
        scrim.onScrimPress = { [weak box] in box?.onClose() }
        box.onClose = { [weak scrim] in scrim?.dismiss() }
        box.onRun = { [weak scrim] entry in
            scrim?.dismiss()
            run(entry)
        }
        scrim.present(in: window)
        return box
    }

    // MARK: Paths that were typed

    /// The folder to go to at a path that was typed, by its path as the disk spells it (`DiskPath.asOnDisk`), which is
    /// how the folder on screen and the rows spell theirs: every link followed, "." and ".." and a slash at the end
    /// resolved, and each name with its accents and letter case as its folder holds it. One that isn't there keeps
    /// the spelling given, and shows its error by it; so does a path that isn't absolute. The disk is asked off the
    /// main thread.
    nonisolated static func typedPlaceAsOnDisk(_ path: String) async -> String {
        guard path.hasPrefix("/") else { return path }
        return await BlockingWork.run { access(path, F_OK) == 0 ? DiskPath(path).asOnDisk().string : path }
    }

    /// The folder items are sent to at a path that was typed or chosen in a panel, by its path as the disk spells
    /// it, which is how a write names what it made and how the folder on screen is known. One that isn't there yet,
    /// and may be made, is the folder it would be in as the disk spells it, with its name as typed. The disk is asked
    /// off the main thread.
    nonisolated static func typedDestinationAsOnDisk(_ path: String) async -> String {
        guard path.hasPrefix("/") else { return path }
        return await BlockingWork.run { DiskPath(path).asOnDisk().string }
    }

    // MARK: Go To

    /// `openLocationSheet` (⌘K, ⇧⌘G, the toolbar's Go To): the box opens empty over the explorer, and no pane has the
    /// keyboard while it is up.
    func openLocationSheet() {
        guard let window, !isDialogOpen else { return }
        AppMenuPresenter.shared.close()
        let box = presentGoToBox(.goTo(currentPath: shownFolderPath), in: window)
        box.onSubmit = { [weak self, weak box] path in
            guard let self, let box else { return }
            self.submitGoTo(path, box: box)
        }
    }

    /// Shows a Go To box over `window`, its places read and ranked as of now.
    @discardableResult
    func presentGoToBox(_ options: GoToBoxOptions, in window: NSWindow) -> GoToFolderBox {
        let box = GoToFolderBox(
            places: placesNow(options.purpose), options: options, timers: Self.dialogTimers,
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

    /// The `places` memo: the opened folders and the favorites, ranked as of now. A box choosing a folder for items
    /// also has the folders chosen before, and the other pane's folder first.
    private func placesNow(_ purpose: GoToPurpose) -> [Place] {
        let choosing = purpose == .chooseFolder
        return Places.build(
            visitedFolders: Self.visitStore()?.folders() ?? [], favoritePaths: preferences.favorites.map(\.path),
            currentPath: shownFolderPath, homePath: DiskPath.home.string,
            now: AppClock.now.timeIntervalSince1970 * 1000, startupDiskName: services.startupDisk.name,
            destinationFolders: choosing ? Self.visitStore()?.destinations() ?? [] : [],
            otherPanePath: choosing ? otherPane.flatMap(otherPaneDestination) : nil)
    }

    /// The typed text trimmed, `~` expanded, a path from "./" or "../" taken from the folder on screen, hidden folders
    /// only when the tab shows them, 12 at most.
    func pathCompletions(_ input: String) async -> [GoToCompletion]? {
        let home = DiskPath.home.string
        let path = PathCompletionRequests.requestPath(input, homePath: home, currentPath: shownFolderPath)
        let hidden = includeHidden
        guard
            let answer = try? await services.directoryService.pathSuggestions(
                inputPath: path, includeHidden: hidden, limit: InfoMetrics.suggestionLimit)
        else { return nil }
        return answer.suggestions.map { GoToCompletion(path: $0.path, name: $0.name) }
    }

    /// Opens the typed path: trimmed, `~` expanded, "./" and "../" from the folder on screen, then spelled as the disk
    /// spells it (`typedPlaceAsOnDisk`), a push counted as a Go To visit. The box closes only if the folder opened;
    /// otherwise it shows the read's message. An opened folder chosen from the list that is gone is forgotten; one
    /// that only couldn't be opened is kept.
    func submitGoTo(_ path: String, box: GoToFolderBox) {
        let home = DiskPath.home.string
        let expanded = GoToBoxState.folderPath(path, homePath: home, currentPath: box.options.currentPath)
        let wasVisited = box.state.places.contains { $0.isVisited && samePath($0.path, path) }
        box.setError(nil)
        box.setSubmitting(true)
        Task { @MainActor [weak self, weak box] in
            guard let self else { return }
            let outcome = await self.goToFolder(await Self.typedPlaceAsOnDisk(expanded))
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
            let exists = await BlockingWork.run { FileManager.default.fileExists(atPath: path) }
            // `forgetPlace`: the folder leaves the list of the box, still up with the error.
            guard !exists else { return }
            Self.visitStore()?.forgetVisitedFolder(path)
            if self.goToBox === box { box.setPlaces(self.placesNow(box.options.purpose)) }
        }
    }

    /// Opens the folder at `path` for Go To: the folder on screen stays when it can't be read.
    func goToFolder(_ path: String) async -> GoToOutcome {
        var failure: String?
        if await navigate(to: path, history: .push, goToFailure: { failure = $0 }) { return .opened }
        return failure.map(GoToOutcome.failed) ?? .superseded
    }

    // MARK: Move To and Extract To

    /// `openMoveDialog`: the Move To box, on the folder shown now. The busy notice was said before it opens.
    func openMoveDialog(_ paths: [String], _ actions: WindowWriteActions) {
        guard !paths.isEmpty, let window, !isDialogOpen else { return }
        AppMenuPresenter.shared.close()
        let options = GoToBoxOptions.moveTo(paths, currentPath: shownFolderPath, browse: browseFolder(window))
        let box = presentGoToBox(options, in: window)
        box.onSubmit = { [weak self, weak box] destination in
            guard let self, let box else { return }
            self.submitChosenFolder(
                destination, box: box, actions: actions, verb: "Move",
                refusal: { Self.alreadyThere(paths, in: $0) ?? Self.insideItself(paths, folder: $0) },
                start: { [weak self] folder in
                    await self?.startMove(paths, to: folder, actions) ?? .cancelled
                },
                started: { actions.reviewIfAsked($0, action: .moveTo) })
        }
    }

    /// The Extract To box, on the folder shown now: the archives are taken apart into the folder chosen. The busy
    /// notice was said before it opens.
    func openExtractToDialog(_ paths: [String], _ actions: WindowWriteActions) {
        guard !paths.isEmpty, let window, !isDialogOpen else { return }
        AppMenuPresenter.shared.close()
        let options = GoToBoxOptions.extractTo(paths, currentPath: shownFolderPath, browse: browseFolder(window))
        let box = presentGoToBox(options, in: window)
        box.onSubmit = { [weak self, weak box] destination in
            guard let self, let box else { return }
            self.submitChosenFolder(
                destination, box: box, actions: actions, verb: "Extract",
                start: { folder in await actions.extract(paths, into: folder, reportsRefusals: false) })
        }
    }

    /// Choose…: the system's folder picker, starting at the path typed.
    private func browseFolder(_ window: NSWindow) -> @MainActor (String) async -> String? {
        let current = shownFolderPath
        let home = DiskPath.home.string
        return { [weak window] path in
            await Self.pickDirectory(
                path.isEmpty ? nil : GoToBoxState.folderPath(path, homePath: home, currentPath: current), window)
        }
    }

    /// The items go into the folder typed in a Move To or Extract To box, by its path as the disk spells it
    /// (`typedDestinationAsOnDisk`): the write is sent there and the folder remembered by that spelling. Queued or sent
    /// to the review, the box closes and the folder is remembered as a destination; cancelled, it stays as it was;
    /// refused, it says why under the field. A folder that doesn't exist yet, in one that does, is offered to be made
    /// first: the box's button says "Create and Move" (or Extract), and the next submit makes it.
    func submitChosenFolder(
        _ typed: String, box: GoToFolderBox, actions: WindowWriteActions, verb: String,
        refusal: @escaping @MainActor (String) -> String? = { _ in nil },
        start: @escaping @MainActor (String) async -> CopyLikeOutcome,
        started: @escaping @MainActor (CopyLikeOutcome) -> Void = { _ in }
    ) {
        let home = DiskPath.home.string
        let asTyped = GoToBoxState.folderPath(typed, homePath: home, currentPath: box.options.currentPath)
        let creates = box.state.createsFolder
        let submitted = box.state.text
        box.setError(nil)
        box.setSubmitting(true)
        Task { @MainActor [weak self, weak box] in
            guard let self else { return }
            let folder = await Self.typedDestinationAsOnDisk(asTyped)
            let outcome = await self.sendToChosenFolder(
                folder, creates: creates, actions: actions, verb: verb, refusal: refusal, start: start,
                offer: { [weak box] notice in box?.offerToCreate(notice: notice, for: submitted) })
            guard let box else { return }
            switch outcome {
            case .queued, .review:
                Self.visitStore()?.recordDestination(folder)
                box.onClose()
                started(outcome)
            case .cancelled:
                box.setSubmitting(false)
            case .blocked(let message), .error(let message):
                box.setSubmitting(false)
                box.setError(message)
            }
        }
    }

    /// The folder checked, made when that was offered, and the items started into it.
    private func sendToChosenFolder(
        _ folder: String, creates: Bool, actions: WindowWriteActions, verb: String,
        refusal: @MainActor (String) -> String?, start: @MainActor (String) async -> CopyLikeOutcome,
        offer: @MainActor (String) -> Void
    ) async -> CopyLikeOutcome {
        if !folder.hasPrefix("/") { return .blocked(message: "Choose a destination folder.") }
        if actions.session.isWriteLocked { return .blocked(message: WriteDialogs.busyMessage) }
        if let message = refusal(folder) { return .blocked(message: message) }
        // Before a folder is made for them: nothing is made in the Trash.
        if Paths.isInsideTrash(folder, homePath: trashHomePath) {
            return .blocked(message: "Items can\u{2019}t be \(verb == "Move" ? "moved" : "extracted") into the Trash.")
        }
        guard let refused = await TabDragDrop.destinationRefusal(folder, services.directoryService) else {
            return await start(folder)
        }
        // A folder that isn't there, in one that is, can be made first.
        let parent = NodePath.dirname(folder)
        let isMissing = await BlockingWork.run { (try? FileManager.default.attributesOfItem(atPath: folder)) == nil }
        guard isMissing, !samePath(parent, folder),
            await TabDragDrop.destinationRefusal(parent, services.directoryService) == nil
        else { return .blocked(message: refused) }
        guard creates else {
            offer(
                "There\u{2019}s no folder \u{201C}\(NodePath.basename(folder))\u{201D} there yet: Create and \(verb) "
                    + "makes it first.")
            return .cancelled
        }
        switch await actions.makeFolder(at: folder) {
        case .made(let made):
            return await start(made)
        case .failed(let message):
            return .error(message: message)
        case .cancelled:
            return .cancelled
        }
    }

    /// Why a move into `folder` can't be: it is inside one of the items. Said before a folder typed there is made,
    /// which would otherwise be left behind inside the item when the move is refused. Byte for byte: a folder whose
    /// path differs from an item's only in how an accent is stored is another folder, and takes the item.
    static func insideItself(_ paths: [String], folder: String) -> String? {
        guard let item = paths.first(where: { folder.utf8.starts(with: ($0 + "/").utf8) }) else { return nil }
        return "\u{201C}\(NodePath.basename(item))\u{201D} can\u{2019}t be moved into itself."
    }

    /// Why a move into `folder` would do nothing: every item is in it already, by its path's bytes.
    static func alreadyThere(_ paths: [String], in folder: String) -> String? {
        let folder = DiskPath(folder)
        guard !paths.isEmpty, paths.allSatisfy({ DiskPath($0).parent == folder }) else { return nil }
        return paths.count == 1
            ? "\u{201C}\(NodePath.basename(paths[0]))\u{201D} is already in this folder."
            : "These items are already in this folder."
    }

    /// A move from the Move To box into a folder checked already.
    private func startMove(_ paths: [String], to destination: String, _ actions: WindowWriteActions) async
        -> CopyLikeOutcome
    {
        await actions.copyLike(
            mode: .cut, sources: paths, destination: destination, action: .moveTo, initiator: .moveDialog,
            reportsRefusals: false)
    }

    // MARK: Alerts

    /// A notice with one OK over the tab's window, its detail list under the message.
    func showNotice(title: String, message: String, detailLines: [String] = []) {
        guard let window else { return }
        InWindowAlerts.notice(title: title, message: message, detailLines: detailLines, in: window)
    }
}
