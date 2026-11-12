#if DEBUG
    import AppKit

    extension AutomationRunner {
        // MARK: Mouse

        func click(
            _ ref: Scenario.ElementRef, button: Scenario.MouseButton, count: Int, modifiers names: [String],
            holdMilliseconds: Int = 0, window: NSWindow
        ) async -> Outcome {
            guard let modifiers = KeyEvents.modifiers(names) else {
                return Outcome(.failed, "unknown modifier in \(names)")
            }
            let match: ElementFinder.Match
            switch ElementFinder.find(ref, elements: elements, in: window) {
            case .failure(let failure): return Outcome(.failed, failure.message)
            case .success(let found): match = found
            }
            // A right click opens a native menu, whose tracking loop would hold the run: the menu is
            // found and not shown.
            // The app's own right-click menus (Back and Forward's history) are drawn in the window: the press is sent.
            if button == .right, let target = match.view.window,
                let pressed = target.contentView?.superview?.hitTest(MouseEvents.center(of: match.view)),
                pressed is ToolbarButton || pressed.superview is ToolbarButton,
                let event = MouseEvents.event(.rightMouseDown, at: MouseEvents.center(of: match.view), in: target)
            {
                target.sendEvent(event)
                return Outcome(.ok)
            }
            if button == .right { return contextMenu(match, ref: ref) }
            guard let target = match.view.window else { return Outcome(.failed, "\(ref) is in no window") }
            if holdMilliseconds > 0 {
                let done = await MouseEvents.press(
                    at: MouseEvents.center(of: match.view), in: target, holdMilliseconds: holdMilliseconds,
                    modifiers: modifiers)
                return done ? Outcome(.ok) : Outcome(.failed, "could not make the mouse events")
            }
            let done = await MouseEvents.click(
                at: MouseEvents.center(of: match.view), in: target, count: count, modifiers: modifiers)
            return done ? Outcome(.ok) : Outcome(.failed, "could not make the mouse events")
        }

        /// The menu a right click on the element would show: asked of the view under its center and the
        /// views above it, as AppKit asks. It is only found, since a native menu can't be drawn into the
        /// window's capture.
        private func contextMenu(_ match: ElementFinder.Match, ref: Scenario.ElementRef) -> Outcome {
            guard let window = match.view.window else { return Outcome(.failed, "\(ref) is in no window") }
            let point = MouseEvents.center(of: match.view)
            guard let event = MouseEvents.event(.rightMouseDown, at: point, in: window) else {
                return Outcome(.failed, "could not make the mouse event")
            }
            var view: NSView? = window.contentView?.superview?.hitTest(point) ?? match.view
            var menu: NSMenu?
            while let candidate = view, menu == nil {
                menu = candidate.menu(for: event)
                view = candidate.superview
            }
            guard let menu else { return Outcome(.unsupported, "no context menu on \(ref)") }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.delegate?.menuDidClose?(menu)
            let titles = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
            return Outcome(
                .partial, "menu found, not shown (a native menu isn't captured): \(titles.joined(separator: ", "))")
        }

        // MARK: Dialogs

        /// Waits up to 5 s for the named sheet, alert or panel.
        func expectSheet(_ name: String, window: NSWindow) async -> Outcome {
            guard let identifier = elements?.identifiers[name] else {
                return Outcome(.failed, "unknown element \"\(name)\"")
            }
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                if !ElementFinder.all(identifier: identifier, text: nil, in: window).isEmpty { return Outcome(.ok) }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return Outcome(.failed, "no \(name) shown")
        }

        // MARK: Windows and tabs

        func newTab(window: NSWindow) -> Outcome {
            guard let controller = currentController else { return Outcome(.failed, "no explorer window") }
            let before = Set((window.tabbedWindows ?? [window]).map(ObjectIdentifier.init))
            controller.newWindowForTab(nil)
            let added = (window.tabbedWindows ?? []).first { !before.contains(ObjectIdentifier($0)) }
            guard let added else { return Outcome(.failed, "no tab was added") }
            current = added
            return Outcome(.ok)
        }

        func selectTab(_ index: Int, window: NSWindow) -> Outcome {
            let tabs = window.tabGroup?.windows ?? [window]
            guard tabs.indices.contains(index) else { return Outcome(.failed, "no tab \(index) of \(tabs.count)") }
            let tab = tabs[index]
            window.tabGroup?.selectedWindow = tab
            tab.makeKeyAndOrderFront(nil)
            Self.windowPicked(tab)
            current = tab
            return Outcome(.ok)
        }

        /// With the app in the background a window picked doesn't become key, so what follows the key window (the window
        /// in front, which the menu's commands go to, and the state the menu shows) would stay on the one before: it is
        /// told as it is when the window does become key.
        static func windowPicked(_ window: NSWindow) {
            guard !window.isKeyWindow else { return }
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        }

        /// The `prefs` steps before the first step that needs the window, carried out before any of the steps, as if
        /// seeded before launch: the tree reveals the folder with them, at the size the window opens with. A `window`
        /// step among them comes after that, and leaves the tree where it stands. Answers what each did, by its step's
        /// index, for the run to report when it reaches that step.
        func seedPreferences() async -> [Int: Outcome] {
            guard let scenario else { return [:] }
            var outcomes: [Int: Outcome] = [:]
            var density = false
            seeding: for (offset, step) in scenario.steps.enumerated() {
                switch step {
                case .window: continue
                case .prefs(let prefs):
                    outcomes[offset] = await perform(step)
                    if prefs["density"] != nil { density = true }
                default: break seeding
                }
            }
            guard let sidebar = currentController?.sidebarController else { return outcomes }
            let deadline = ContinuousClock.now + .seconds(3)
            while !sidebar.selectedRowIsListed, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if density { sidebar.revealSelectionFromTheTop() }
            return outcomes
        }

        /// By title, any window (Settings, an alert); by index, the explorer windows in the order they
        /// opened, each counted once with its tabs. A window still opening (Open in New Window shows it once its
        /// folder is read) is waited for up to 5 s.
        func selectWindow(index: Int?, title: String?) async -> Outcome {
            let deadline = ContinuousClock.now + .seconds(5)
            var outcome = pickWindow(index: index, title: title)
            while case .failure = outcome, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                outcome = pickWindow(index: index, title: title)
            }
            switch outcome {
            case .failure(let failure): return Outcome(.failed, failure.message)
            case .success(let picked):
                picked.makeKeyAndOrderFront(nil)
                Self.windowPicked(picked)
                current = picked
                return Outcome(.ok)
            }
        }

        private func pickWindow(index: Int?, title: String?) -> Result<NSWindow, Failure> {
            let visible = NSApp.windows.filter(\.isVisible)
            var picked: NSWindow?
            if let title {
                picked = visible.first { $0.title == title }
                guard picked != nil else { return .failure(.init("no window titled “\(title)”")) }
            }
            guard let index else { return picked.map { .success($0) } ?? .failure(.init("no window picked")) }
            let explorers = Self.explorerWindows()
            guard explorers.indices.contains(index) else {
                return .failure(.init("no window \(index) of \(explorers.count)"))
            }
            if let picked, picked !== explorers[index] {
                return .failure(.init("window \(index) is not titled “\(title ?? "")”"))
            }
            return .success(explorers[index])
        }

        /// The explorer windows on screen in the order they opened, each counted once with its tabs (the tab in
        /// front stands for it). The tab groups are told apart by the tabs they hold: each window has a tab group
        /// object of its own until it is shown in a tab bar.
        static func explorerWindows() -> [NSWindow] {
            let tabs = NSApp.windows.filter { $0.isVisible && $0.windowController is MainWindowController }
            var groups: [[NSWindow]] = []
            for window in tabs {
                let members = window.tabbedWindows ?? [window]
                if groups.contains(where: { group in group.contains { members.contains($0) } }) { continue }
                groups.append(members)
            }
            return
                groups
                .map { members in
                    let front = members.first?.tabGroup?.selectedWindow
                    let shown = front.flatMap { selected in members.first { $0 === selected } } ?? members[0]
                    // The order the window opened in: its oldest tab's number.
                    return (shown, members.map(\.windowNumber).min() ?? shown.windowNumber)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
    }

    extension AutomationRunner {
        /// Scrolls the folder's view by `distance` points over `milliseconds`, a step each frame at 120 Hz (sideways in the
        /// Compact List), and says how long the main thread took over each frame: the scroll, the layout of the items it
        /// brings in, their drawing and the commit. It moves the clip view itself, so it times the main thread's part of
        /// scrolling, which a trackpad's responsive scrolling would otherwise hide.
        func scroll(by distance: Double, milliseconds: Int, window: NSWindow) async -> Outcome {
            let scrollView =
                Views.first(NSCollectionView.self, in: window.contentView)?.enclosingScrollView
                ?? Views.folderTable(in: window)?.enclosingScrollView
            guard let scrollView else { return Outcome(.failed, "no folder view to scroll") }
            let clip = scrollView.contentView
            let start = clip.bounds.origin
            let document = scrollView.documentView?.frame.size ?? .zero
            let maxX = max(0, document.width - clip.bounds.width)
            let maxY = max(0, document.height - clip.bounds.height)
            let sideways = (scrollView as? ItemGridScrollView)?.wheelScrollsSideways == true
            let frame = 1.0 / 120
            let count = max(1, Int(Double(milliseconds) / 1000 / frame))
            var times: [Double] = []
            for step in 1...count {
                let began = ContinuousClock.now
                let along = distance * Double(step) / Double(count)
                clip.scroll(
                    to: sideways
                        ? NSPoint(x: min(maxX, max(0, start.x + along)), y: start.y)
                        : NSPoint(x: start.x, y: min(maxY, max(0, start.y + along))))
                scrollView.reflectScrolledClipView(clip)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                times.append(Double((ContinuousClock.now - began).milliseconds))
                try? await Task.sleep(for: .milliseconds(Int(frame * 1000)))
            }
            let sorted = times.sorted()
            let late = times.filter { $0 > frame * 1000 }.count
            return Outcome(
                .ok,
                String(
                    format: "%d frames: median %.1f ms, slowest %.1f ms, %d over %.1f ms", count, sorted[count / 2],
                    sorted[count - 1], late, frame * 1000))
        }
    }
#endif
