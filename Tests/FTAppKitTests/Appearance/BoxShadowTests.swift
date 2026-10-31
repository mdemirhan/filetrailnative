// Checks `box-shadow` and see-through text as apps/desktop/src/renderer/styles.css draws them, windowless
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct BoxShadowTests {
    final class Plain: NSView {
        var flips = false
        override var isFlipped: Bool { flips }
    }

    /// A view in a window that never comes on screen, in a host flipped or not, as the app's hosts are.
    private func window(hostFlipped: Bool, size: NSSize = NSSize(width: 300, height: 200)) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let host = Plain(frame: NSRect(origin: .zero, size: size))
        host.flips = hostFlipped
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.appearance = NSAppearance(named: .aqua)
        return (window, host)
    }

    /// The window as `tools/capture` takes it: the whole frame view. The gray at a point of `view`.
    private func gray(in window: NSWindow) throws -> (NSView, CGFloat, CGFloat) -> CGFloat {
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / frameView.bounds.width
        return { view, x, y in
            let point = view.convert(NSPoint(x: x, y: y), to: frameView)
            let color = rep.colorAt(x: Int(point.x * scale), y: Int((frameView.bounds.height - point.y) * scale))
            return color?.usingColorSpace(.sRGB)?.redComponent ?? 0
        }
    }

    final class Box: NSView {
        var flips = true
        override var isFlipped: Bool { flips }
        override func draw(_ dirtyRect: NSRect) {
            BoxShadow.draw(
                [ShadowLayer(x: 0, y: 6, blur: 8, color: RGBA(r: 0, g: 0, b: 0, alpha: 0.5))],
                around: bounds.insetBy(dx: 20, dy: 20), radius: 4)
        }
    }

    private func expectDown(_ view: NSView, in window: NSWindow) throws {
        let gray = try gray(in: window)
        // In the view's own coordinates: the edge at the bottom on screen is the largest y when it is flipped.
        let bottom = view.isFlipped ? view.bounds.maxY - 16 : CGFloat(16)
        let top = view.isFlipped ? CGFloat(16) : view.bounds.maxY - 16
        let below = gray(view, view.bounds.midX, bottom)
        let above = gray(view, view.bounds.midX, top)
        #expect(below < above - 0.08, "below \(below), above \(above)")
        // Not under the box.
        #expect(gray(view, view.bounds.midX, view.bounds.midY) == 1)
    }

    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func aDropFallsBelowItsBoxInEveryHost(hostFlipped: Bool, viewFlipped: Bool) throws {
        let (window, host) = window(hostFlipped: hostFlipped)
        let box = Box(frame: NSRect(x: 50, y: 50, width: 120, height: 90))
        box.flips = viewFlipped
        host.addSubview(box)
        try expectDown(box, in: window)
    }

    @Test func theDropStaysDownInALayerOfItsOwn() throws {
        let (window, host) = window(hostFlipped: true)
        let box = Box(frame: NSRect(x: 50, y: 50, width: 120, height: 90))
        box.wantsLayer = true
        host.addSubview(box)
        try expectDown(box, in: window)
    }

    // The bezel the pop-ups keep (`.push-button`'s): the edge lies outside, and its soft line falls under it (45). F-917
    @Test(arguments: [true, false])
    func aPushButtonsBezelFallsBelowIt(hostFlipped: Bool) throws {
        let (window, host) = window(hostFlipped: hostFlipped)
        let button = SettingsPopup(
            label: "Choice", options: [.init(value: "a", title: "Customize…")], value: "a",
            theme: AppearanceModel.shared.theme)
        button.frame = NSRect(x: 40, y: 40, width: 120, height: 24)
        host.addSubview(button)
        let gray = try gray(in: window)
        let above = gray(button, 60, -0.25)
        let below = gray(button, 60, 24.25)
        #expect(below < above, "below \(below), above \(above)")
        #expect(gray(button, -0.25, 12) < 1)
    }

    // AppKit's tab bar has no public type: its parts go by their class names.
    @Test func theTabBarsPartsGoByTheirNames() {
        #expect(!ExplorerTabGroup.isTabBarView(NSView()))
        #expect(!ExplorerTabGroup.isTabBarView(NSButton()))
    }
}
