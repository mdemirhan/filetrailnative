// Port of apps/desktop/src/renderer/components/PathbarFolderMenu.tsx, shown as a system menu (D-022)
import AppKit
import FTFoundation

final class InfoFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The folder menu of one separator, while it is open: it asks for the folders and opens above the button.
@MainActor
final class PathFolderMenuController {
    private var menu: AppMenu?
    private weak var button: PathSeparatorView?
    private var requestID = 0
    private var folders: [PathbarFolder]?
    private var failed = false
    private var activePath = ""
    private var limited = PathbarFolderMenuModel.Limited(shown: [], hiddenBefore: 0, hiddenAfter: 0)
    private weak var window: NSWindow?
    private var presenter: AppMenuPresenter?
    private var loadingTimer: DispatchWorkItem?
    var onNavigate: (String) -> Void = { _ in }
    var onChange: (Bool) -> Void = { _ in }

    var isOpen: Bool { button != nil }

    func isOpen(from view: PathSeparatorView) -> Bool { button === view }

    func toggle(
        from separator: PathSeparatorView, parent: String, active: String,
        request: @escaping @MainActor (String) async throws -> [PathbarFolder]
    ) {
        if button === separator {
            close()
            return
        }
        close()
        guard let window = separator.window else { return }
        let presenter = AppMenuPresenter.shared
        presenter.close()
        self.presenter = presenter
        self.window = window
        button = separator
        activePath = active
        folders = nil
        failed = false
        separator.setMenuOpen(true)
        onChange(true)
        requestID += 1
        let id = requestID
        // A moment's wait shows nothing; a slow folder shows "Loading…".
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.requestID == id, self.folders == nil, !self.failed else { return }
                self.present()
            }
        }
        loadingTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.folderMenuLoadingDelay, execute: timer)
        Task { @MainActor [weak self] in
            let result = await Result { try await request(parent) }
            guard let self, self.requestID == id, self.button != nil else { return }
            switch result {
            case .success(let list):
                self.folders = list
                self.failed = false
            case .failure:
                self.folders = []
                self.failed = true
            }
            self.present()
        }
    }

    /// Notes ("Loading…", "3 more folders above") and folders, the one on the path ticked.
    private func items() -> [AppMenuItem] {
        func note(_ text: String) -> AppMenuItem {
            AppMenuItem(title: text, enabled: false, rowIdentifier: "pathBarMenu.note")
        }
        guard let folders else { return [note("Loading…")] }
        if failed { return [note("Can’t Read This Folder")] }
        if folders.isEmpty { return [note("No Folders")] }
        limited = PathbarFolderMenuModel.limit(folders, activePath: activePath)
        var items: [AppMenuItem] = []
        if limited.hiddenBefore > 0 {
            items.append(note(PathbarFolderMenuModel.hiddenLabel(limited.hiddenBefore) + " above"))
        }
        for folder in limited.shown {
            items.append(
                AppMenuItem(
                    title: folder.name, checked: folder.path == activePath ? true : nil, tooltip: folder.path,
                    action: { [weak self] in self?.choose(folder) }))
        }
        if limited.hiddenAfter > 0 {
            items.append(note(PathbarFolderMenuModel.hiddenLabel(limited.hiddenAfter) + " below"))
        }
        return items
    }

    private func present() {
        guard let button, let window, let presenter, let host = AppMenuPresenter.overlayHost(of: window) else { return }
        let items = items()
        // The keyboard starts on the ticked folder, else on the first.
        let marked =
            folders == nil || failed ? nil : items.firstIndex { $0.checked == true } ?? items.firstIndex { $0.enabled }
        // Above the button: its bottom edge 6 pt over the button, its left edge 6 pt left of it. A list too tall for
        // that opens with the ticked folder at the button, which keeps it in view, as a Mac pop-up opens.
        func place(_ menu: AppMenu) -> (origin: NSPoint, positioning: Int?) {
            let rect = button.convert(button.bounds, to: host)
            let buttonTop = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            let left = rect.minX - InfoMetrics.folderMenuGap
            let top = buttonTop - InfoMetrics.folderMenuGap - menu.size.height
            let fits = top >= 0
            return (NSPoint(x: left, y: fits ? top : buttonTop), fits ? nil : marked)
        }
        // The folders in place of "Loading…": the menu goes where they put it, its bottom edge staying put.
        if let menu {
            menu.markedIndex = marked
            menu.setItems(items)
            let (origin, positioning) = place(menu)
            presenter.move(to: origin, positioning: positioning)
            return
        }
        let view = AppMenu(
            items: items, identifier: "pathBarMenu", rowIdentifier: "pathBarMenu.item",
            minWidth: InfoMetrics.folderMenuMinWidth, maxWidth: InfoMetrics.folderMenuMaxWidth)
        view.markedIndex = marked
        menu = view
        let (origin, positioning) = place(view)
        presenter.show(view, in: window, at: origin, owner: button, positioning: positioning) { [weak self] in
            self?.close()
        }
    }

    private func choose(_ folder: PathbarFolder) {
        let active = activePath
        close()
        if folder.path != active { onNavigate(folder.path) }
    }

    func close() {
        requestID += 1
        loadingTimer?.cancel()
        loadingTimer = nil
        let shown = menu
        menu = nil
        let was = button
        button = nil
        if shown != nil, shown === presenter?.menu { presenter?.close() }
        presenter = nil
        was?.setMenuOpen(false)
        if was != nil { onChange(false) }
    }
}
