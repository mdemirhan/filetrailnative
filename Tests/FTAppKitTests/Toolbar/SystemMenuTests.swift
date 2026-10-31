// Checks the app's menus as system menus (D-022): what their items say and do, not how they are drawn
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SystemMenuTests {
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aMenuHoldsAnItemForEachRow() throws {
        let key = try #require(MenuKeyEquivalent.parse("Cmd+Shift+G"))
        let menu = AppMenu(
            items: [
                .heading("Match"),
                AppMenuItem(title: "On", key: key, checked: true, tooltip: "/on"),
                .separator,
                AppMenuItem(title: "Off", checked: false),
                AppMenuItem(title: "Note", enabled: false),
                AppMenuItem(title: "App", appPath: "/System/Applications/TextEdit.app"),
            ], identifier: "menu", rowIdentifier: "menu.item", minWidth: 180)
        let items = menu.nsMenu.items
        #expect(items.map(\.title) == ["Match", "On", "", "Off", "Note", "App"])
        #expect(items[0].isSectionHeader)
        #expect(items[2].isSeparatorItem)
        #expect(items[1].state == .on && items[3].state == .off)
        #expect(items[1].keyEquivalent == "g" && items[1].keyEquivalentModifierMask == [.command, .shift])
        #expect(items[1].toolTip == "/on")
        #expect(items[1].isEnabled && !items[4].isEnabled)
        #expect(items[5].image != nil && items[1].image == nil)
        #expect(!menu.nsMenu.autoenablesItems)
        #expect(menu.nsMenu.minimumWidth == 180)
        #expect(menu.rows.map(\.title) == ["On", "Off", "Note", "App"])
    }

    // B-NAV-033: the history menu's folder comes after the name, smaller; a long name stops at 220.
    @Test func aRowsDetailFollowsItsNameAndLongTextIsCut() throws {
        let name = String(repeating: "long folder name ", count: 20)
        let menu = AppMenu(
            items: [AppMenuItem(title: name, detail: "~/some/where")], identifier: "historyMenu", rowIdentifier: "row",
            maxWidth: 420, nameMaxWidth: 220)
        let title = try #require(menu.nsMenu.items.first?.attributedTitle)
        #expect(title.string.contains("…"))
        #expect(title.string.hasSuffix("  ~/some/where"))
        let font = NSFont.menuFont(ofSize: 0)
        let cut = AppMenu.cut(name, font: font, width: 220)
        #expect(cut.hasSuffix("…") && cut.count < name.count)
        #expect((cut as NSString).size(withAttributes: [.font: font]).width <= 220)
        #expect(AppMenu.cut("short", font: font, width: 220) == "short")
    }

    @Test func choosingClosesTheMenuThenRunsTheItem() {
        let presenter = AppMenuPresenter()
        var events: [String] = []
        let menu = AppMenu(
            items: [AppMenuItem(title: "One", action: { events.append("chosen") })], identifier: "menu",
            rowIdentifier: "menu.item")
        let owner = NSView()
        presenter.show(menu, in: window(), at: NSPoint(x: 10, y: 10), owner: owner) { events.append("closed") }
        #expect(presenter.isOpen(from: owner))
        menu.onChoose(0)
        #expect(!presenter.isOpen)
        #expect(events == ["closed", "chosen"])
    }

    // What the system tells of a menu it closed: Escape or a press elsewhere.
    @Test func theSystemClosingTheMenuClosesItHere() {
        let presenter = AppMenuPresenter()
        var closed = 0
        let menu = AppMenu(items: [AppMenuItem(title: "One")], identifier: "menu", rowIdentifier: "menu.item")
        presenter.show(menu, in: window(), at: .zero, owner: nil) { closed += 1 }
        menu.menuDidClose(menu.nsMenu)
        #expect(!presenter.isOpen)
        #expect(closed == 1)
        menu.menuDidClose(menu.nsMenu)
        #expect(closed == 1)
    }

    // A scenario sees an open menu's rows by their names, and a click on one chooses it.
    @Test func aScenarioFindsAndClicksTheRows() throws {
        let presenter = AppMenuPresenter()
        let window = window()
        var chosen = false
        let menu = AppMenu(
            items: [
                .heading("Head"), AppMenuItem(title: "One", checked: true, action: { chosen = true }), .separator,
                AppMenuItem(title: "Two", enabled: false),
            ], identifier: "menu", rowIdentifier: "menu.item")
        presenter.show(menu, in: window, at: NSPoint(x: 10, y: 10), owner: nil)
        let root = try #require(window.contentView)
        #expect(views("menu", in: root).count == 1)
        #expect(views("menu.heading", in: root).first?.accessibilityLabel() == "Head")
        #expect(views("menu.item", in: root).compactMap { $0.accessibilityLabel() } == ["One", "Two"])
        #expect(views("menu.item.checked", in: root).compactMap { $0.accessibilityLabel() } == ["One"])
        // The rows follow the menu.
        menu.setItems(menu.items + [AppMenuItem(title: "Three")])
        #expect(views("menu.item", in: root).count == 3)
        // A disabled row does nothing.
        _ = views("menu.item", in: root)[1].accessibilityPerformPress()
        #expect(presenter.isOpen)
        _ = views("menu.item", in: root).first?.accessibilityPerformPress()
        #expect(chosen && !presenter.isOpen)
        #expect(views("menu", in: root).isEmpty)
    }

    @Test func escapeAndAPressElsewhereCloseTheStandIn() throws {
        let presenter = AppMenuPresenter()
        let window = window()
        let open = {
            presenter.show(
                AppMenu(items: [AppMenuItem(title: "One")], identifier: "menu", rowIdentifier: "row"), in: window,
                at: NSPoint(x: 10, y: 10), owner: nil)
        }
        open()
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        #expect(presenter.intercept(escape, in: window))
        #expect(!presenter.isOpen)
        open()
        let press = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 590, y: 5), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!presenter.intercept(press, in: window))
        #expect(!presenter.isOpen)
    }

    // Option swaps Open With to Always Open With while the menu is open.
    // B-INFO-061 T-8727f2e5
    @Test func optionChangesTheRowsOfAMenuThatAsks() {
        let menu = AppMenu(items: [AppMenuItem(title: "Zed")], identifier: "menu", rowIdentifier: "row")
        menu.watchOption(held: false) { held in
            held ? [.heading("Always Open With"), AppMenuItem(title: "Zed")] : [AppMenuItem(title: "Zed")]
        }
        menu.optionChanged(held: false)
        #expect(menu.nsMenu.items.count == 1)
        menu.optionChanged(held: true)
        #expect(menu.nsMenu.items.map(\.title) == ["Always Open With", "Zed"])
        menu.optionChanged(held: false)
        #expect(menu.nsMenu.items.map(\.title) == ["Zed"])
    }

    // The swap builds new rows: the row the keyboard or the pointer is on stays marked, counted without the heading and
    // the separators (`activeIndex` in PullDownMenu.tsx:32, 92), so Option+Return chooses it.
    @Test func optionKeepsTheHighlightedRowMarked() throws {
        let plain: [AppMenuItem] = [AppMenuItem(title: "Zed"), .separator, AppMenuItem(title: "Other…")]
        let menu = AppMenu(items: plain, identifier: "menu", rowIdentifier: "row")
        menu.watchOption(held: false) { held in held ? [.heading("Always Open With")] + plain : plain }
        menu.optionChanged(held: true, highlighted: menu.nsMenu.items[2])
        #expect(menu.markedIndex == 3)
        #expect(menu.nsMenu.items[3].title == "Other…")
        menu.optionChanged(held: false, highlighted: menu.nsMenu.items[1])
        #expect(menu.markedIndex == 0)
        // Nothing highlighted stays that way.
        menu.optionChanged(held: true, highlighted: nil)
        #expect(menu.markedIndex == nil)
    }

    private func views(_ identifier: String, in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.accessibilityIdentifier() == identifier { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }
}

/// The system's menu itself: it puts a menu on screen, so only with FILETRAIL_GUI_TESTS=1, under the GUI lock.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct SystemMenuTrackingGUITests {
    // While the system's menu is open the app goes on: an answer that comes in changes the rows, the keyboard's mark
    // shows, and closing it from the app ends its tracking.
    @Test func aTrackedMenuTakesNewRowsAndClosesFromTheApp() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let presenter = AppMenuPresenter()
        presenter.forcesTracking = true
        let menu = AppMenu(
            items: [AppMenuItem(title: "Loading…", enabled: false)], identifier: "menu", rowIdentifier: "row")
        var closed = false
        presenter.show(menu, in: window, at: NSPoint(x: 40, y: 40), owner: nil) { closed = true }
        #expect(await waitUntil { menu.isTracking })
        try await Task.sleep(for: .milliseconds(200))
        // This task runs while the menu tracks, as the folder menu's answer does.
        menu.markedIndex = 1
        menu.setItems([AppMenuItem(title: "One"), AppMenuItem(title: "Two")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.nsMenu.items.map(\.title) == ["One", "Two"])
        #expect(menu.nsMenu.highlightedItem?.title == "Two")
        presenter.close()
        #expect(closed)
        #expect(await waitUntil { !menu.isTracking })
        window.close()
    }

    // The swap of Option leaves the row that was highlighted highlighted, in the system's own menu.
    @Test func aTrackedMenuKeepsItsHighlightThroughTheOptionSwap() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let presenter = AppMenuPresenter()
        presenter.forcesTracking = true
        let plain = [AppMenuItem(title: "Zed"), AppMenuItem(title: "Other…")]
        let menu = AppMenu(items: plain, identifier: "menu", rowIdentifier: "row")
        menu.markedIndex = 1
        presenter.show(menu, in: window, at: NSPoint(x: 40, y: 40), owner: nil)
        #expect(await waitUntil { menu.isTracking })
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.nsMenu.highlightedItem?.title == "Other…")
        // Watched only from here: the app's timer would read the real key and swap back.
        menu.watchOption(held: false) { held in held ? [.heading("Always Open With")] + plain : plain }
        menu.optionChanged(held: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(menu.nsMenu.items.count == 3)
        #expect(menu.nsMenu.highlightedItem === menu.nsMenu.items[2])
        presenter.close()
        #expect(await waitUntil { !menu.isTracking })
        window.close()
    }

    // A menu that moves goes on being open: its closing for the move closes nothing, and it comes up again.
    @Test func aTrackedMenuMovesWithoutClosing() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let presenter = AppMenuPresenter()
        presenter.forcesTracking = true
        let menu = AppMenu(
            items: [AppMenuItem(title: "Loading…", enabled: false)], identifier: "menu", rowIdentifier: "row")
        var closed = false
        presenter.show(menu, in: window, at: NSPoint(x: 40, y: 200), owner: nil) { closed = true }
        #expect(await waitUntil { menu.isTracking })
        try await Task.sleep(for: .milliseconds(200))
        menu.setItems([AppMenuItem(title: "One"), AppMenuItem(title: "Two"), AppMenuItem(title: "Three")])
        presenter.move(to: NSPoint(x: 40, y: 100))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!closed && presenter.isOpen)
        #expect(presenter.place?.top == 100)
        #expect(menu.isTracking)
        presenter.close()
        #expect(closed)
        #expect(await waitUntil { !menu.isTracking })
        window.close()
    }
}
