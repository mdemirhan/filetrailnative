// The release's frame times: a real window on a folder of 3,000 files, each view scrolled at its default size and at its
// largest, the main thread's time over each frame measured as the scenario's `scroll` step measures it
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// One view at one size, as the release keeps it: the median of three scrolls for each number.
struct FrameTiming: Codable, Equatable {
    var view: String
    var size: String
    var medianMs: Double
    var lateShare: Double
    var slowestMs: Double
}

/// Puts a window on screen: only with FILETRAIL_GUI_TESTS=1, and with the fixture trees built. The results go to the
/// file FILETRAIL_FRAME_TIMINGS_OUT names, which scripts/release.sh reads.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct FrameTimeGUITests {
    private static let folder: URL = {
        let cache =
            ProcessInfo.processInfo.environment["FILETRAIL_DEV_CACHE"]
            ?? NSHomeDirectory() + "/Library/Caches/filetrail-dev"
        return URL(fileURLWithPath: cache).appendingPathComponent("fixtures/large/files-3000")
    }()

    /// How far each scroll goes, and over how long: 180 frames at 120 Hz.
    private static let distance = 4_000.0
    private static let milliseconds = 1_500
    private static let runs = 3

    private struct Setup {
        var view: String
        var size: String
        var command: AppCommand
        /// The icon size or the column width; nil for the List, which has none.
        var value: Double?
    }

    private static let setups = [
        Setup(view: "list", size: "default", command: .viewAsDetails, value: nil),
        Setup(view: "icons", size: "default", command: .viewAsIcons, value: 64),
        Setup(view: "icons", size: "largest", command: .viewAsIcons, value: 128),
        Setup(view: "compact", size: "default", command: .viewAsList, value: 292),
        Setup(view: "compact", size: "largest", command: .viewAsList, value: 600),
    ]

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @Test func scrollingEachViewTakesTheMainThreadSoLong() async throws {
        try #require(
            FileManager.default.fileExists(atPath: Self.folder.path), "the fixture trees aren't built")
        let state = try TemporaryDirectory.shallow(prefix: "filetrail-frame-times")
        defer { state.remove() }
        _ = NSApplication.shared
        TestServices.install()
        let store = AppStateStore(
            filePath: state.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
        let windows = ExplorerWindows(store: store, quit: QuitCoordinator())
        windows.openStartupWindows(folder: Self.folder.path)
        let tab = try #require(windows.front as? MainWindowController)
        let window = try #require(tab.window)
        #expect(await waitUntil { window.isVisible })
        window.setFrame(NSRect(x: 80, y: 80, width: 1_280, height: 800), display: true)
        defer { for tab in windows.allTabs { tab.window?.close() } }

        var timings: [FrameTiming] = []
        for setup in Self.setups {
            tab.perform(setup.command)
            if let value = setup.value {
                if setup.view == "icons" {
                    tab.content.iconSizeChanged(value, save: false)
                } else {
                    tab.content.compactListWidthChanged(value, save: false)
                }
            }
            let ready = await waitUntil {
                tab.content.entries.count == 3_000 && ScrollFrameTimes.folderScrollView(in: window) != nil
            }
            try #require(ready, "\(setup.view) at \(setup.size) didn't show the folder")
            var scrolls: [ScrollFrameTimes] = []
            for _ in 0..<Self.runs {
                tab.content.pane?.scrollPosition = (top: 0, left: 0)
                window.displayIfNeeded()
                let timed = try #require(
                    await ScrollFrameTimes.measure(by: Self.distance, milliseconds: Self.milliseconds, window: window))
                #expect(timed.count == 180)
                scrolls.append(timed)
            }
            timings.append(
                FrameTiming(
                    view: setup.view, size: setup.size, medianMs: Self.rounded(Self.median(scrolls.map(\.medianMs))),
                    lateShare: Self.rounded(Self.median(scrolls.map(\.lateShare)), places: 3),
                    slowestMs: Self.rounded(Self.median(scrolls.map(\.slowestMs)))))
        }
        #expect(timings.count == Self.setups.count)
        if let out = ProcessInfo.processInfo.environment["FILETRAIL_FRAME_TIMINGS_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["timings": timings]).write(to: URL(fileURLWithPath: out))
        }
    }

    private static func rounded(_ value: Double, places: Int = 2) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
