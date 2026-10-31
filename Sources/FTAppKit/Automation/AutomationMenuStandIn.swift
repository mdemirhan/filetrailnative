// Port of the menu steps of tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import AppKit

    extension AppMenuPresenter {
        /// A scenario is being played (`AutomationRunner`).
        static var isPlayingScenario = false

        /// Not in a scenario run or a test process: a system menu's tracking loop would hold it up.
        static var tracksByDefault: Bool {
            !isPlayingScenario && !ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
                && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        }
    }

    /// An open system menu as a scenario sees it. A native menu's tracking loop would hold the run and its rows are not
    /// the app's views, so in a test or a scenario run the menu isn't shown: this clear view stands where it would be,
    /// with a clear view for each row carrying the names of `elements.json`. A click on one chooses that item, as the
    /// `contextMenu` step carries out an item of a right-click menu. A capture doesn't show it (a native menu isn't
    /// captured either).
    @MainActor
    final class AppMenuStandIn {
        private let view: AppMenuStandInView
        private weak var menu: AppMenu?

        var window: NSWindow? { view.window }

        init(menu: AppMenu, host: NSView, left: Double, top: Double) {
            self.menu = menu
            let size = menu.size
            view = AppMenuStandInView(
                frame: NSRect(
                    x: left, y: host.isFlipped ? top : host.bounds.height - top - size.height, width: size.width,
                    height: size.height))
            view.autoresizingMask = host.isFlipped ? [] : [.minYMargin]
            view.setAccessibilityIdentifier(menu.identifier)
            view.show(menu)
            host.addSubview(view)
            menu.onItemsChange = { [weak view, weak menu] in
                if let menu { view?.show(menu) }
            }
        }

        func contains(_ windowPoint: NSPoint) -> Bool {
            view.bounds.contains(view.convert(windowPoint, from: nil))
        }

        func remove() {
            menu?.onItemsChange = {}
            view.removeFromSuperview()
        }
    }

    final class AppMenuStandInView: NSView {
        override var isFlipped: Bool { true }

        /// One row for each item, from the top down.
        func show(_ menu: AppMenu) {
            for view in subviews { view.removeFromSuperview() }
            let rows = menu.items.enumerated().filter { $0.element.kind != .separator }
            let height = rows.isEmpty ? 0 : bounds.height / Double(rows.count)
            for (position, row) in rows.enumerated() {
                let (index, item) = row
                let view = AppMenuStandInRow(text: item.title)
                view.frame = NSRect(x: 0, y: Double(position) * height, width: bounds.width, height: height)
                if item.kind == .heading {
                    view.setAccessibilityIdentifier("menu.heading")
                } else {
                    view.setAccessibilityIdentifier(item.rowIdentifier ?? menu.rowIdentifier)
                    if item.enabled { view.onClick = { [weak menu] in menu?.onChoose(index) } }
                }
                if item.checked == true {
                    let tick = AppMenuStandInRow(text: item.title)
                    tick.frame = NSRect(x: 8, y: 0, width: 16, height: height)
                    tick.setAccessibilityIdentifier((item.rowIdentifier ?? menu.rowIdentifier) + ".checked")
                    tick.passesPresses = true
                    view.addSubview(tick)
                }
                addSubview(view)
            }
        }
    }

    final class AppMenuStandInRow: NSView, TextStyleSource {
        let label = NSTextField(labelWithString: "")
        var onClick: () -> Void = {}
        var passesPresses = false

        var styleTextField: NSTextField? { label }

        init(text: String) {
            super.init(frame: .zero)
            label.stringValue = text
            label.alphaValue = 0
            addSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel(text)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            label.frame = bounds
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            passesPresses ? nil : (frame.contains(point) ? self : nil)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}

        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
        }

        override func accessibilityPerformPress() -> Bool {
            onClick()
            return true
        }
    }
#endif
