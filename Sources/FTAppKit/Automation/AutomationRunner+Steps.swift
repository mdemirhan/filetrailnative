// Port of the element, dialog and window steps of tools/capture/electron/driver.ts; no TypeScript source.
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
            // resolved and not shown, as contextMenu does.
            // The app's own right-click menus (Back and Forward's history) are drawn in the window: the press is sent.
            if button == .right, let target = match.view.window,
                let pressed = target.contentView?.superview?.hitTest(MouseEvents.center(of: match.view)),
                pressed is ToolbarButton || pressed.superview is ToolbarButton,
                let event = MouseEvents.event(.rightMouseDown, at: MouseEvents.center(of: match.view), in: target)
            {
                target.sendEvent(event)
                return Outcome(.ok)
            }
            if button == .right { return contextMenu(match, choose: [], ref: ref) }
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

        /// Sets a pop-up button to the item titled `option` and sends its action, as choosing it does.
        func pick(_ ref: Scenario.ElementRef, option: String, window: NSWindow) -> Outcome {
            let match: ElementFinder.Match
            switch ElementFinder.find(ref, elements: elements, in: window) {
            case .failure(let failure): return Outcome(.failed, failure.message)
            case .success(let found): match = found
            }
            guard let popUp = Views.first(NSPopUpButton.self, in: match.view) else {
                return Outcome(.failed, "\(ref) is not a pop-up button")
            }
            popUp.menu?.update()
            guard let item = popUp.item(withTitle: option) else { return Outcome(.failed, "no option “\(option)”") }
            guard item.isEnabled else { return Outcome(.failed, "“\(option)” is disabled") }
            popUp.select(item)
            if let action = popUp.action {
                NSApp.sendAction(action, to: popUp.target, from: popUp)
            }
            return Outcome(.ok)
        }

        func contextMenu(_ ref: Scenario.ElementRef, choose: [String], window: NSWindow) -> Outcome {
            switch ElementFinder.find(ref, elements: elements, in: window) {
            case .failure(let failure): return Outcome(.failed, failure.message)
            case .success(let match): return contextMenu(match, choose: choose, ref: ref)
            }
        }

        /// The menu a right click on the element would show: asked of the view under its center and the
        /// views above it, as AppKit asks. The item chosen is carried out; with none, the menu is only
        /// found, since a native menu can't be drawn into the window's capture.
        private func contextMenu(_ match: ElementFinder.Match, choose: [String], ref: Scenario.ElementRef) -> Outcome {
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
            guard !choose.isEmpty else {
                menu.delegate?.menuDidClose?(menu)
                let titles = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
                return Outcome(
                    .partial, "menu found, not shown (a native menu isn't captured): \(titles.joined(separator: ", "))")
            }
            switch AutomationMenus.find(choose, in: menu) {
            case .failure(let failure):
                menu.delegate?.menuDidClose?(menu)
                return Outcome(.failed, failure.message)
            case .success(let (owner, item)):
                return AutomationMenus.perform(item, in: owner, window: window)
            }
        }

        func drag(
            from: Scenario.ElementRef, to: Scenario.ElementRef, modifiers names: [String], toEdge: Scenario.Edge?,
            window: NSWindow
        ) async -> Outcome {
            guard let modifiers = KeyEvents.modifiers(names) else {
                return Outcome(.failed, "unknown modifier in \(names)")
            }
            let source: ElementFinder.Match
            switch ElementFinder.find(from, elements: elements, in: window) {
            case .failure(let failure): return Outcome(.failed, "from: \(failure.message)")
            case .success(let found): source = found
            }
            // The target may be in another window (between windows): looked for in every window.
            var destination: ElementFinder.Match?
            var reason = "no \(to) on screen"
            for candidate in [window] + NSApp.orderedWindows where candidate.isVisible {
                switch ElementFinder.find(to, elements: elements, in: candidate) {
                case .success(let found): destination = found
                case .failure(let failure): reason = failure.message
                }
                if destination != nil { break }
            }
            guard let destination, let sourceWindow = source.view.window,
                let targetWindow = destination.view.window
            else { return Outcome(.failed, "to: \(reason)") }

            let start = MouseEvents.center(of: source.view)
            let center = MouseEvents.center(of: destination.view)
            let quarter = destination.view.convert(destination.view.bounds, to: nil).height / 4
            // Window coordinates grow upward: the top quarter is above the center.
            let shift: CGFloat = toEdge == .top ? quarter : toEdge == .bottom ? -quarter : 0
            let end = NSPoint(x: center.x, y: center.y + shift)
            if let (sourceView, dragSource) = AutomationDrag.nearest(AutomationDragSource.self, from: source.view),
                let (targetView, dropTarget) = AutomationDrag.nearest(AutomationDropTarget.self, from: destination.view)
            {
                let items = dragSource.automationDragItems(at: sourceView.convert(start, from: nil))
                guard !items.isEmpty else { return Outcome(.failed, "nothing to drag at \(from)") }
                let taken = dropTarget.automationDrop(
                    items, at: targetView.convert(end, from: nil), allowed: AutomationDrag.allowed(modifiers))
                let note = "drop handler called through the debug seam: a native drag session can't be driven"
                return taken ? Outcome(.ok, note) : Outcome(.failed, "the drop was refused (\(note))")
            }
            if AutomationDrag.startsDraggingSession(source.view) {
                return Outcome(.unsupported, "\(from) has no drag seam, and its drag session can't be driven")
            }
            guard sourceWindow === targetWindow else {
                return Outcome(.unsupported, "a drag between windows needs the drag seams")
            }
            let done = await MouseEvents.drag(from: start, to: end, in: sourceWindow, modifiers: modifiers)
            return done ? Outcome(.ok) : Outcome(.failed, "could not make the mouse events")
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

        /// Clicks the button titled `label` in the sheet, alert or panel in front, else in the window.
        func sheetButton(_ label: String, window: NSWindow) -> Outcome {
            let places = ElementFinder.windows(around: window).filter { $0 !== window } + [window]
            for place in places {
                let root = place.contentView?.superview ?? place.contentView
                let button = Views.first(NSButton.self, in: root) {
                    $0.title == label && $0.isEnabled && $0.window?.isVisible == true
                }
                if let button {
                    button.performClick(nil)
                    return Outcome(.ok)
                }
            }
            return Outcome(.failed, "no enabled button “\(label)”")
        }

        // MARK: Windows and tabs

        func newWindow() -> Outcome {
            guard let delegate = NSApp.delegate as? AppDelegate else { return Outcome(.failed, "no app delegate") }
            let folder = currentController?.folder ?? FileManager.default.homeDirectoryForCurrentUser
            guard let opened = delegate.openWindow(at: folder) else { return Outcome(.failed, "no window opened") }
            current = opened.window
            return Outcome(.ok)
        }

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
            current = tab
            return Outcome(.ok)
        }

        /// By title, any window (Settings, an alert); by index, the explorer windows in the order they
        /// opened, each counted once with its tabs.
        func selectWindow(index: Int?, title: String?) -> Outcome {
            let visible = NSApp.windows.filter(\.isVisible).sorted { $0.windowNumber < $1.windowNumber }
            var picked: NSWindow?
            if let title {
                picked = visible.first { $0.title == title }
                guard picked != nil else { return Outcome(.failed, "no window titled “\(title)”") }
            }
            if let index {
                var seen = Set<ObjectIdentifier>()
                var explorers: [NSWindow] = []
                for window in visible where window.windowController is MainWindowController {
                    let group = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
                    guard seen.insert(group).inserted else { continue }
                    explorers.append(window.tabGroup?.selectedWindow ?? window)
                }
                guard explorers.indices.contains(index) else {
                    return Outcome(.failed, "no window \(index) of \(explorers.count)")
                }
                if let picked, picked !== explorers[index] {
                    return Outcome(.failed, "window \(index) is not titled “\(title ?? "")”")
                }
                picked = explorers[index]
            }
            guard let picked else { return Outcome(.failed, "no window picked") }
            picked.makeKeyAndOrderFront(nil)
            current = picked
            return Outcome(.ok)
        }

        // MARK: Expectations

        /// A soft assertion: the step is ok when it could look, and the report records what it found.
        func expect(
            _ ref: Scenario.ElementRef, text: String?, visible: Bool?, count: Int?, window: NSWindow
        ) -> Outcome {
            guard let identifier = elements?.identifiers[ref.name] else {
                return Outcome(.failed, "unknown element \"\(ref.name)\"")
            }
            let matches = ElementFinder.all(identifier: identifier, text: ref.text, in: window)
            let picked = matches.indices.contains(ref.index ?? 0) ? matches[ref.index ?? 0] : nil
            var problems: [String] = []
            var found: [String] = []
            if let count {
                found.append("count \(matches.count)")
                if matches.count != count { problems.append("count \(matches.count), expected \(count)") }
            }
            if let visible {
                found.append(picked == nil ? "hidden" : "visible")
                if visible != (picked != nil) { problems.append(visible ? "not shown" : "shown") }
            }
            if let text {
                let actual = picked.map { ElementFinder.text(of: $0.view) }
                found.append("text “\(actual ?? "")”")
                if actual != text { problems.append(actual.map { "text “\($0)”, expected “\(text)”" } ?? "no \(ref)") }
            }
            let check = AutomationReport.Check(
                passed: problems.isEmpty,
                detail: problems.isEmpty
                    ? "\(ref): " + found.joined(separator: ", ") : "\(ref): " + problems.joined(separator: "; "))
            return Outcome(.ok, check: check)
        }
    }
#endif
