// Port of apps/desktop/src/renderer/hooks/useExplorerDragAndDrop.ts on AppKit's dragging: a tab's drags out (the system
// file drag, its images and its end, the items other apps took away) and the drags over it (the targets, move or
// copy by the disks and the keys, the highlights, springing folders, the tree's hover expand, the drop). AppKit's
// dragging callbacks replace the web page's guesses about when a drag came, left and ended; `draggingSequenceNumber`
// tells one drag from the next (D-004).
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

@MainActor
final class TabDragDrop {
    /// The drag of the app's own items going on, from the window it started in.
    struct OwnDrag {
        let session: DragSession
        let windowNumber: Int
        /// The tab it came from.
        weak var tab: MainWindowController?
    }

    /// Where a drop goes, as the drag-overs and the drop work it out.
    struct Target: Equatable {
        var surface: DropTargetSurface
        var path: String
        var supportsMove: Bool
        var isSelected = false
        /// The tree selects the target after the drop (a folder of the tree or a favorite, not a location).
        var selectsInTree = false
    }

    /// The app's own drag, while it lasts (one at a time).
    static var ownDrag: OwnDrag?
    /// Operations started by a drop from another app: told quietly when they land in the folder on screen.
    static var externalDropOperations: Set<String> = []
    /// What the drop asks the disks (injectable for tests).
    static var readDiskIds: @Sendable ([String]) -> [Int64?] = { SystemActions.diskIds(paths: $0) }
    /// Brings the window forward for a question or a result about a drop from another app, when the app isn't
    /// active (B-CLIP-178; injectable for tests).
    static var bringForward: (NSWindow?) -> Void = { window in
        guard !NSApp.isActive else { return }
        Task { _ = await FileDrag.bringToFront(window) }
    }
    /// The modifier keys held now.
    static var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// Whether a drag is still held anywhere over the window (injectable for tests). Only the list, the grid and the
    /// sidebar hear drag-overs from AppKit; the original hears them from the whole window.
    static var dragIsHeldOver: (NSWindow?) -> Bool = { window in
        guard let window, window.isVisible else { return false }
        return NSEvent.pressedMouseButtons & 1 != 0 && window.frame.contains(NSEvent.mouseLocation)
    }

    /// Whether a drag that was over the window just now was let go there: the button is up, with the pointer still over
    /// it (`noteExternalDragLetGo`; injectable for tests).
    static var dragWasLetGoOver: (NSWindow?) -> Bool = { window in
        guard let window, window.isVisible else { return false }
        return NSEvent.pressedMouseButtons & 1 == 0 && window.frame.contains(NSEvent.mouseLocation)
    }

    /// `EXTERNAL_DRAG_GONE_MS`: another app's drag is taken to be gone when its drag-overs stop this long.
    private static let externalDragGoneMs = 400.0

    private(set) weak var tab: MainWindowController?
    private var external: (sequence: Int, session: DragSession?)?
    private var spring = SpringHold()
    /// Where the tab was before the drag's first spring in it, and whether a folder opened.
    private var springStart: (sequence: Int, place: MainWindowController.TabPlace, opened: Bool)?
    /// Spring reads not back yet (`opening`): a drag can end with one on its way.
    private var springsOpening = 0
    private var externalGone: DispatchWorkItem?
    private var quiet: DispatchWorkItem?
    private var hoverExpand: (path: String, work: DispatchWorkItem)?
    private var refusedDropToastSequence: Int?
    /// What the disks have said about one drag's folders (`diskAnswersRef`): asked again for each drag.
    private var disks: (session: DragSession, answers: DiskAnswers)?

    init(tab: MainWindowController) {
        self.tab = tab
    }

    /// A window is blocked for drags: a write runs (here or in another window), a sheet, a dialog drawn in the window
    /// or a copy and paste dialog is open, or the toolbar is being customized (`dragDropBlocked`).
    var isBlocked: Bool {
        guard let tab else { return true }
        return tab.isWriteLocked || tab.window?.attachedSheet != nil || tab.isDialogOpen
            || CopyPasteDialogs.isOpen(in: tab.window) || tab.isCustomizingToolbar
    }

    // MARK: Drag out

    /// A press on an item moved far enough: a system drag of the items it carries starts (B-CLIP-148, B-CLIP-149).
    /// While a write runs it doesn't, and a toast says why; the gesture is taken either way.
    func beginDrag(_ entries: [DirectoryEntry], event: NSEvent, from view: NSView) -> Bool {
        guard let tab, let window = tab.window, !entries.isEmpty else { return false }
        if let refusal = busyRefusal(drop: false) {
            _ = NotificationOverlay.push(.info, title: refusal, in: window)
            return true
        }
        guard !isBlocked, let session = makeSession(entries) else { return false }
        let paths = session.sourceItems.map(\.path)
        var images: [FileDragImage] = []
        var source = view
        if let placed = tab.content.dragPlacements(for: paths) {
            source = placed.view
            images = FileDragImages.measure(paths, placements: placed.placements)
        }
        let directories = Self.dragDirectories(session.sourceItems)
        let thumbnails = Self.dragThumbnails(paths, images: images) {
            IconThumbnails.store.loadedPicture(forPath: $0)?.image
        }
        Self.ownDrag = OwnDrag(session: session, windowNumber: window.windowNumber, tab: tab)
        tab.folderChangesHeld = true
        let started = FileDrag.start(
            from: source, event: event, paths: paths, directories: directories, images: images,
            thumbnails: thumbnails
        ) { [weak self] operation, over in
            self?.ownDragEnded(paths: paths, operation: operation, over: over)
        }
        if !started {
            Self.ownDrag = nil
            tab.folderChangesHeld = false
        }
        return started
    }

    /// Which dragged items go on the pasteboard as folders: folders as the disk has them, a link to one and an app
    /// or package among them.
    static func dragDirectories(_ items: [DragItem]) -> [Bool] {
        items.map { $0.kind == .directory || $0.kind == .symlinkDirectory || $0.kind == .bundle }
    }

    /// The Quick Look pictures the dragged items show (Icons view), by their place among `paths`; the others are
    /// drawn with their file icons.
    static func dragThumbnails(
        _ paths: [String], images: [FileDragImage], loaded: (String) -> NSImage?
    ) -> [Int: NSImage] {
        var thumbnails: [Int: NSImage] = [:]
        for image in images where image.thumbnail && paths.indices.contains(image.index) {
            if let picture = loaded(paths[image.index]) { thumbnails[image.index] = picture }
        }
        return thumbnails
    }

    /// The session of a drag of `entries` from the list: the search results' own surface, or the folder's.
    private func makeSession(_ entries: [DirectoryEntry]) -> DragSession? {
        guard let tab, let lead = entries.first else { return nil }
        var kinds: [PathBox: FTFoundation.EntryKind] = [:]
        for entry in entries { kinds[PathBox(entry.path)] = entry.kind.rules }
        return DragRules.session(
            sourceSurface: tab.searchRootPath != nil ? .search : .content, draggedPath: lead.path,
            selectedPathsInViewOrder: entries.map(\.path), kindOf: { kinds[PathBox($0)] })
    }

    /// `endFileDrag`: the app's own drag ended. Dropped elsewhere with a move or a delete (the Dock's Trash), the
    /// items another app took are looked for (B-CLIP-165); a drag that ended without a drop in this tab (one on
    /// another window included) brings the tab back from the folders it sprang into (B-CLIP-169). A drop here has
    /// let go of where the tab was already.
    func ownDragEnded(paths: [String], operation: FileDragEnd, over: FileDragEndedOver) {
        Self.ownDrag = nil
        tab?.folderChangesHeld = false
        clearTargets()
        restoreSprings()
        disks = nil
        if over == .elsewhere, operation == .move || operation == .delete {
            checkDraggedAway(paths, intoTrash: operation == .delete, after: DragTimings.draggedAwayChecksMs)
        }
    }

    /// `followDraggedAway`: asks the disk which dragged items are gone, after each wait in turn; gone ones are told at
    /// once and not asked about again. Each drag is followed on its own, however many end meanwhile, until the tab goes.
    func checkDraggedAway(_ paths: [String], intoTrash: Bool, after waits: [Double]) {
        guard let wait = waits.first, !paths.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let found = FileDrag.findDraggedAway(paths, intoTrash: intoTrash)
                if !found.gone.isEmpty { self.draggedAway(found.gone, cleared: found.cleared, intoTrash: intoTrash) }
                let gone = Set(found.gone.map(PathBox.init))
                let remaining = paths.filter { !gone.contains(PathBox($0)) }
                self.checkDraggedAway(remaining, intoTrash: intoTrash, after: Array(waits.dropFirst()))
            }
        }
    }

    /// `filetrail:draggedAway`: the clipboard lets go of the items (a cut of any is cancelled), every window forgets
    /// their sizes and reads what they left again, and the search results on screen are found again.
    func draggedAway(_ gone: [String], cleared: [String], intoTrash: Bool) {
        guard let tab else { return }
        let clipboard = tab.services.clipboard
        let followed = ClipboardRules.followThroughRemoval(clipboard.contents, gone)
        if followed != clipboard.contents {
            clipboard.set(followed, follows: clipboard.contents.capturedAt, from: tab.windowID)
            tab.clipboardChanged()
        }
        let tabs = (NSApp.delegate as? AppDelegate)?.explorerWindowsIfStarted?.allTabs ?? [tab]
        for each in tabs {
            each.folderSizes.forgetChangedSizes(cleared, intoTrash: intoTrash)
            each.reload(changedPaths: cleared)
        }
        findSearchResultsAgain()
    }

    /// `followItemsGoneElsewhere`: search results on screen are found again, as after a write of the app's own
    /// (B-SRCH-142).
    func findSearchResultsAgain() {
        guard let tab else { return }
        let shown = tab.group?.selected ?? tab
        if shown.searchRootPath != nil { shown.search.session.rerun() }
    }

    // MARK: Drags over the tab

    /// The drag `info` carries: the app's own from this window, or one from another app (another window of the app
    /// included), its files read from its pasteboard once per drag. Nil for a drag of no files.
    func session(for info: any NSDraggingInfo) -> DragSession? {
        if let own = Self.ownDrag, info.draggingSource is FileDragSource, own.windowNumber == tab?.window?.windowNumber
        {
            external = nil
            return own.session
        }
        let sequence = info.draggingSequenceNumber
        if let external, external.sequence == sequence { return external.session }
        let read = DragPasteboard.draggedIn(DragPasteboard.read(info.draggingPasteboard))
        let made = externalSession(read.items.map { DragItem(path: $0.path, kind: $0.kind.rules) })
        external = (sequence, made)
        return made
    }

    private func externalSession(_ items: [DragItem]) -> DragSession? {
        guard let lead = items.first else { return nil }
        return DragSession(sourceSurface: .external, sourceItems: items, leadPath: lead.path, leadKind: lead.kind)
    }

    /// Whether the source offers a move (`effectAllowed`).
    private func offersMove(_ info: any NSDraggingInfo, _ session: DragSession) -> Bool {
        session.sourceSurface != .external || !info.draggingSourceOperationMask.intersection([.move, .generic]).isEmpty
    }

    /// The decision for a drop of `session` on `target`: the operation, or why not.
    func decide(
        _ session: DragSession?, target: Target?, offersMove: Bool, modifiers: NSEvent.ModifierFlags,
        answers: DiskAnswers? = nil
    ) -> (operation: DropOperation, refusal: DropRefusal?) {
        let option = modifiers.contains(.option)
        let command = modifiers.contains(.command)
        guard let session, let target else {
            return (
                .move,
                DragRules.validate(
                    session: session, blocked: isBlocked, targetSurface: .content, targetPath: nil,
                    targetSupportsMove: false)
            )
        }
        let same = onSameDisk(session, target.path, answers: answers)
        let operation = DragRules.allowedBySource(
            DragRules.operation(
                session.facts, targetPath: target.path, option: option, command: command, onSameDisk: same),
            offersMove: offersMove)
        let refusal = DragRules.validate(
            session: session, blocked: isBlocked, targetSurface: target.surface, targetPath: target.path,
            targetSupportsMove: target.supportsMove, targetIsSelected: target.isSelected, operation: operation)
        return (operation, refusal)
    }

    /// The cursor for a decision, as the source allows it.
    private func dragOperation(
        _ decision: (operation: DropOperation, refusal: DropRefusal?), _ info: any NSDraggingInfo
    )
        -> NSDragOperation
    {
        guard decision.refusal == nil else { return [] }
        let mask = info.draggingSourceOperationMask
        if decision.operation == .copy { return mask.contains(.copy) ? .copy : mask.intersection([.generic, .move]) }
        if mask.contains(.move) { return .move }
        return mask.contains(.generic) ? .generic : .copy
    }

    // MARK: The content pane

    /// The target of a drag over the content pane: a folder row (real folders take drops; an alias shows invalid),
    /// or the folder on screen, which takes a drag from another app, and the app's own once it has sprung into it.
    func contentTarget(_ session: DragSession, entry: DirectoryEntry?) -> Target? {
        guard let tab else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let entry {
            // Search results take drops from other apps only.
            if tab.searchRootPath != nil, session.sourceSurface != .external { return nil }
            let real = entry.kind == .directory && !entry.isSymlink
            return Target(
                surface: .content, path: entry.path,
                supportsMove: real && !Paths.isInsideTrash(entry.path, homePath: home),
                isSelected: session.facts.sourcePaths.contains { samePath($0, entry.path) })
        }
        // Search results have no background to drop on (App.tsx leaves out its background handlers in search).
        guard tab.searchRootPath == nil else { return nil }
        let folder = tab.shownFolderPath
        guard !folder.isEmpty, session.sourceSurface == .external || springOpenedHere(session) else { return nil }
        return Target(surface: .content, path: folder, supportsMove: !Paths.isInsideTrash(folder, homePath: home))
    }

    private func springOpenedHere(_ session: DragSession) -> Bool {
        guard let start = springStart, let own = Self.ownDrag, own.session === session else { return false }
        return start.opened
    }

    /// A drag-over of the content pane, at the entry under it (nil: a file or empty space).
    func contentDragUpdated(_ info: any NSDraggingInfo, entry: DirectoryEntry?) -> NSDragOperation {
        guard let tab else { return [] }
        noteDragOver()
        clearTreeTarget()
        let session = session(for: info)
        guard let session else {
            tab.content.setDropTarget(nil, nil, background: nil)
            return []
        }
        let target = contentTarget(session, entry: entry)
        let decision = decide(
            session, target: target, offersMove: offersMove(info, session), modifiers: Self.modifiers())
        let state: DropTargetState? = target.map { _ in decision.refusal == nil ? .valid : .invalid }
        if let entry, let target {
            let point = info.draggingLocation
            let step = spring.over(
                entry.path,
                canSpring: canSpring(session, into: entry, target: target, refusal: decision.refusal),
                at: (Double(point.x), Double(point.y)), now: Date().timeIntervalSince1970 * 1000)
            switch step {
            case .idle: tab.content.setDropTarget(entry.path, state, background: nil)
            case .warning: tab.content.setDropTarget(entry.path, .springing, background: nil)
            case .open(let path):
                tab.content.setDropTarget(nil, nil, background: nil)
                springOpen(path, sequence: info.draggingSequenceNumber)
            }
        } else {
            spring.reset()
            tab.content.setDropTarget(nil, nil, background: target == nil ? nil : state)
        }
        return dragOperation(decision, info)
    }

    /// Whether a drag resting on the folder `entry` opens it: one that takes the drop and isn't the folder on screen,
    /// and never while the tab shows search results, whatever the drag came from (`openFolder` is null then).
    func canSpring(_ session: DragSession, into entry: DirectoryEntry, target: Target, refusal: DropRefusal?) -> Bool {
        guard let tab, tab.searchRootPath == nil else { return false }
        return refusal == nil && target.supportsMove && !isBlocked && !samePath(entry.path, tab.folder.path)
            && session.sourceSurface != .search
    }

    /// Opens the folder a drag rests on in the tab, noting first where the tab was.
    func springOpen(_ path: String, sequence: Int) {
        guard let tab else { return }
        if springStart?.sequence != sequence {
            springStart = (sequence, tab.tabPlace, false)
        }
        springStart?.opened = true
        springsOpening += 1
        Task { [weak self] in
            // A drag that ended before this began has already sent the tab back.
            if self?.springStart?.sequence == sequence {
                await tab.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
            }
            self?.springsOpening -= 1
        }
    }

    /// A drag that sprang into folders ended without a drop in the app: the tab goes back where it was, overtaking a
    /// read still on its way.
    private func restoreSprings() {
        guard let start = springStart, let tab else { return }
        springStart = nil
        guard
            start.opened,
            springsOpening > 0 || !samePath(tab.folder.path, start.place.path)
                || tab.navigationHistory != start.place.history
        else { return }
        Task { await tab.comeBack(to: start.place) }
    }

    /// `checkExternalDragStillOver`: drag-overs of another app's drag stopped. Held over a part of the window that hears
    /// none (the path bar, the toolbar, the Info panel), it is still there; otherwise it left the window, was let go or
    /// was cancelled. AppKit tells no destination of that; one that was dropped here has let go of where the tab was
    /// already.
    private func settleExternalDrag() {
        let sprung = springStart != nil && external?.sequence == springStart?.sequence
        if Self.dragIsHeldOver(tab?.window) {
            if sprung || (isBlocked && external?.session != nil) { armExternalGone() }
            return
        }
        tellDropRefusedIfLetGo()
        if sprung { restoreSprings() }
    }

    /// The drag was let go over the content pane.
    func contentPerformDrop(_ info: any NSDraggingInfo, entry: DirectoryEntry?) -> Bool {
        let session = session(for: info)
        let target = session.flatMap { contentTarget($0, entry: entry) }
        return drop(info, session: session, target: target)
    }

    // MARK: The sidebar

    /// The target of a drag over a sidebar row: a folder of the tree (not an alias), a favorite or a location (not
    /// the Trash); nothing inside the Trash (B-TREE-157, B-TREE-159).
    func sidebarTarget(_ row: SidebarRowState?) -> Target? {
        guard let row, let path = row.item.path, row.item.kind != .favoritesRoot, row.item.kind != .locationsRoot
        else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let trash = Paths.isInsideTrash(path, homePath: home)
        switch row.item.kind {
        case .filesystem:
            return Target(
                surface: .tree, path: path, supportsMove: !row.item.isSymlink && !trash, selectsInTree: true)
        case .favorite:
            return Target(surface: .favorite, path: path, supportsMove: !trash, selectsInTree: true)
        default:
            return Target(surface: .favorite, path: path, supportsMove: !trash)
        }
    }

    func sidebarDragUpdated(_ info: any NSDraggingInfo, row: SidebarRowState?) -> NSDragOperation {
        guard let tab else { return [] }
        noteDragOver()
        let session = session(for: info)
        let target = sidebarTarget(row)
        guard let session, let target, let path = row?.item.path else {
            tab.sidebarController.dropStates = [:]
            cancelHoverExpand()
            return []
        }
        let decision = decide(
            session, target: target, offersMove: offersMove(info, session), modifiers: Self.modifiers())
        tab.sidebarController.dropStates = [path: decision.refusal == nil ? .valid : .invalid]
        if let row, decision.refusal == nil, row.subview == .tree, row.item.kind == .filesystem, row.item.canExpand,
            !row.item.expanded, !row.item.loading, !row.item.isSymlink
        {
            hoverExpand(path)
        } else {
            cancelHoverExpand()
        }
        return dragOperation(decision, info)
    }

    func sidebarPerformDrop(_ info: any NSDraggingInfo, row: SidebarRowState) -> Bool {
        drop(info, session: session(for: info), target: sidebarTarget(row))
    }

    /// A folder of the tree held under a valid drag for 700 ms expands; another row starts the wait again.
    private func hoverExpand(_ path: String) {
        if let hoverExpand, samePath(hoverExpand.path, path) { return }
        cancelHoverExpand()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let tab = self.tab else { return }
                self.hoverExpand = nil
                tab.sidebarController.model.toggle(path)
            }
        }
        hoverExpand = (path, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + DragTimings.treeHoverExpandMs / 1000, execute: work)
    }

    private func cancelHoverExpand() {
        hoverExpand?.work.cancel()
        hoverExpand = nil
    }

    // MARK: Leaving and dropping

    /// Drag-overs keep coming while a drag is over the tab; 300 ms without one, it has left (or ended), and the
    /// targets show nothing.
    private func noteDragOver() {
        quiet?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.clearTargets() } }
        quiet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DragTimings.dropTargetsQuietMs / 1000, execute: work)
        armExternalGone()
    }

    private func armExternalGone() {
        externalGone?.cancel()
        let gone = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settleExternalDrag() } }
        externalGone = gone
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.externalDragGoneMs / 1000, execute: gone)
    }

    /// AppKit asks for no drop whose last answer was none: it says the drag left, when the button comes up too.
    func dragExited() {
        clearTargets()
        tellDropRefusedIfLetGo()
    }

    /// `noteExternalDragLetGo`: a drag from another app was let go over the window while a write holds it. "The page
    /// hears nothing else of a drop it refused": neither does a view here. Not for a drag that only passes over.
    private func tellDropRefusedIfLetGo() {
        guard let external, external.session != nil, isBlocked, Self.dragWasLetGoOver(tab?.window) else { return }
        tellDropRefused(sequence: external.sequence)
    }

    /// `tellDropRefused`: why the drop isn't taken, once for each drag.
    private func tellDropRefused(sequence: Int) {
        guard refusedDropToastSequence != sequence, let refusal = busyRefusal(drop: true) else { return }
        refusedDropToastSequence = sequence
        _ = NotificationOverlay.push(.info, title: refusal, in: tab?.window)
    }

    func clearTargets() {
        quiet?.cancel()
        quiet = nil
        spring.reset()
        tab?.content.setDropTarget(nil, nil, background: nil)
        clearTreeTarget()
    }

    /// `clearTreeTarget`: the sidebar's folder the drag was over shows nothing, and doesn't open. The sidebar says
    /// nothing when a drag moves on from it to the list or the grid, whose drag-overs would keep off the quiet time.
    private func clearTreeTarget() {
        cancelHoverExpand()
        if tab?.sidebarController.dropStates.isEmpty == false { tab?.sidebarController.dropStates = [:] }
    }

    /// Why a drag doesn't start, or a drop from another app isn't taken, while an operation runs; nil when none
    /// runs.
    func busyRefusal(drop: Bool) -> String? {
        guard let tab, let group = tab.group, let operations = AppWriteOperations.current else { return nil }
        let session = operations.session(for: group)
        if let card = session.card {
            return ClipboardTexts.dragRefusedWhileBusy(
                action: card.action.rawValue, currentSourcePath: card.currentSourcePath, drop: drop)
        }
        if let foreign = session.foreign {
            return ClipboardTexts.dragRefusedWhileBusy(
                action: foreign.action.rawValue, currentSourcePath: foreign.currentSourcePath, drop: drop)
        }
        return nil
    }

    /// A drop: checked again, then a copy or a move through the paste's flow. Without ⌥ or ⌘, a drop whose disks
    /// haven't answered waits up to 1.5 s for them, and is refused if they still haven't (B-CLIP-162).
    func drop(_ info: any NSDraggingInfo, session: DragSession?, target: Target?) -> Bool {
        let offers = session.map { offersMove(info, $0) } ?? true
        return drop(
            session: session, target: target, offersMove: offers, modifiers: Self.modifiers(),
            sequence: info.draggingSequenceNumber)
    }

    @discardableResult
    func drop(
        session: DragSession?, target: Target?, offersMove: Bool, modifiers: NSEvent.ModifierFlags, sequence: Int
    ) -> Bool {
        clearTargets()
        guard tab != nil else { return false }
        // The drag ends with its drop: the drop keeps its own hold on what the disks have said, and are still to say.
        let answers = session.map(diskAnswers)
        disks = nil
        let decision = decide(
            session, target: target, offersMove: offersMove, modifiers: modifiers, answers: answers)
        if decision.refusal == .blocked, session?.sourceSurface == .external { tellDropRefused(sequence: sequence) }
        guard let session, let target, decision.refusal == nil else { return false }
        if springStart?.sequence == sequence { springStart = nil }
        // `endExternalDrag`: a drag taken here is over, and its own write's card is no refusal of it.
        if external?.sequence == sequence {
            external = nil
            externalGone?.cancel()
            externalGone = nil
        }
        let waitsForDisks =
            !modifiers.contains(.option) && !modifiers.contains(.command)
            && onSameDisk(session, target.path, answers: answers) == nil
        Task { [weak self] in
            guard let self else { return }
            var operation = decision.operation
            if waitsForDisks {
                guard let answered = await self.waitForDisks(session, target.path, answers: answers) else {
                    self.couldNotDrop(external: session.sourceSurface == .external)
                    return
                }
                operation = DragRules.allowedBySource(answered ? .move : .copy, offersMove: offersMove)
                // A move into the items' own folder is dropped silently.
                guard
                    DragRules.validate(
                        session: session, blocked: self.isBlocked, targetSurface: target.surface,
                        targetPath: target.path, targetSupportsMove: target.supportsMove,
                        targetIsSelected: target.isSelected, operation: operation) == nil
                else { return }
            }
            await self.start(session, target: target, operation: operation)
        }
        return true
    }

    /// `copy_to` or `move_to` through the paste's flow, with the tree's target selected after it. The destination is
    /// checked first (`validateDestinationBeforeAnalyze`): only a real folder takes a drop, so a favorite that links
    /// to one refuses it, as the original does (an accepted risk: the drop showed as taken).
    private func start(_ session: DragSession, target: Target, operation: DropOperation) async {
        guard let tab, let actions = tab.writeActions else { return }
        let action: WriteOperationAction = operation == .copy ? .copyTo : .moveTo
        let outcome: CopyLikeOutcome
        if actions.refuseWhileBusy(.operation(action)) {
            outcome = .cancelled
        } else if let message = await Self.destinationRefusal(target.path, tab.services.directoryService) {
            actions.dialogs.showRefusal(.operation(action), message: message, in: tab.window)
            outcome = .blocked(message: message)
        } else {
            if target.selectsInTree { actions.session.pendingTreeSelectionPath = target.path }
            outcome = await actions.copyLike(
                mode: operation == .copy ? .copy : .cut, sources: session.facts.sourcePaths,
                destination: target.path, action: action, initiator: .dragDrop, checksBusy: false,
                moveFromSearchResults: action == .moveTo && session.sourceSurface == .search)
        }
        switch outcome {
        case .queued(let operationId):
            if session.sourceSurface == .external { Self.externalDropOperations.insert(operationId) }
        case .review:
            actions.reviewIfAsked(outcome, action: action)
            fallthrough
        default:
            // A question or an error about a drop from another app brings the window forward.
            if session.sourceSurface == .external { Self.bringForward(tab.window) }
        }
    }

    /// `validateMoveDestinationDirectory`: why `path` can't take a drop (not a folder, or a link to one), or nil.
    static func destinationRefusal(_ path: String, _ service: DirectoryService) async -> String? {
        let item = await service.itemProperties(path: path)
        return item.kind != .directory || item.isSymlink ? "Destination must be an existing folder." : nil
    }

    // MARK: Disks

    /// What the disks have said about one drag's folders: `.some(nil)` for a path that can't be read.
    @MainActor
    final class DiskAnswers {
        fileprivate var ids: [PathBox: Int64?] = [:]
        fileprivate var asking: Set<PathBox> = []
    }

    /// The answers of `session`'s drag: a new drag starts with none, so each one asks the disks again.
    private func diskAnswers(_ session: DragSession) -> DiskAnswers {
        if let disks, disks.session === session { return disks.answers }
        let answers = DiskAnswers()
        disks = (session, answers)
        return answers
    }

    /// Whether the items and the target are on one disk, as far as the disks have answered for this drag; asks them
    /// otherwise.
    func onSameDisk(_ session: DragSession, _ target: String, answers: DiskAnswers? = nil) -> Bool? {
        let answers = answers ?? diskAnswers(session)
        let paths = session.facts.folderPaths + [target]
        let missing = paths.filter { answers.ids[PathBox($0)] == nil }
        if !missing.isEmpty { askDisks(missing, into: answers) }
        return DragRules.onSameDisk(sourceFolderPaths: session.facts.folderPaths, targetPath: target) {
            answers.ids[PathBox($0)]
        }
    }

    private func askDisks(_ paths: [String], into answers: DiskAnswers) {
        let asking = paths.filter { answers.asking.insert(PathBox($0)).inserted }
        guard !asking.isEmpty else { return }
        let read = Self.readDiskIds
        Task.detached {
            let ids = read(asking)
            await MainActor.run {
                for (path, id) in zip(asking, ids) {
                    answers.ids[PathBox(path)] = .some(id)
                    answers.asking.remove(PathBox(path))
                }
            }
        }
    }

    /// Waits up to 1.5 s for the disks; nil when one didn't answer or can't be read.
    private func waitForDisks(_ session: DragSession, _ target: String, answers: DiskAnswers?) async -> Bool? {
        let deadline = Date().addingTimeInterval(DragTimings.diskAnswerWaitMs / 1000)
        while Date() < deadline {
            if let same = onSameDisk(session, target, answers: answers) { return same }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return onSameDisk(session, target, answers: answers)
    }

    /// `Couldn’t Drop`.
    private func couldNotDrop(external: Bool) {
        guard let tab else { return }
        tab.writeActions?.dialogs.show(
            "Couldn\u{2019}t Drop",
            "A disk didn\u{2019}t answer in time or couldn\u{2019}t be read, so File Trail couldn\u{2019}t tell whether to move or copy the items. Nothing was moved or copied.",
            tab.window)
        if external { Self.bringForward(tab.window) }
    }
}
