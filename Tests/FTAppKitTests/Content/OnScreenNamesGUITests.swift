// The text of the folder's views as a window on screen shows it, after a scroll (the Compact List's and the Icons
// view's names, the List's cells): each drawn once, by itself, sharp. A text field that draws its own layer is given a
// label of AppKit's own on screen, and only there, which drew the name a second time, cut short its own way; a window
// that is never shown doesn't show it.
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// Puts a window on screen: only with FILETRAIL_GUI_TESTS=1, as a release runs it.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct OnScreenNamesGUITests {
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test func compactListNamesAreDrawnOnlyByThemselves() async throws {
        try await checkNames(.viewAsList, size: { $0.compactListWidthChanged(160, save: false) }, scroll: 6_000)
    }

    // AppKit places the Icons view's items a hair off the whole points their layout gives (a tenth of a pixel, in
    // rows spread by fractions of a point), so their names' layers aren't checked for whole pixels: measured, a name
    // there is as sharp as the text field it replaced.
    @Test func iconsViewNamesAreDrawnOnlyByThemselves() async throws {
        try await checkNames(
            .viewAsIcons, size: { $0.iconSizeChanged(32, save: false) }, scroll: 4_000, layersOnWholePixels: false)
    }

    @Test func listTextIsDrawnOnlyByItself() async throws {
        try await checkNames(.viewAsDetails, size: { _ in }, scroll: 4_000)
    }

    /// Opens a folder of 600 files in a view on screen, scrolls along and back, and checks each piece of text drawn as a
    /// picture that shows: nothing of AppKit's draws it a second time over it, and it is drawn at the screen's scale
    /// into a picture its size exactly.
    private func checkNames(
        _ view: AppCommand, size: (ContentPaneController) -> Void, scroll distance: Double,
        layersOnWholePixels: Bool = true
    ) async throws {
        let folder = try TemporaryDirectory.shallow(prefix: "filetrail-onscreen-names")
        defer { folder.remove() }
        let count = 600
        for index in 0..<count {
            let name = String(format: "A name long enough to be cut short %04d.txt", index)
            try Data().write(to: folder.appending(name))
        }
        let state = try TemporaryDirectory.shallow(prefix: "filetrail-onscreen-names-state")
        defer { state.remove() }
        _ = NSApplication.shared
        TestServices.install()
        let store = AppStateStore(
            filePath: state.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
        let windows = ExplorerWindows(store: store, quit: QuitCoordinator())
        windows.openStartupWindows(folder: folder.path)
        let tab = try #require(windows.front as? MainWindowController)
        let window = try #require(tab.window)
        defer { for tab in windows.allTabs { tab.window?.close() } }
        #expect(await waitUntil { window.isVisible })
        window.setFrame(NSRect(x: 80, y: 80, width: 1_000, height: 640), display: true)
        tab.perform(view)
        size(tab.content)
        let shown = await waitUntil {
            tab.content.entries.count == count && ScrollFrameTimes.folderScrollView(in: window) != nil
        }
        try #require(shown, "the view didn't show the folder")

        // Scrolled along and back, then drawn.
        _ = await ScrollFrameTimes.measure(by: distance, milliseconds: 300, window: window)
        _ = await ScrollFrameTimes.measure(by: -distance / 2, milliseconds: 300, window: window)
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        // Those that show: AppKit keeps the items and rows it may use again in the view, hidden.
        let names = ExplorerTestViews.all(PictureLabel.self, in: window.contentView).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0
        }
        #expect(names.count > 50)
        // Nothing of AppKit's draws the text a second time over it: no text field, nor a layer of its own that no view
        // of the app's put there (the Icons view's tag dots are a view of the app's).
        let drawnTwice = names.filter { name in
            let ownLayers = Set(name.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
            let foreign = (name.layer?.sublayers ?? []).filter { !ownLayers.contains(ObjectIdentifier($0)) }
            return name.subviews.contains { $0 is NSTextField } || !foreign.isEmpty
        }
        #expect(drawnTwice.isEmpty, "\(drawnTwice.count) of \(names.count) have something drawn over them")
        // Sharp: drawn at the screen's scale, each picture the view's size exactly (whole pixels wide and high), so the
        // screen doesn't stretch it, and its layer on whole pixels of the window, so the screen doesn't resample it.
        let scale = window.backingScaleFactor
        let blurred = names.filter { ($0.layer?.contentsScale ?? 0) != scale }
        #expect(blurred.isEmpty, "\(blurred.count) of \(names.count) are drawn at another scale than \(scale)")
        let stretched = names.filter { name in
            let size = [name.bounds.width, name.bounds.height].map { $0 * scale }
            guard size.allSatisfy({ abs($0 - $0.rounded()) <= 0.001 }) else { return true }
            // The picture is there, and exactly the view's size in pixels.
            guard let contents = name.layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
                return true
            }
            let picture = contents as! CGImage
            return picture.width != Int(size[0].rounded()) || picture.height != Int(size[1].rounded())
        }
        #expect(stretched.isEmpty, "\(stretched.count) of \(names.count) have no picture of their size in whole pixels")
        let root = try #require(window.contentView?.superview?.layer ?? window.contentView?.layer)
        let between = names.filter { name in
            guard layersOnWholePixels else { return false }
            guard let layer = name.layer else { return true }
            let place = layer.convert(layer.bounds, to: root)
            return [place.minX, place.minY].map { $0 * scale }.contains { abs($0 - $0.rounded()) > 0.001 }
        }
        #expect(between.isEmpty, "\(between.count) of \(names.count) have their layer between pixels")
    }
}

/// The views of a kind in a window's tree.
@MainActor
private enum ExplorerTestViews {
    static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += all(type, in: child) }
        return found
    }
}
