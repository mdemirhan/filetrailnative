#if DEBUG
    import AppKit
    import FTTestSupport
    import Foundation
    import Testing

    @testable import FTAppKit

    /// A window that says it shows, never put on screen.
    private final class ShownWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    /// A view that takes files, answering as it is told.
    @MainActor
    private final class TakesFiles: NSView {
        var answer: NSDragOperation = .move
        var exits = 0
        var dropped: [String] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { answer }
        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { answer }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { exits += 1 }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            dropped = urls?.map(\.path) ?? []
            return true
        }
    }

    /// The scenario steps, the checked-in scenarios and elements, and the pieces of the runner
    /// that work without a running app.
    @Suite struct AutomationStepsTests {
        private static let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        private static let capture = repo.appendingPathComponent("tools/capture")

        private func parse(_ json: String) throws -> Scenario {
            try Scenario.parse(Data(json.utf8))
        }

        @Test func readsTheNewSteps() throws {
            let scenario = try parse(
                """
                {
                  "name": "x",
                  "steps": [
                    { "step": "click", "element": "list row", "text": "Avatar.jsx", "count": 2, "modifiers": ["cmd"] },
                    { "step": "click", "element": "back button", "holdMs": 600 },
                    { "step": "click", "element": { "name": "tab", "index": 1 }, "button": "right" },
                    { "step": "menu", "path": ["File", "New Folder"] },
                    { "step": "expectSheet", "name": "review sheet" },
                    { "step": "newTab" },
                    { "step": "selectTab", "index": 1 },
                    { "step": "selectWindow", "title": "Settings" },
                    { "step": "selectWindow", "index": 0 }
                  ]
                }
                """)
            typealias Ref = Scenario.ElementRef
            #expect(
                scenario.steps == [
                    .click(
                        Ref("list row", text: "Avatar.jsx"), button: .left, count: 2, modifiers: ["cmd"],
                        holdMilliseconds: 0),
                    .click(Ref("back button"), button: .left, count: 1, modifiers: [], holdMilliseconds: 600),
                    .click(Ref("tab", index: 1), button: .right, count: 1, modifiers: [], holdMilliseconds: 0),
                    .menu(path: ["File", "New Folder"]),
                    .expectSheet(name: "review sheet"),
                    .newTab,
                    .selectTab(index: 1),
                    .selectWindow(index: nil, title: "Settings"),
                    .selectWindow(index: 0, title: nil),
                ])
            #expect(scenario.steps.map(\.kind).contains("selectWindow"))
        }

        @Test func rejectsBadNewSteps() {
            let bad = [
                #"{"step": "click"}"#,
                #"{"step": "click", "element": "x", "count": 4}"#,
                #"{"step": "click", "element": "x", "button": "middle"}"#,
                #"{"step": "click", "element": "x", "holdMs": 9000}"#,
                #"{"step": "menu", "path": []}"#,
                #"{"step": "selectWindow"}"#,
            ]
            for step in bad {
                #expect(throws: Scenario.ParseError.self, "\(step)") {
                    try parse(#"{"name": "x", "steps": [\#(step)]}"#)
                }
            }
        }

        @Test func readsListAndObjectPreferences() throws {
            let scenario = try parse(
                #"{"name": "x", "steps": [{"step": "prefs", "prefs": {"detailColumns": {"created": true}, "favorites": [], "terminalApp": null}}]}"#
            )
            #expect(
                scenario.steps == [
                    .prefs([
                        "detailColumns": .object(["created": .bool(true)]), "favorites": .array([]),
                        "terminalApp": .null,
                    ])
                ])
        }

        @Test func elementsNameOneIdentifierEach() throws {
            let elements = try AutomationElements.load(Self.capture.appendingPathComponent("elements.json"))
            #expect(elements.identifiers["list row"] == "list.row")
            #expect(elements.identifiers["review sheet"] == "reviewSheet")
            #expect(throws: AutomationElements.LoadError.self) {
                try AutomationElements.parse(Data(#"{"elements": {"x": {"labelled": true}}}"#.utf8))
            }
            let scenario = Self.capture.appendingPathComponent("readme/search.json")
            #expect(AutomationElements.locate(near: scenario)?.lastPathComponent == "elements.json")
        }

        // MARK: Preferences

        @Test @MainActor func reportsPreferencesKeyByKey() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                backing: .buffered, defer: true)
            func apply(_ prefs: [String: Scenario.PrefValue]) -> AutomationRunner.Outcome {
                AutomationPrefs.apply(prefs, context: .init(controller: nil, window: window, prefs: prefs))
            }
            #expect(apply(["accent": .string("#007AFF")]).status == .ok)
            let partial = apply(["includeHidden": .bool(true), "openItemLimit": .number(7)])
            #expect(partial.status == .partial)
            #expect(partial.message == "unsupported: includeHidden, openItemLimit")
            #expect(apply(["zoom": .number(1)]).status == .failed)
            #expect(apply(["theme": .string("sepia")]).status == .failed)

            #expect(!AutomationPrefs.hasHandler(.openItemLimit))
            AutomationPrefs.register(.openItemLimit) { value, _ in
                (value.number ?? 0) >= 1 ? .applied : .failed("openItemLimit")
            }
            defer { AutomationPrefs.unregister(.openItemLimit) }
            #expect(apply(["openItemLimit": .number(7)]).status == .ok)
            #expect(apply(["openItemLimit": .number(0)]).status == .failed)
        }

        // MARK: Menus, elements, events

        @MainActor private final class Target: NSObject, NSMenuItemValidation {
            var chosen: [String] = []
            var enabled = true
            @objc func newFolder(_ sender: Any?) { chosen.append("newFolder") }
            func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
        }

        @Test @MainActor func choosesMenuItemsByTitle() throws {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                backing: .buffered, defer: true)
            let target = Target()
            let bar = NSMenu()
            let file = NSMenu(title: "File")
            bar.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
            let item = file.addItem(
                withTitle: "New Folder…", action: #selector(Target.newFolder(_:)), keyEquivalent: "")
            item.target = target

            guard case .success(let (menu, found)) = AutomationMenus.find(["File", "New Folder"], in: bar) else {
                Issue.record("no New Folder")
                return
            }
            #expect(found === item)
            #expect(AutomationMenus.perform(found, in: menu, window: window).status == .ok)
            #expect(target.chosen == ["newFolder"])
            target.enabled = false
            #expect(AutomationMenus.perform(found, in: menu, window: window).message == "“New Folder…” is disabled")
            guard case .failure(let failure) = AutomationMenus.find(["File", "Rename"], in: bar) else {
                Issue.record("found Rename")
                return
            }
            #expect(failure.message == "no menu item File › Rename")
        }

        @Test @MainActor func findsElementsByNameTextAndPlace() throws {
            _ = NSApplication.shared
            // The finder looks only in windows that show: this one says it does, and stays off screen.
            let window = ShownWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            for (index, name) in ["b.txt", "a.txt"].enumerated() {
                let row = NSTextField(labelWithString: name)
                row.frame = NSRect(x: 10, y: 250 - 30 * Double(index), width: 100, height: 20)
                row.setAccessibilityIdentifier("list.row")
                content.addSubview(row)
            }
            let icon = NSButton(frame: NSRect(x: 300, y: 260, width: 20, height: 20))
            icon.setAccessibilityIdentifier("toolbar.back")
            icon.setAccessibilityLabel("Back")
            content.addSubview(icon)
            let below = NSTextField(labelWithString: "c.txt")
            below.frame = NSRect(x: 10, y: -15, width: 100, height: 20)
            below.setAccessibilityIdentifier("list.row")
            content.addSubview(below)

            let elements = AutomationElements(identifiers: ["list row": "list.row", "back button": "toolbar.back"])
            func found(_ ref: Scenario.ElementRef) -> String? {
                guard case .success(let match) = ElementFinder.find(ref, elements: elements, in: window) else {
                    return nil
                }
                return ElementFinder.text(of: match.view)
            }
            #expect(found(.init("list row")) == "b.txt")
            #expect(found(.init("list row", index: 1)) == "a.txt")
            #expect(found(.init("list row", text: "a.txt")) == "a.txt")
            #expect(found(.init("list row", index: 2)) == nil)
            #expect(found(.init("back button", text: "Back")) != nil)
            guard case .failure(let failure) = ElementFinder.find(.init("nope"), elements: elements, in: window) else {
                Issue.record("found an unknown element")
                return
            }
            #expect(failure.message == "unknown element \"nope\"")
        }

        @MainActor private final class OneRow: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 1 }
        }

        @Test @MainActor func tellsAPressOnEmptySpaceOfAList() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            window.contentView = content
            let table = NSTableView(frame: content.bounds)
            table.addTableColumn(NSTableColumn(identifier: .init("name")))
            table.rowHeight = 20
            let source = OneRow()
            table.dataSource = source
            content.addSubview(table)
            table.reloadData()
            // The table is flipped: its one row is at its top, the rest is empty space.
            let row = table.convert(table.rect(ofRow: 0), to: nil)
            #expect(!AutomationDrag.pressesNoItem(table, at: NSPoint(x: row.midX, y: row.midY)))
            #expect(AutomationDrag.pressesNoItem(table, at: NSPoint(x: 150, y: 50)))
            #expect(!AutomationDrag.pressesNoItem(content, at: NSPoint(x: 150, y: 50)))
        }

        // What the step plays goes to the view AppKit would ask, so it finds out whether a field takes files.
        @Test @MainActor func aFileDragGoesToTheViewAppKitWouldAsk() async throws {
            let window = ShownWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled],
                backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            window.contentView = content
            let urls = [URL(fileURLWithPath: "/tmp/outside/a.txt")]

            let plain = NSView(frame: NSRect(x: 0, y: 200, width: 300, height: 50))
            content.addSubview(plain)
            #expect(await AutomationDrag.playFiles(urls, over: plain, refused: true, hold: false) == .noDestination)

            let taker = TakesFiles(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            content.addSubview(taker)
            let name = "TakesFiles"
            #expect(await AutomationDrag.playFiles(urls, over: taker, refused: false, hold: true) == .offered(by: name))
            #expect(taker.dropped.isEmpty)
            #expect(taker.exits == 1)
            #expect(await AutomationDrag.playFiles(urls, over: taker, refused: true, hold: false) == .offered(by: name))
            let result = await AutomationDrag.playFiles(urls, over: taker, refused: false, hold: false)
            #expect(result == .dropped(by: name, taken: true))
            #expect(taker.dropped == ["/tmp/outside/a.txt"])

            // A view inside it asks it, as AppKit walks up from what is under the pointer.
            let label = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            taker.addSubview(label)
            #expect(await AutomationDrag.playFiles(urls, over: label, refused: true, hold: false) == .offered(by: name))

            taker.answer = []
            #expect(await AutomationDrag.playFiles(urls, over: taker, refused: true, hold: false) == .refused(by: name))
        }

        @Test @MainActor func makesClicksAndDragMasks() {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                backing: .buffered, defer: true)
            let pairs = MouseEvents.clicks(at: NSPoint(x: 10, y: 10), in: window, count: 2, modifiers: [.command])
            #expect(pairs.map(\.down.clickCount) == [1, 2])
            #expect(pairs.map(\.up.type) == [.leftMouseUp, .leftMouseUp])
            #expect(pairs.first?.down.modifierFlags.contains(.command) == true)
            #expect(AutomationDrag.allowed([.option]) == .copy)
            #expect(AutomationDrag.allowed([.command]) == .move)
            #expect(AutomationDrag.allowed([.option, .command]) == .link)
            #expect(AutomationDrag.allowed([]).contains(.generic))
        }
    }
#endif
