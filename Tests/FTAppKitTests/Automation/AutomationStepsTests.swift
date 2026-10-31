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

    /// The scenario steps P0-10 added, the checked-in scenarios and elements, and the pieces of the runner
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
                  "name": "x", "features": ["F-808"], "behaviors": ["B-SEL-071"], "tier": ["wave", "final"],
                  "steps": [
                    { "step": "click", "element": "list row", "text": "Avatar.jsx", "count": 2, "modifiers": ["cmd"] },
                    { "step": "click", "element": "back button", "holdMs": 600 },
                    { "step": "click", "element": { "name": "tab", "index": 1 }, "button": "right" },
                    { "step": "pick", "element": "batch rename presets", "option": "Save as Preset…" },
                    { "step": "menu", "path": ["File", "New Folder"] },
                    { "step": "contextMenu", "element": "list row", "index": 2, "choose": "Rename" },
                    { "step": "contextMenu", "element": "list row", "choose": ["Open With", "TextEdit"] },
                    { "step": "drag", "from": { "name": "favorite row", "text": "docs" },
                      "to": { "name": "favorite row", "index": 0 }, "modifiers": ["option"], "toEdge": "top" },
                    { "step": "dragFiles", "files": ["out/a.txt"], "to": "search field", "refused": true },
                    { "step": "dragFiles", "files": ["out/a.txt", "out/b.txt"], "to": "content", "hold": true },
                    { "step": "expectSheet", "name": "review sheet" },
                    { "step": "sheetButton", "label": "Keep Both" },
                    { "step": "newWindow" }, { "step": "newTab" },
                    { "step": "selectTab", "index": 1 },
                    { "step": "selectWindow", "title": "Settings" },
                    { "step": "selectWindow", "index": 0 },
                    { "step": "fs", "op": "create", "path": "a/Copies", "directory": true },
                    { "step": "fs", "op": "write", "path": "a/b.txt", "contents": "more", "append": true },
                    { "step": "fs", "op": "rename", "path": "a/b.txt", "to": "a/c.txt" },
                    { "step": "fs", "op": "delete", "path": "a/c.txt" },
                    { "step": "fs", "op": "chmod", "path": "a", "mode": "755" },
                    { "step": "fs", "op": "lock", "path": "a", "locked": false },
                    { "step": "fs", "op": "touch", "path": "a" },
                    { "step": "expect", "element": { "name": "list row", "text": "a.txt" }, "visible": true },
                    { "step": "expect", "element": "cut list row", "count": 4 },
                    { "step": "expect", "element": "title", "text": "components" }
                  ]
                }
                """)
            #expect(scenario.features == ["F-808"])
            #expect(scenario.behaviors == ["B-SEL-071"])
            #expect(scenario.tiers == ["wave", "final"])
            typealias Ref = Scenario.ElementRef
            #expect(
                scenario.steps == [
                    .click(
                        Ref("list row", text: "Avatar.jsx"), button: .left, count: 2, modifiers: ["cmd"],
                        holdMilliseconds: 0),
                    .click(Ref("back button"), button: .left, count: 1, modifiers: [], holdMilliseconds: 600),
                    .click(Ref("tab", index: 1), button: .right, count: 1, modifiers: [], holdMilliseconds: 0),
                    .pick(Ref("batch rename presets"), option: "Save as Preset…"),
                    .menu(path: ["File", "New Folder"]),
                    .contextMenu(Ref("list row", index: 2), choose: ["Rename"]),
                    .contextMenu(Ref("list row"), choose: ["Open With", "TextEdit"]),
                    .drag(
                        from: Ref("favorite row", text: "docs"), to: Ref("favorite row", index: 0),
                        modifiers: ["option"], toEdge: .top),
                    .dragFiles(files: ["out/a.txt"], to: Ref("search field"), hold: false, refused: true),
                    .dragFiles(files: ["out/a.txt", "out/b.txt"], to: Ref("content"), hold: true, refused: false),
                    .expectSheet(name: "review sheet"),
                    .sheetButton(label: "Keep Both"),
                    .newWindow, .newTab,
                    .selectTab(index: 1),
                    .selectWindow(index: nil, title: "Settings"),
                    .selectWindow(index: 0, title: nil),
                    .fs(.create(path: "a/Copies", contents: "", directory: true)),
                    .fs(.write(path: "a/b.txt", contents: "more", append: true)),
                    .fs(.rename(path: "a/b.txt", to: "a/c.txt")),
                    .fs(.delete(path: "a/c.txt")),
                    .fs(.chmod(path: "a", mode: "755")),
                    .fs(.lock(path: "a", locked: false)),
                    .fs(.touch(path: "a")),
                    .expect(Ref("list row", text: "a.txt"), text: nil, visible: true, count: nil),
                    .expect(Ref("cut list row"), text: nil, visible: nil, count: 4),
                    .expect(Ref("title"), text: "components", visible: nil, count: nil),
                ])
            #expect(scenario.steps.map(\.kind).contains("selectWindow"))
        }

        @Test func rejectsBadNewSteps() {
            let bad = [
                #"{"step": "click"}"#,
                #"{"step": "click", "element": "x", "count": 4}"#,
                #"{"step": "click", "element": "x", "button": "middle"}"#,
                #"{"step": "click", "element": "x", "holdMs": 9000}"#,
                #"{"step": "pick", "element": "x"}"#,
                #"{"step": "menu", "path": []}"#,
                #"{"step": "contextMenu", "element": "x", "choose": 3}"#,
                #"{"step": "drag", "from": "a", "to": "b", "toEdge": "left"}"#,
                #"{"step": "dragFiles", "to": "x"}"#,
                #"{"step": "dragFiles", "files": [], "to": "x"}"#,
                #"{"step": "dragFiles", "files": ["a"]}"#,
                #"{"step": "dragFiles", "files": ["a"], "to": "x", "hold": true, "refused": true}"#,
                #"{"step": "selectWindow"}"#,
                #"{"step": "fs", "op": "chmod", "path": "a", "mode": "rwx"}"#,
                #"{"step": "fs", "op": "explode", "path": "a"}"#,
                #"{"step": "fs", "op": "rename", "path": "a"}"#,
                #"{"step": "expect", "element": "x"}"#,
            ]
            for step in bad {
                #expect(throws: Scenario.ParseError.self, "\(step)") {
                    try parse(#"{"name": "x", "steps": [\#(step)]}"#)
                }
            }
            #expect(throws: Scenario.ParseError.self) { try parse(#"{"name": "x", "tier": "wp", "steps": []}"#) }
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

        @Test func readsTheClockAsLocalTime() throws {
            let scenario = try parse(#"{"name": "x", "now": "2026-10-13T14:38:00", "steps": []}"#)
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: try #require(scenario.nowDate))
            #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute] == [2026, 10, 13, 14, 38])
        }

        @Test func elementsNameOneIdentifierEach() throws {
            let elements = try AutomationElements.load(Self.capture.appendingPathComponent("elements.json"))
            #expect(elements.identifiers["list row"] == "list.row")
            #expect(elements.identifiers["review sheet"] == "reviewSheet")
            #expect(throws: AutomationElements.LoadError.self) {
                try AutomationElements.parse(Data(#"{"elements": {"x": {"electron": {"selector": "a"}}}}"#.utf8))
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
            #expect(apply(["zoomPercent": .number(100), "accent": .string("#007AFF")]).status == .ok)
            let partial = apply(["includeHidden": .bool(true), "openItemLimit": .number(7)])
            #expect(partial.status == .partial)
            #expect(partial.message == "unsupported: includeHidden, openItemLimit")
            #expect(apply(["zoom": .number(1)]).status == .failed)
            #expect(apply(["theme": .string("sepia")]).status == .failed)

            #expect(!AutomationPrefs.hasHandler("openItemLimit"))
            AutomationPrefs.register("openItemLimit") { value, _ in
                (value.number ?? 0) >= 1 ? .applied : .failed("openItemLimit")
            }
            #expect(apply(["openItemLimit": .number(7)]).status == .ok)
            #expect(apply(["openItemLimit": .number(0)]).status == .failed)
        }

        // MARK: File changes

        @Test func changesOnlyTheScratchCopy() throws {
            try withTemporaryDirectory { folder in
                let root = folder.appending("Lighthouse")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let environment = ["FILETRAIL_SCENARIO_ROOT": root.path]
                let scenario = try parse(#"{"name": "x", "now": "2026-10-13T14:38:00", "steps": []}"#)
                func run(_ op: Scenario.FileOp) throws {
                    try AutomationFileOps.perform(op, scenario: scenario, environment: environment)
                }
                let fm = FileManager.default
                try run(.create(path: "Copies", contents: "", directory: true))
                try run(.create(path: "Copies/a.txt", contents: "alpha", directory: false))
                #expect(throws: AutomationFileOps.Failure.self) {
                    try run(.create(path: "Copies/a.txt", contents: "again", directory: false))
                }
                try run(.write(path: "Copies/a.txt", contents: "+", append: true))
                #expect(
                    try String(contentsOf: root.appendingPathComponent("Copies/a.txt"), encoding: .utf8) == "alpha+")
                let modified =
                    try fm.attributesOfItem(atPath: root.appendingPathComponent("Copies/a.txt").path)[
                        .modificationDate] as? Date
                #expect(modified == scenario.nowDate)
                try run(.rename(path: "Copies/a.txt", to: "Copies/b.txt"))
                #expect(fm.fileExists(atPath: root.appendingPathComponent("Copies/b.txt").path))
                try run(.chmod(path: "Copies/b.txt", mode: "600"))
                let mode =
                    try fm.attributesOfItem(atPath: root.appendingPathComponent("Copies/b.txt").path)[
                        .posixPermissions] as? Int
                #expect(mode == 0o600)
                try run(.lock(path: "Copies/b.txt", locked: true))
                #expect(
                    try fm.attributesOfItem(atPath: root.appendingPathComponent("Copies/b.txt").path)[.immutable]
                        as? Bool == true)
                try run(.lock(path: "Copies/b.txt", locked: false))
                try run(.touch(path: "Copies"))
                try run(.delete(path: "Copies/b.txt"))
                #expect(!fm.fileExists(atPath: root.appendingPathComponent("Copies/b.txt").path))
                #expect(throws: AutomationFileOps.Failure.self) { try run(.delete(path: "../outside")) }
                #expect(throws: AutomationFileOps.Failure.self) {
                    try AutomationFileOps.perform(.delete(path: "Copies"), scenario: scenario, environment: [:])
                }
            }
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

        @Test @MainActor func leavesOutWhatItsScrollViewHides() throws {
            _ = NSApplication.shared
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                backing: .buffered, defer: true)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
            scroll.documentView = document
            content.addSubview(scroll)
            // The clip view shows the document's bottom 100 points: a row at y 0 shows, one at y 300 is scrolled away.
            for (y, name) in [(0.0, "shown"), (300.0, "scrolled away")] {
                let row = NSTextField(labelWithString: name)
                row.frame = NSRect(x: 0, y: y, width: 100, height: 20)
                row.setAccessibilityIdentifier("tree.row")
                document.addSubview(row)
            }
            scroll.contentView.scroll(to: .zero)
            let rows = GeometryDump(window: window, name: "x").elements.filter { $0.id == "tree.row" }
            #expect(rows.map { $0.text?.string } == ["shown"])
            let all = GeometryDump(window: window, name: "x", allViews: true).elements.filter { $0.id == "tree.row" }
            #expect(all.count == 2)
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

        // B-CLIP-175: what the step plays goes to the view AppKit would ask, so it finds out whether a field takes files.
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

        // T-49bf3581 B-CLIP-175: a field being edited is where the drag goes, and it takes no files.
        @Test @MainActor func aFieldBeingEditedIsWhereAFileDragGoes() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let field = try #require(tab.searchField)
            let urls = [URL(fileURLWithPath: "/tmp/outside/a.txt")]

            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor())
            #expect(editor is FileRefusingFieldEditor)
            let name = String(describing: type(of: editor))
            let result = await AutomationDrag.playFiles(urls, over: field, refused: true, hold: false)
            #expect(result == .refused(by: name))
            #expect(field.stringValue.isEmpty)

            // A drop that gets there anyway types nothing.
            let info = AutomationDraggingInfo(urls: urls, location: .zero, window: window)
            defer { info.draggingPasteboard.releaseGlobally() }
            #expect(!editor.performDragOperation(info))
            #expect(field.stringValue.isEmpty)
            // Other drags it leaves alone.
            #expect(FileRefusingFieldEditor.carriesFiles(info.draggingPasteboard))
            info.draggingPasteboard.clearContents()
            info.draggingPasteboard.setString("typed", forType: .string)
            #expect(!FileRefusingFieldEditor.carriesFiles(info.draggingPasteboard))
            await harness.close()
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

        @Test func recordsExpectations() throws {
            var report = AutomationReport(scenario: "x")
            report.steps.append(
                .init(
                    index: 1, step: "expect", status: .ok, message: nil, milliseconds: 1,
                    check: .init(passed: false, detail: "title: text “a”, expected “b”")))
            report.steps.append(.init(index: 2, step: "expect", status: .ok, message: nil, milliseconds: 1))
            #expect(report.failedChecks == 1)
            #expect(report.failedCount == 0)
            let decoded = try JSONDecoder().decode(AutomationReport.self, from: report.encoded())
            #expect(decoded == report)
        }
    }
#endif
