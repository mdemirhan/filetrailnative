// Settings edits the app's preferences directly: every window hears each edit once, nothing comes back to be
// written again, and the file is written once for a burst of edits such as a color dragged in the color panel
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// A timer that runs when the test says so, keeping only the timers not cancelled.
private final class HandStateTimer: StateTimer, @unchecked Sendable {
    private var timers: [Int: (delay: Int, action: @Sendable () -> Void)] = [:]
    private var next = 0

    func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        next += 1
        let id = next
        timers[id] = (delay, action)
        return { [self] in timers[id] = nil }
    }

    var pending: [Int] { timers.keys.sorted().compactMap { timers[$0]?.delay } }

    func run() {
        for id in timers.keys.sorted() {
            timers.removeValue(forKey: id)?.action()
        }
    }
}

/// The disk, counting the state files written.
private final class CountingFileSystem: StateFileSystem, @unchecked Sendable {
    private let disk = DiskFileSystem()
    var writes = 0

    func exists(_ path: String) -> Bool { disk.exists(path) }
    func createDirectory(_ path: String) throws { try disk.createDirectory(path) }
    func read(_ path: String) throws -> Data { try disk.read(path) }
    func rename(_ from: String, _ to: String) throws { try disk.rename(from, to) }
    func write(_ path: String, _ contents: String) throws {
        if path.hasSuffix("app-state.json.tmp") { writes += 1 }
        try disk.write(path, contents)
    }
}

@MainActor
@Suite struct SettingsSharedPreferencesTests {
    @Test func aColorDraggedInThePanelIsWrittenOnceAndHeardOncePerColor() throws {
        _ = NSApplication.shared
        let folder = try TemporaryDirectory(prefix: "filetrail-settings-shared")
        defer { folder.remove() }
        let path = folder.path + "/app-state.json"
        let timer = HandStateTimer()
        let files = CountingFileSystem()
        let store = AppStateStore(filePath: path, defaultTheme: .light, fileSystem: files, timer: timer)
        var heard: [PreferencesChange] = []
        let pages = PageWindows(model: AppearanceModel(), preferences: { store.preferences() })
        pages.presentsWindows = false
        pages.settingsServices.missingApps = { _ in [] }
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil },
            onPreferencesChanged: { preferences, change in
                heard.append(change)
                pages.preferencesChanged(preferences, change)
            })
        pages.loadPreferences = { channel.preferences(for: nil) }
        pages.updatePreferences = { change in channel.update(from: nil) { $0.apply(change) } }
        pages.openSettings(tab: .general)
        let settings = try #require(pages.settingsWindow)
        SettingsTestKit.layout(settings)
        let colors = (0..<30).map { String(format: "#%02x3366", $0 * 8) }
        settings.openColorPicker = { _, picked in
            for color in colors { picked(color) }
        }
        let swatches = views("settings.accent", in: settings.settingsView).compactMap { $0 as? AccentSwatch }
        SettingsTestKit.click(swatches.last)

        // Each color reaches the app's preferences and every window once, and nothing is sent back.
        #expect(store.preferences().accent == colors.last)
        #expect(heard == colors.map { _ in PreferencesChange(keys: [.accent], senderID: nil) })
        #expect(settings.store.preferences.accent == colors.last)
        #expect(swatches.last?.customFill == RGBA(hex: colors.last ?? ""))
        // One write for the burst, a moment after the last color.
        #expect(timer.pending == [AppStateStore.promptSaveDelayMilliseconds])
        #expect(files.writes == 0)
        timer.run()
        #expect(files.writes == 1)
        let saved = try JSONNode.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(saved["preferences"]?["accent"] == .string(colors.last ?? ""))
        settings.close()
    }

    @Test func anEditMadeElsewhereIsShownAndNotWrittenBack() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        var heard = 0
        let pages = PageWindows(model: AppearanceModel(), preferences: { store.preferences() })
        pages.presentsWindows = false
        pages.settingsServices.missingApps = { _ in [] }
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil },
            onPreferencesChanged: { preferences, change in
                heard += 1
                pages.preferencesChanged(preferences, change)
            })
        pages.loadPreferences = { channel.preferences(for: nil) }
        pages.updatePreferences = { change in channel.update(from: nil) { $0.apply(change) } }
        pages.openSettings(tab: .general)
        let settings = try #require(pages.settingsWindow)
        SettingsTestKit.layout(settings)
        let marks = try SettingsTestKit.control("Mark copied and cut items", SettingsSwitch.self, in: settings)
        #expect(marks.isOn)

        channel.update(from: 4) { $0.markClipboardItems = false }
        #expect(!marks.isOn)
        #expect(heard == 1)
        // An edit here is one change, told once.
        marks.press()
        #expect(store.preferences().markClipboardItems)
        #expect(heard == 2)
        // A press that changes nothing changes nothing.
        settings.store.update { $0.markClipboardItems = true }
        #expect(heard == 2)
        settings.close()
    }
}
