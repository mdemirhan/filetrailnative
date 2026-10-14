import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// An explorer window that records the commands it is given. Its NSWindow is never shown.
@MainActor
final class FakeExplorerWindow: ExplorerWindowHandle {
    let windowID: Int
    let window: NSWindow?
    var isOnScreen = true
    private(set) var performed: [RendererCommand] = []

    init(id: Int) {
        windowID = id
        _ = NSApplication.shared
        window = makeOffscreenWindow()
    }

    func perform(_ command: RendererCommand) { performed.append(command) }
}

/// A window that is built but never ordered front.
@MainActor
func makeOffscreenWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
}

/// A host for the shell tests.
@MainActor
final class FakeWindowHost: ExplorerWindowHost {
    let list = ExplorerWindowList()
    var windows: any ExplorerWindowListing { list }
    private(set) var calls: [String] = []
    var takesFilesFromOtherApps = true

    func openStartupWindows(folder: String?) { calls.append("startup \(folder ?? "-")") }
    func openDefaultWindow(initialCommand: RendererCommand?) {
        calls.append("default \(initialCommand?.rawValue ?? "-")")
    }
    func openNewWindowFromFront() { calls.append("newWindowFromFront") }
    func bringToFront() { calls.append("bringToFront") }
    func openFromOtherApp(_ path: String) -> Bool {
        calls.append("fromOtherApp \(path)")
        return takesFilesFromOtherApps
    }
    func openWindowOnFolder(_ path: String) { calls.append("onFolder \(path)") }
}

/// The menu in the words of the original's tests: titles, with "-" for a separator.
@MainActor
func titles(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
}

@MainActor
func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
    guard let menu = main.items.first(where: { $0.title == title })?.submenu else {
        preconditionFailure("\(title) menu missing")
    }
    return menu
}

/// The first item with this title.
@MainActor
func item(_ menu: NSMenu, _ title: String) -> NSMenuItem {
    guard let found = menu.items.first(where: { $0.title == title }) else {
        preconditionFailure("\(title) menu item missing")
    }
    return found
}

/// An item's key written as Electron's accelerators are, "Command+Shift+N"; nil without one.
@MainActor
func accelerator(_ item: NSMenuItem) -> String? {
    guard !item.keyEquivalent.isEmpty else { return nil }
    var parts: [String] = []
    let modifiers = item.keyEquivalentModifierMask
    if modifiers.contains(.control) { parts.append("Control") }
    if modifiers.contains(.command) { parts.append("Command") }
    if modifiers.contains(.option) { parts.append("Alt") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    let names: [String: String] = [
        String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)): "Up",
        String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)): "Down",
        String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)): "Left",
        String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)): "Right",
        "\u{8}": "Backspace", "\t": "Tab", "\r": "Return", " ": "Space",
    ]
    let key = item.keyEquivalent
    parts.append(names[key] ?? key.uppercased())
    return parts.joined(separator: "+")
}

/// Every item of every menu, submenus included.
@MainActor
func flatten(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
}

/// Chooses the item as a click on it does.
@MainActor
func choose(_ item: NSMenuItem, _ router: MenuCommandRouter) {
    #expect(item.target === router)
    router.chooseMenuItem(item)
}
