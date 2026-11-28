// The names of a folder's views as a window on screen shows them, after a scroll: each drawn once, by the name itself,
// sharp. A text field that draws its own layer is given a label of AppKit's own on screen, and only there, which drew
// the name a second time, cut short its own way; a window that is never shown doesn't show it.
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
        tab.perform(.viewAsList)
        tab.content.compactListWidthChanged(160, save: false)
        let shown = await waitUntil {
            tab.content.entries.count == count && ScrollFrameTimes.folderScrollView(in: window) != nil
        }
        try #require(shown, "the Compact List didn't show the folder")

        // Scrolled along and back, then drawn.
        _ = await ScrollFrameTimes.measure(by: 6_000, milliseconds: 300, window: window)
        _ = await ScrollFrameTimes.measure(by: -3_000, milliseconds: 300, window: window)
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        // Those that show: AppKit keeps the items it may use again in the view, hidden.
        let names = ExplorerTestViews.all(CompactNameLabel.self, in: window.contentView).filter {
            !$0.isHiddenOrHasHiddenAncestor
        }
        #expect(names.count > 50)
        // Nothing of AppKit's draws the name a second time over it.
        let drawnTwice = names.filter { !$0.subviews.isEmpty || !($0.layer?.sublayers ?? []).isEmpty }
        #expect(drawnTwice.isEmpty, "\(drawnTwice.count) of \(names.count) names have something drawn over them")
        // Sharp: drawn at the screen's scale, and on whole pixels so the screen doesn't resample them.
        let scale = window.backingScaleFactor
        let blurred = names.filter { ($0.layer?.contentsScale ?? 0) != scale }
        #expect(blurred.isEmpty, "\(blurred.count) of \(names.count) names are drawn at another scale than \(scale)")
        // Within the folder's view, which the scroll moves as a whole.
        let folderView = try #require(ScrollFrameTimes.folderScrollView(in: window)?.documentView)
        let between = names.filter { name in
            let place = name.convert(name.bounds, to: folderView)
            let pixels = [place.minX, place.minY, place.width, place.height].map { $0 * scale }
            return pixels.contains { abs($0 - $0.rounded()) > 0.001 }
        }
        #expect(between.isEmpty, "\(between.count) of \(names.count) names are between pixels")
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
