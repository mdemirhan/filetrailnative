// Checks the rule of apps/desktop/src/main/main.ts:424-445 (no acceptFirstMouse): the click that brings a window forward
// only brings it forward
import AppKit
import Testing

@testable import FTAppKit

/// A window that says it shows, whose keyboard is what a test says: macOS answers its asks late, or never.
private final class ForwardWindow: NSWindow {
    var saysKey = false
    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { saysKey }
}

@MainActor
@Suite struct FirstClickGateTests {
    @Test func aPressOnAWindowNotKeyOnlyBringsItForward() {
        #expect(FirstClickGate.bringsForward(pressedAt: 10, isKey: false, keyWindowIsItsOwn: false, cameForwardAt: 0))
    }

    // Its popover or other child has the keyboard: the press is for the window, as the original's in-window ones were.
    @Test func aPressWithTheWindowsOwnChildKeyGoesThrough() {
        #expect(!FirstClickGate.bringsForward(pressedAt: 10, isKey: false, keyWindowIsItsOwn: true, cameForwardAt: 0))
    }

    // The app in the background: the window is key again by the time the press gets here, and the press was made first.
    @Test func aPressMadeBeforeTheWindowCameForwardOnlyBringsItForward() {
        #expect(
            FirstClickGate.bringsForward(pressedAt: 10, isKey: true, keyWindowIsItsOwn: false, cameForwardAt: 10.01))
        #expect(
            !FirstClickGate.bringsForward(pressedAt: 10.02, isKey: true, keyWindowIsItsOwn: false, cameForwardAt: 10.01)
        )
        #expect(
            !FirstClickGate.bringsForward(pressedAt: 0, isKey: true, keyWindowIsItsOwn: false, cameForwardAt: 10.01))
    }

    // main.ts:424-445: no first click reaches the toolbar's search options, a view of the field and no control of its own.
    // The band's own room isn't in any item: it stays the frame's.
    @Test func theToolbarsSearchOptionsCountAsAToolbarControl() async throws {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        let field = tab.explorerToolbar.searchField
        #expect(FirstClickGate.isContent(field.optionsButton, of: window))
        #expect(FirstClickGate.isContent(field, of: window))
        #expect(!FirstClickGate.isContent(NSView(), of: window))
        await harness.close()
    }

    // A window never shown can't be clicked to bring it forward.
    @Test func aWindowNotOnScreenKeepsNothingBack() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let gate = FirstClickGate()
        let down = try #require(MouseEvents.event(.leftMouseDown, at: NSPoint(x: 50, y: 50), in: window))
        #expect(!gate.keepsBack(down, in: window))
    }

    private func forwardWindow() -> ForwardWindow {
        let window = ForwardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        return window
    }

    /// An event as the window server's, on the content of `window`.
    private func event(
        _ type: NSEvent.EventType, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, in window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Runs `body` with macOS answering nothing, and says how often it was asked for the app and for the window.
    private func unanswered(appIsActive: Bool = false, _ body: () -> Void) -> (activated: Int, madeKey: Int) {
        let saved = FirstClickGate.system
        defer { FirstClickGate.system = saved }
        var activated = 0
        var madeKey = 0
        FirstClickGate.system = FirstClickGate.System(
            appIsActive: { appIsActive }, activateApp: { activated += 1 }, makeKey: { _ in madeKey += 1 })
        body()
        return (activated, madeKey)
    }

    // A drop from Finder leaves Finder in front: making the window key doesn't bring the app, so a press kept back asks
    // for that too.
    @Test func aPressKeptBackAsksForTheAppWhenItIsntActive() {
        let window = forwardWindow()
        let gate = FirstClickGate()
        let asked = unanswered {
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
        }
        #expect(asked.activated == 1)
        #expect(asked.madeKey == 1)
    }

    @Test func aPressKeptBackAsksOnlyForTheWindowWhenTheAppIsActive() {
        let window = forwardWindow()
        let gate = FirstClickGate()
        let asked = unanswered(appIsActive: true) {
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
        }
        #expect(asked.activated == 0)
        #expect(asked.madeKey == 1)
    }

    // The freeze: macOS doesn't bring the window forward, and the app looks hung if every press is lost. One press, with
    // its drags and its release, stays back; every one after it reaches AppKit, and asks again.
    @Test func onlyOnePressIsKeptBackWhileTheWindowStaysNotKey() {
        let window = forwardWindow()
        let gate = FirstClickGate()
        let asked = unanswered {
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            #expect(gate.keepsBack(event(.leftMouseDragged, in: window), in: window))
            #expect(gate.keepsBack(event(.leftMouseUp, in: window), in: window))
            for _ in 0..<3 {
                #expect(!gate.keepsBack(event(.leftMouseDown, in: window), in: window))
                #expect(!gate.keepsBack(event(.leftMouseDragged, in: window), in: window))
                #expect(!gate.keepsBack(event(.leftMouseUp, in: window), in: window))
            }
        }
        #expect(asked.activated == 4)
        #expect(asked.madeKey == 4)
    }

    // Slow to come forward: two clicks made before it did, or during a stall on the main thread, come in once it has.
    // The first brought it; the second is a click on what it shows.
    @Test func onlyOnePressMadeBeforeTheWindowCameForwardIsKeptBack() {
        let window = forwardWindow()
        window.saysKey = true
        let gate = FirstClickGate()
        let before = ProcessInfo.processInfo.systemUptime - 1
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        _ = unanswered(appIsActive: true) {
            #expect(gate.keepsBack(event(.leftMouseDown, at: before, in: window), in: window))
            #expect(gate.keepsBack(event(.leftMouseUp, at: before, in: window), in: window))
            #expect(!gate.keepsBack(event(.leftMouseDown, at: before + 0.2, in: window), in: window))
            #expect(!gate.keepsBack(event(.leftMouseUp, at: before + 0.2, in: window), in: window))
        }
    }

    // What the gate is for stays: each time the window has lost the keyboard or the app the front, one click only brings
    // it forward again.
    @Test func aWindowThatLostTheKeyboardKeepsBackOnePressAgain() {
        let window = forwardWindow()
        let gate = FirstClickGate()
        _ = unanswered {
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            #expect(!gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            #expect(!gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
        }
    }

    // Another window losing the keyboard says nothing of this one, and a press kept in another says nothing either.
    @Test func eachWindowKeepsBackItsOwnPress() {
        let window = forwardWindow()
        let other = forwardWindow()
        let gate = FirstClickGate()
        let otherGate = FirstClickGate()
        _ = unanswered {
            #expect(gate.keepsBack(event(.leftMouseDown, in: window), in: window))
            #expect(otherGate.keepsBack(event(.leftMouseDown, in: other), in: other))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
            #expect(!gate.keepsBack(event(.leftMouseDown, in: window), in: window))
        }
    }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct FirstClickGUITests {
        // On screen, through the window's own event path: with another window in front, a press on a list row only brings
        // the window forward and the selection stays; the next press selects.
        @Test func theClickThatBringsAWindowForwardLeavesTheSelection() async throws {
            let harness = try ExplorerHarness()
            let (tab, list) = try await harness.openList()
            let window = try #require(tab.window)
            let table = try #require(list.table)
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            #expect(!window.isKeyWindow)
            let selection = tab.content.selection
            let row = table.convert(table.rect(ofRow: 1), to: nil)
            let point = NSPoint(x: row.midX, y: row.midY)
            // Event numbers as the window server's: a press of this process's own, in the background, is let through.
            let event = { (type: NSEvent.EventType, number: Int) in
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)
            }
            window.sendEvent(try #require(event(.leftMouseDown, 7)))
            window.sendEvent(try #require(event(.leftMouseUp, 7)))
            #expect(tab.content.selection == selection)
            if !NSApp.isActive {
                let plain = try #require(event(.leftMouseDown, 0))
                #expect(FirstClickGate().keepsBack(plain, in: window) == false)
            }
            await harness.close()
        }

        // On screen, through the window's own event path: macOS doesn't answer the first press, and the second still gets
        // to the row. The release is waiting for the table, which follows the mouse until it comes.
        @Test func theSecondClickSelectsWhenTheWindowDidntComeForward() async throws {
            let harness = try ExplorerHarness()
            let (tab, list) = try await harness.openList()
            let window = try #require(tab.window)
            let table = try #require(list.table)
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            let selection = tab.content.selection
            let row = table.convert(table.rect(ofRow: 1), to: nil)
            let point = NSPoint(x: row.midX, y: row.midY)
            let event = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)
            }
            let saved = FirstClickGate.system
            defer { FirstClickGate.system = saved }
            FirstClickGate.system = FirstClickGate.System(activateApp: {}, makeKey: { _ in })
            window.sendEvent(try #require(event(.leftMouseDown)))
            window.sendEvent(try #require(event(.leftMouseUp)))
            #expect(tab.content.selection == selection)
            NSApp.postEvent(try #require(event(.leftMouseUp)), atStart: false)
            window.sendEvent(try #require(event(.leftMouseDown)))
            #expect(tab.content.selection != selection)
            await harness.close()
        }

        // On screen, through the window's own event path: a press on the magnifier only brings the window forward, and the
        // options menu stays shut.
        @Test func theClickThatBringsAWindowForwardOpensNoSearchOptions() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            let field = tab.explorerToolbar.searchField
            var opened = 0
            field.onOptions = { _ in opened += 1 }
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            let magnifier = field.optionsButton
            let point = magnifier.convert(NSPoint(x: magnifier.bounds.midX, y: magnifier.bounds.midY), to: nil)
            #expect(window.contentView?.superview?.hitTest(point) === magnifier)
            let event = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)
            }
            window.sendEvent(try #require(event(.leftMouseDown)))
            window.sendEvent(try #require(event(.leftMouseUp)))
            #expect(opened == 0)
            await harness.close()
        }
    }
}
