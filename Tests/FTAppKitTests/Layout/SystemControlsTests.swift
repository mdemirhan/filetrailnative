// D-020: the system's controls take clicks through the views that name their segments for captures, and the keys
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// Windowless: the window is made and never shown; events go straight to it.
@MainActor
@Suite(.serialized)
struct SystemControlsTests {
    private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    private final class ClickTarget: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private func hostWindow() -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 720, height: 240), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        window.contentView = host
        return (window, host)
    }

    /// A click on a segment as the system's tracking ends it: the segment under `mark` selected and the action sent.
    /// (Real presses go through the checkpoint's scenarios: posting mouse events here would end the test process's run
    /// loop.)
    private func click(_ mark: NSView, on control: SystemSegmentedControl, in window: NSWindow) throws {
        let point = MouseEvents.center(of: mark)
        let root = try #require(window.contentView?.superview)
        #expect(root.hitTest(root.convert(point, from: nil)) === control)
        control.focusByClick()
        control.selectedSegment = try #require(
            control.subviews.filter { $0.accessibilityIdentifier() == mark.accessibilityIdentifier() }
                .firstIndex { $0 === mark })
        control.sendAction(control.action, to: control.target)
    }

    // F-646 B-DLG-238: a click reaches each control where its mark says it is; the marks take none themselves.
    @Test func clicksReachTheSystemControlsThroughTheMarks() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let modes = BatchRenameModeControl()
        modes.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: modes.preferredSize)
        host.addSubview(modes)
        let conflicts = AllConflictsControl(choices: [.skip, .keepAll, .overwrite], value: .skip)
        conflicts.frame = NSRect(origin: NSPoint(x: 20, y: 60), size: conflicts.preferredSize)
        conflicts.onChange = { [weak conflicts] in conflicts?.value = $0 }
        host.addSubview(conflicts)
        let theSwitch = SettingsSwitch(label: "A switch", isOn: false, theme: AppearanceModel.shared.theme)
        theSwitch.frame = NSRect(origin: NSPoint(x: 20, y: 100), size: theSwitch.preferredSize)
        host.addSubview(theSwitch)
        var pressed = 0
        let plain = SystemButton(title: "Plain")
        let target = ClickTarget { pressed += 1 }
        plain.target = target
        plain.action = #selector(ClickTarget.fire)
        plain.frame = NSRect(x: 20, y: 130, width: plain.preferredWidth, height: 24)
        host.addSubview(plain)
        host.layoutSubtreeIfNeeded()

        let root = try #require(window.contentView?.superview)
        let format = try #require(modes.segments.first { $0.mode == .format })
        try click(format, on: modes, in: window)
        #expect(modes.selected == .format)
        #expect(window.firstResponder === modes)
        #expect(!modes.showsFocusRing)
        let replace = try #require(conflicts.segments.first { $0.choice == .overwrite })
        try click(replace, on: conflicts, in: window)
        #expect(conflicts.value == .overwrite)
        #expect(conflicts.selectedSegmentBezelColor == NSColor(AppearanceModel.shared.theme.palette.danger))
        #expect(root.hitTest(root.convert(MouseEvents.center(of: theSwitch), from: nil)) === theSwitch)
        #expect(root.hitTest(root.convert(MouseEvents.center(of: plain), from: nil)) === plain)
        theSwitch.press()
        #expect(theSwitch.isOn)
        plain.perform()
        #expect(pressed == 1)
    }

    // The arrows move the radio group's choice, wrapping, and Space takes the first while none is chosen.
    @Test func theArrowsMoveTheChoice() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let conflicts = AllConflictsControl(choices: [.skip, .keepAll, .overwrite], value: nil)
        conflicts.frame = NSRect(origin: NSPoint(x: 20, y: 60), size: conflicts.preferredSize)
        conflicts.onChange = { [weak conflicts] in conflicts?.value = $0 }
        host.addSubview(conflicts)
        #expect(window.makeFirstResponder(conflicts))
        func key(_ code: UInt16, _ text: String = "") throws {
            conflicts.keyDown(
                with: try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
        }
        #expect(conflicts.selectedSegment == -1)
        try key(49, " ")
        #expect(conflicts.value == .skip)
        try key(123)
        #expect(conflicts.value == .overwrite)
        try key(124)
        #expect(conflicts.value == .skip)
        #expect(conflicts.selectedSegment == 0)
    }

    /// Holds the keyboard, as the results do, and counts the keys it gets.
    private final class KeyboardOwner: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys += 1 }
    }

    private func arrowDown(_ window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
    }

    // F-750: a scope is a plain button of the pane: a click searches there and the keyboard stays with the results, so
    // the arrows move through them and never change the scope (SearchBar.tsx:57-71, useExplorerShortcuts.ts:878-915).
    @Test func aClickOnAScopeLeavesTheKeyboardWithTheResults() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let results = KeyboardOwner(frame: NSRect(x: 0, y: 100, width: 720, height: 100))
        host.addSubview(results)
        let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: 720, height: 60))
        host.addSubview(header)
        var changes: [String] = []
        header.onScopeChange = { changes.append($0) }
        header.show(
            scopes: [SearchScopeOption(path: "/a", label: "A"), SearchScopeOption(path: "/b", label: "B")],
            rootPath: "/a", isRunning: false, truncated: false, filterText: "")
        header.layoutSubtreeIfNeeded()
        let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })
        #expect(window.makeFirstResponder(results))
        #expect(!track.acceptsFirstResponder)
        #expect(!track.canBecomeKeyView)

        track.focusByClick()
        #expect(window.firstResponder === results)
        try #require(window.firstResponder).keyDown(with: try arrowDown(window))
        #expect(results.keys == 1)
        #expect(changes.isEmpty)
        #expect(track.selectedSegment == 0)

        // The click still chooses.
        track.selectedSegment = 1
        track.sendAction(track.action, to: track.target)
        #expect(changes == ["/b"])
        #expect(window.firstResponder === results)
    }

    private func key(_ code: UInt16, _ characters: String, shift: Bool = false, _ window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// The header with two scopes, in a window.
    private func shownHeader(
        window: NSWindow, host: NSView, isRunning: Bool = false
    ) -> SearchHeaderView {
        let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: 720, height: 60))
        host.addSubview(header)
        header.show(
            scopes: [SearchScopeOption(path: "/a", label: "A"), SearchScopeOption(path: "/b", label: "B")],
            rootPath: "/a", isRunning: isRunning, truncated: false, filterText: "")
        header.layoutSubtreeIfNeeded()
        return header
    }

    // F-750, SearchBar.tsx: only the filter is the browser's to Tab out of: to the next button, or back to the last scope.
    // There Return or Space presses it, and no arrow changes the scope.
    @Test func tabFromTheFilterReachesTheNextButtonAndTheLastScopeAndReturnPressesThem() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let header = shownHeader(window: window, host: host)
        var done = 0
        var scopes: [String] = []
        header.onDone = { done += 1 }
        header.onScopeChange = { scopes.append($0) }
        let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })

        #expect(window.makeFirstResponder(header.filter.input))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === header.doneButton)
        #expect(header.doneButton.showsFocusRing)
        header.doneButton.keyDown(with: try key(36, "\r", window))
        #expect(done == 1)

        #expect(window.makeFirstResponder(header.filter.input))
        let again = try #require(window.firstResponder as? NSTextView)
        again.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(window.firstResponder === track)
        #expect(track.keyboardSegment == 1)
        track.keyDown(with: try key(36, "\r", window))
        #expect(scopes == ["/b"])
        track.keyDown(with: try arrowDown(window))
        #expect(track.selectedSegment == 1)
        header.show(
            scopes: [SearchScopeOption(path: "/a", label: "A"), SearchScopeOption(path: "/b", label: "B")],
            rootPath: "/a", isRunning: false, truncated: false, filterText: "")
        track.keyDown(with: try key(49, " ", window))
        #expect(scopes == ["/b", "/b"])
    }

    // useExplorerShortcuts.ts:360-396: every button of the bar is in the content pane, where `paneTabSwitch` takes Tab and
    // Shift-Tab alike. The row is never walked: Tab can't step from scope to scope, nor from the ✕ to Done.
    @Test func tabFromAButtonOfTheBarSwitchesPanes() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let tree = KeyboardOwner(frame: NSRect(x: 0, y: 100, width: 720, height: 100))
        host.addSubview(tree)
        let header = shownHeader(window: window, host: host)
        var switches = 0
        header.onSwitchPane = {
            switches += 1
            window.makeFirstResponder(tree)
        }
        let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })
        header.stopButton.isHidden = false
        header.filter.text = "abc"

        func fromTheFilter(_ command: Selector) throws {
            #expect(window.makeFirstResponder(header.filter.input))
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.doCommand(by: command)
        }
        var expected = 0
        func expectSwitch(shift: Bool) throws {
            try #require(window.firstResponder).keyDown(with: try key(48, "\t", shift: shift, window))
            expected += 1
            #expect(switches == expected)
            #expect(window.firstResponder === tree)
        }

        // The ✕, not Done, comes after the filter; and the next Tab leaves the row.
        try fromTheFilter(#selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === header.filter.clearStop)
        try expectSwitch(shift: false)
        try fromTheFilter(#selector(NSResponder.insertTab(_:)))
        try expectSwitch(shift: true)

        // Stop follows the filter with no ✕.
        header.filter.text = ""
        try fromTheFilter(#selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === header.stopButton)
        try expectSwitch(shift: false)

        // Done, in either direction.
        header.stopButton.isHidden = true
        try fromTheFilter(#selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === header.doneButton)
        try expectSwitch(shift: false)
        try fromTheFilter(#selector(NSResponder.insertTab(_:)))
        try expectSwitch(shift: true)

        // A scope: the last is where the filter's Shift-Tab lands, the first where the toolbar's Tab does.
        try fromTheFilter(#selector(NSResponder.insertBacktab(_:)))
        #expect(window.firstResponder === track)
        try expectSwitch(shift: false)
        #expect(track.takeKeyboard())
        #expect(track.keyboardSegment == 0)
        try expectSwitch(shift: false)
        #expect(track.takeKeyboard())
        try expectSwitch(shift: true)
    }

    // The filter's ✕ is a stop while it shows; Return on it clears, and the keyboard goes back to the field.
    @Test func tabStopsAtTheFiltersClearButton() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let header = shownHeader(window: window, host: host)
        var changes: [String] = []
        header.onFilterChange = { changes.append($0) }
        header.filter.text = "abc"
        #expect(window.makeFirstResponder(header.filter.input))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(window.firstResponder === header.filter.clearStop)
        header.filter.clearStop.keyDown(with: try key(36, "\r", window))
        #expect(changes == [""])
        #expect(header.filter.isFocused)
    }

    // ContentPane.tsx:472-486: a press on a scope, Stop or Done gives the pane the keyboard, even from the filter.
    @Test func aPressInTheHeaderGivesThePaneTheKeyboard() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let results = KeyboardOwner(frame: NSRect(x: 0, y: 100, width: 720, height: 100))
        host.addSubview(results)
        let header = shownHeader(window: window, host: host)
        header.onFocusResults = { window.makeFirstResponder(results) }
        let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })
        let up = try #require(MouseEvents.event(.leftMouseUp, at: MouseEvents.center(of: track), in: window))
        NSApp.postEvent(up, atStart: false)
        #expect(window.makeFirstResponder(header.filter.input))
        let down = try #require(MouseEvents.event(.leftMouseDown, at: MouseEvents.center(of: track), in: window))
        track.mouseDown(with: down)
        #expect(window.firstResponder === results)
        // The queued release ended that press; this one is the button's.
        #expect(window.makeFirstResponder(header.filter.input))
        let doneUp = try #require(
            MouseEvents.event(.leftMouseUp, at: MouseEvents.center(of: header.doneButton), in: window))
        NSApp.postEvent(doneUp, atStart: false)
        header.doneButton.mouseDown(
            with: try #require(
                MouseEvents.event(.leftMouseDown, at: MouseEvents.center(of: header.doneButton), in: window)))
        #expect(window.firstResponder === results)
    }

    // SettingsView.tsx Toggle is a button: Return and Space both toggle it.
    @Test func returnAndSpaceToggleASettingsSwitch() throws {
        let (window, host) = hostWindow()
        defer { window.close() }
        let theSwitch = SettingsSwitch(label: "A switch", isOn: false, theme: AppearanceModel.shared.theme)
        host.addSubview(theSwitch)
        var changes: [Bool] = []
        theSwitch.onChange = { changes.append($0) }
        theSwitch.keyDown(with: try key(36, "\r", window))
        #expect(theSwitch.isOn)
        theSwitch.keyDown(with: try key(49, " ", window))
        #expect(!theSwitch.isOn)
        theSwitch.keyDown(with: try key(76, "\u{3}", window))
        #expect(theSwitch.isOn)
        #expect(changes == [true, false, true])
    }

    // F-750: Stop, Done and the card's Stop leave the keyboard where it is, as they did when drawn by hand; a dialog's
    // buttons still take it.
    @Test func theSearchBarsAndTheCardsButtonsDoNotTakeTheKeyboard() {
        _ = NSApplication.shared
        let stop = SmallPushButton(title: "Stop", theme: AppearanceModel.shared.theme, target: nil, action: nil)
        let done = SearchSmallButton(title: "Done", spinner: false)
        let searchStop = SearchSmallButton(title: "Stop", spinner: true)
        for button in [stop, done, searchStop] as [SystemButton] {
            #expect(!button.acceptsFirstResponder)
            #expect(!button.canBecomeKeyView)
        }
        let dialogButton = SystemButton(title: "OK")
        #expect(dialogButton.acceptsFirstResponder)
        #expect(dialogButton.canBecomeKeyView)
    }
}
