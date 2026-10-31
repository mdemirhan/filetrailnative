// Tab through a section of Settings (SettingsView.tsx:92-100, SettingsControls.tsx:20-24: native focusable elements), and
// the keys its recorder hears (ShortcutSettings.tsx:378, shortcuts.ts:763-790)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SettingsKeysTests {
    private typealias Kit = SettingsTestKit

    private func controls(in view: NSView) -> [NSView] {
        view.subviews.flatMap { subview -> [NSView] in
            if subview is SettingsSwitch || subview is SettingsPopup { return [subview] }
            return controls(in: subview)
        }
    }

    // The sections are built when they are chosen: Tab still goes on from a control of the one on screen.
    @Test(arguments: [SettingsTab.browsing, .search, .files])
    func tabMovesOnFromAControlAfterSwitchingSections(_ tab: SettingsTab) throws {
        let (controller, _) = Kit.make(tab: .general)
        controller.show(tab: tab)
        Kit.layout(controller)
        let window = try #require(controller.window)
        let page = try Kit.page(controller)
        let shown = controls(in: page)
        let first = try #require(shown.first)
        #expect(shown.count > 1)
        #expect(window.makeFirstResponder(first))
        window.selectNextKeyView(nil)
        #expect(window.firstResponder !== first)
        #expect(shown.contains { $0 === window.firstResponder })
        window.selectPreviousKeyView(nil)
        #expect(window.firstResponder === first)
    }

    @Test func tabMovesOnAfterComingBackToASection() throws {
        let (controller, _) = Kit.make(tab: .general)
        controller.show(tab: .files)
        controller.show(tab: .general)
        Kit.layout(controller)
        let window = try #require(controller.window)
        let shown = controls(in: try Kit.page(controller))
        let first = try #require(shown.first)
        #expect(window.makeFirstResponder(first))
        window.selectNextKeyView(nil)
        #expect(window.firstResponder !== first)
    }

    // ShortcutSettings.tsx:378: ⇧ and ⌥ with a digit or punctuation are answers, and so are F13 to F20.
    @Test(arguments: [
        (UInt16(18), CGEventFlags([.maskCommand, .maskShift]), "⇧⌘1"),
        (UInt16(18), CGEventFlags([.maskCommand, .maskAlternate]), "⌥⌘1"),
        (UInt16(43), CGEventFlags([.maskCommand, .maskAlternate]), "⌥⌘,"),
        (UInt16(41), CGEventFlags([.maskCommand, .maskShift]), "⇧⌘;"),
        (UInt16(105), CGEventFlags([]), "F13"),
    ])
    func recordsKeysWhoseCharacterAModifierChanges(_ code: UInt16, _ flags: CGEventFlags, _ shown: String) throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        let view = try #require(controller.settingsView.page?.shortcuts)
        let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
        place.perform()
        #expect(place.isRecording)
        #expect(place.record(try systemKeyEvent(code, flags)))
        #expect(!place.isRecording)
        #expect(view.slotView(ShortcutSlot(id: .newFolder, index: 1))?.stringValue == shown)
    }

    // A key macOS keeps says so, rather than the recorder waiting on.
    @Test func aReservedKeyWithADigitIsRefusedWithItsNote() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        let view = try #require(controller.settingsView.page?.shortcuts)
        let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
        place.perform()
        #expect(place.record(try systemKeyEvent(20, [.maskCommand, .maskShift])))
        #expect(view.row(.newFolder)?.noteText?.stringValue.contains("macOS") == true)
    }

    // MARK: The walk

    /// The view that has the keyboard: a number or search field's editor counts as its field.
    private func focused(_ window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSView { return field }
        return window.firstResponder as? NSView
    }

    /// Tab once, as the window does it.
    private func tab(_ window: NSWindow) {
        if let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSView {
            window.selectKeyView(following: field)
        } else {
            window.selectNextKeyView(nil)
        }
    }

    /// Every stop of one round of Tab, from the window's own view back to it.
    private func walk(_ controller: SettingsWindowController) throws -> [NSView] {
        let window = try #require(controller.window)
        #expect(window.makeFirstResponder(controller.settingsView))
        var stops: [NSView] = []
        for _ in 0..<400 {
            tab(window)
            let stop = try #require(focused(window))
            if stop === controller.settingsView { break }
            stops.append(stop)
        }
        return stops
    }

    // ShortcutSettings.tsx:326: Restore Default is there only for a row that is customized.
    @Test func tabNeverLandsOnAHiddenControl() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        Kit.layout(controller)
        let hidden = try walk(controller).filter(\.isHiddenOrHasHiddenAncestor).map { $0.accessibilityLabel() ?? "" }
        #expect(hidden.isEmpty, "hidden stops: \(hidden)")
    }

    @Test func tabLandsOnRestoreDefaultOnceTheRowIsCustomized() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        Kit.layout(controller)
        let view = try #require(controller.settingsView.page?.shortcuts)
        let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
        place.perform()
        #expect(place.record(try systemKeyEvent(105, [])))
        Kit.layout(controller)
        let labels = try walk(controller).compactMap { $0.accessibilityLabel() }
        #expect(labels.filter { $0.hasPrefix("Restore Default for") } == ["Restore Default for New Folder"])
    }

    // SettingsWindowApp.tsx:327-333: the sections are buttons, first in the page's order.
    @Test func tabReachesTheSectionsBeforeTheSectionOnScreen() throws {
        let (controller, _) = Kit.make(tab: .browsing)
        Kit.layout(controller)
        let sections = controller.settingsView.items
        #expect(sections.count == 5)
        let stops = try walk(controller)
        #expect(stops.count > sections.count)
        for (index, section) in sections.enumerated() {
            #expect(stops.indices.contains(index) && stops[index] === section)
        }
    }

    // The browser brings what the keyboard reached into view (SettingsView.tsx:92-100).
    @Test func tabScrollsTheControlIntoView() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        Kit.layout(controller)
        let window = try #require(controller.window)
        let clip = controller.settingsView.scroll.contentView
        #expect(window.makeFirstResponder(controller.settingsView))
        var moved = false
        for _ in 0..<80 {
            tab(window)
            let stop = try #require(focused(window))
            if clip.bounds.minY > 0 { moved = true }
            guard stop.isDescendant(of: clip) else { continue }
            let rect = stop.convert(stop.bounds, to: clip)
            #expect(clip.bounds.contains(rect), "\(stop.accessibilityLabel() ?? "") at \(rect) in \(clip.bounds)")
        }
        #expect(moved)
        #expect(controller.settingsView.isScrolled)
        // Back up the page as well.
        let top = try #require(try Kit.page(controller).shortcuts?.slotView(ShortcutSlot(id: .goBack, index: 0)))
        #expect(window.makeFirstResponder(top))
        #expect(clip.bounds.contains(top.convert(top.bounds, to: clip)))
    }

    // Blink's CenterIfNeeded: what shows stays, what is cut off comes to the near edge, what is out of sight is centered.
    @Test func theControlComesAsFarAsItNeeds() {
        let top: (CGFloat, CGFloat) -> CGFloat = { minY, height in
            SettingsView.revealedTop(
                of: NSRect(x: 0, y: minY, width: 10, height: height),
                in: NSRect(x: 0, y: 100, width: 10, height: 200), documentHeight: 1000)
        }
        #expect(top(120, 20) == 100)
        #expect(top(290, 20) == 110)
        #expect(top(90, 20) == 90)
        #expect(top(600, 20) == 510)
        #expect(top(10, 20) == 0)
        #expect(top(980, 20) == 800)
        #expect(top(250, 500) == 250)
    }

    // A press doesn't move the page: only the keyboard and code do.
    @Test func aPressDoesNotScroll() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        Kit.layout(controller)
        let shortcuts = try #require(controller.settingsView.page?.shortcuts)
        let far = try #require(shortcuts.slotView(ShortcutSlot(id: .duplicateTab, index: 0)))
        let clip = controller.settingsView.scroll.contentView
        controller.settingsView.reveal(far, for: .leftMouseDown)
        #expect(clip.bounds.minY == 0)
        controller.settingsView.reveal(far, for: .keyDown)
        #expect(clip.bounds.minY > 0)
    }

    @Test(arguments: [(" ", UInt16(49)), ("\r", UInt16(36)), ("\u{3}", UInt16(76))])
    func aKeyOnASectionChoosesIt(_ character: String, _ code: UInt16) throws {
        let (controller, _) = Kit.make(tab: .general)
        Kit.layout(controller)
        let window = try #require(controller.window)
        let section = try #require(controller.settingsView.items.first { $0.tab == .files })
        #expect(window.makeFirstResponder(section))
        section.keyDown(with: Kit.key(character, code: code, window: window))
        #expect(controller.activeTab == .files)
        #expect(window.firstResponder === section)
        window.selectNextKeyView(nil)
        #expect(window.firstResponder !== section)
    }

    // styles.css:4930: the ring comes and goes with the keyboard.
    @Test func aSectionShowsItHasTheKeyboard() throws {
        let (controller, _) = Kit.make(tab: .general)
        Kit.layout(controller)
        let window = try #require(controller.window)
        let section = try #require(controller.settingsView.items.first)
        #expect(window.makeFirstResponder(section))
        #expect(section.focusIsVisible)
        #expect(window.makeFirstResponder(controller.settingsView))
        #expect(!section.focusIsVisible)
    }
}
