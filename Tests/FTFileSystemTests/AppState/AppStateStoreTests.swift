// Port of the I/O, save-tier and window cases of apps/desktop/src/main/appStateStore.test.ts
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct AppStateStoreTests {
    typealias Kit = StateTestKit

    /// A store whose timers run when the test says so, counting the writes it makes.
    struct Timed {
        let store: AppStateStore
        let path: String
        let timer = ManualTimer()
        let files = RecordingFileSystem()

        init(_ folder: String, contents: String? = nil) {
            path = Kit.statePath(folder)
            if let contents { try? contents.write(toFile: path, atomically: true, encoding: .utf8) }
            store = Kit.store(path, fileSystem: files, timer: timer)
        }
    }

    // T-6bdc54b6 F-011
    @Test func persistsThroughATempFileSoAFailedWriteKeepsThePreviousState() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            let store = Kit.store(path)
            store.updatePreferences(["favoritesExpanded": .bool(false), "locationsExpanded": .bool(false)])
            store.flush()
            let persisted = try String(contentsOfFile: path, encoding: .utf8)
            let saved = Kit.json(persisted)["preferences"]
            #expect(saved?["favoritesExpanded"] == .bool(false))
            #expect(saved?["locationsExpanded"] == .bool(false))
            #expect(Kit.store(path).preferences().locationsExpanded == false)
            #expect(!FileManager.default.fileExists(atPath: path + ".tmp"))
            // The file is JSON.stringify(state, null, 2) and a newline.
            #expect(persisted.hasPrefix("{\n  \"preferences\": {\n    \"theme\": \"dark\",\n"))
            #expect(persisted.hasSuffix("}\n"))

            let failures = Failures()
            let failing = RecordingFileSystem()
            failing.failWrites = RecordingFileSystem.Failure(message: "disk full")
            let failingStore = Kit.store(path, fileSystem: failing, onPersistError: { failures.add($0) })
            failingStore.updatePreferences(["favoritesExpanded": .bool(true)])
            failingStore.flush()

            #expect(failures.all as? [RecordingFileSystem.Failure] == [.init(message: "disk full")])
            #expect(failing.renamed == 0)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == persisted)
        }
    }

    // T-20da35cd F-011
    @Test func writesADeliberateChangePromptly() throws {
        try Kit.withFolder { folder in
            let t = Timed(folder)
            t.store.updatePreferences(["foldersFirst": .bool(false)])
            t.store.updatePreferences(["favoritesExpanded": .bool(false)])
            // A burst of changes is one write, a moment later.
            #expect(t.timer.pendingDelays == [150])
            t.timer.run()

            #expect(t.files.written.count == 1)
            #expect(Kit.readFile(t.path)["preferences"]?["foldersFirst"] == .bool(false))

            // Forgetting a folder Go To does not list changes nothing.
            t.store.forgetVisitedFolder("/Users/demo/gone")
            #expect(t.timer.pendingDelays == [])
            t.store.recordFolderVisit("/Users/demo/gone", kind: .stay, now: 1_000)
            t.store.forgetVisitedFolder("/Users/demo/gone")
            #expect(t.timer.pendingDelays == [150])
        }
    }

    // T-46ebfbd8 F-011
    @Test func keepsWhereTheUserIsForTheQuitTimeWrite() throws {
        try Kit.withFolder { folder in
            let t = Timed(folder)
            t.store.updatePreferences([
                "lastVisitedPath": .string("/Users/demo/work"), "treeRootPath": .string("/Users/demo"),
            ])
            t.store.recordFolderVisit("/Users/demo/work", kind: .goTo, now: 1_000)
            t.store.addExplorerWindow(
                id: "window-a", bounds: StoredWindowState(width: 800, height: 500, maximized: false),
                session: t.store.createWindowSession())
            t.store.setExplorerWindowBounds(
                "window-a", StoredWindowState(x: 10, y: 20, width: 900, height: 600, maximized: false))
            t.store.updatePreferences(["lastVisitedPath": .string("/Users/demo/music")])
            t.store.recordFolderVisit("/Users/demo/music", kind: .stay, now: 2_000)

            // Nothing is written while browsing; one long timer bounds what a crash can lose, and later navigation does
            // not push it back.
            #expect(t.files.written.isEmpty)
            #expect(t.timer.pendingDelays == [5 * 60 * 1000])

            t.store.flush()
            #expect(t.files.written == ["visited-folders.json", "app-state.json"])
            #expect(t.timer.pendingDelays == [])
            let saved = Kit.readFile(t.path)
            #expect(saved["preferences"]?["lastVisitedPath"] == .string("/Users/demo/music"))
            #expect(saved["windows"]?.array?.first?["bounds"]?["x"] == .number(10))
            #expect(saved["windows"]?.array?.first?["bounds"]?["width"] == .number(900))
            #expect(saved["visitedFolders"] == nil)
            let visits = Kit.readFile(folder + "/visited-folders.json")
            #expect(visits["folders"]?.array?.count == 2)

            // Nothing has changed since: quitting again writes nothing.
            t.store.flush()
            #expect(t.files.written.count == 2)
            // Nor does passing through a folder already known.
            t.store.recordFolderVisit("/Users/demo/work", kind: .passThrough, now: 2_500)
            #expect(t.timer.pendingDelays == [])

            // The long timer does write, for a session that stays open, and only what changed.
            t.store.recordFolderVisit("/Users/demo/work", kind: .stay, now: 3_000)
            t.timer.run()
            #expect(Array(t.files.written.dropFirst(2)) == ["visited-folders.json"])
        }
    }

    // T-15a224c9 F-011
    @Test func keepsTheOpenTabsForTheQuitTimeWriteButWritesTheSettingAtOnce() throws {
        try Kit.withFolder { folder in
            let t = Timed(folder)
            // Opening, switching and closing tabs is where the user is, not a setting.
            t.store.updatePreferences(["openTabs": Kit.tabs(["/Users/demo/work"]), "activeTabIndex": .number(0)])
            t.store.updatePreferences([
                "openTabs": Kit.tabs(["/Users/demo/work", "/Users/demo/music"]), "activeTabIndex": .number(1),
            ])
            #expect(t.files.written.isEmpty)
            #expect(t.timer.pendingDelays == [5 * 60 * 1000])

            // Nor are the view mode and sort order, which are those of the tab on screen.
            t.store.updatePreferences([
                "viewMode": .string("details"), "sortBy": .string("size"), "sortDirection": .string("desc"),
            ])
            t.store.updatePreferences([
                "searchResultsSortBy": .string("name"), "searchResultsSortDirection": .string("desc"),
            ])
            #expect(t.files.written.isEmpty)
            #expect(t.timer.pendingDelays == [5 * 60 * 1000])

            // The same tabs again are not a change.
            t.store.updatePreferences([
                "openTabs": Kit.tabs(["/Users/demo/work", "/Users/demo/music"]), "activeTabIndex": .number(1),
            ])
            t.store.flush()
            #expect(t.files.written.count == 1)
            let saved = Kit.readFile(t.path)["preferences"]
            #expect(
                saved?["openTabs"]?.array?.compactMap { $0["path"]?.string } == [
                    "/Users/demo/work", "/Users/demo/music",
                ])
            #expect(saved?["activeTabIndex"] == .number(1))
            #expect(saved?["viewMode"] == .string("details"))
            #expect(saved?["sortBy"] == .string("size"))
            #expect(saved?["sortDirection"] == .string("desc"))
            t.store.flush()
            #expect(t.files.written.count == 1)

            t.store.updatePreferences(["restoreSessionOnStartup": .bool(false)])
            #expect(t.timer.pendingDelays == [150])
            t.timer.run()
            #expect(t.files.written.count == 2)
        }
    }

    // T-1ddc673f F-011
    @Test func writesNavigationAlongWithTheNextDeliberateChangeAndNothingForNoChange() throws {
        try Kit.withFolder { folder in
            let t = Timed(folder)
            t.store.updatePreferences(["lastVisitedPath": .string("/Users/demo/work")])
            t.store.addExplorerWindow(id: "window-a", bounds: Kit.bounds, session: t.store.createWindowSession())
            t.store.updatePreferences(["foldersFirst": .bool(false)])
            // The prompt write takes the place of the long timer.
            #expect(t.timer.pendingDelays == [150])
            t.timer.run()

            #expect(t.files.written.count == 1)
            #expect(t.timer.pendingDelays == [])
            #expect(Kit.readFile(t.path)["preferences"]?["lastVisitedPath"] == .string("/Users/demo/work"))

            // The same values again, and the same window, are not changes.
            t.store.updatePreferences([
                "foldersFirst": .bool(false), "lastVisitedPath": .string("/Users/demo/work"),
            ])
            t.store.setExplorerWindowBounds("window-a", t.store.explorerWindows()[0].bounds)
            t.timer.run()
            t.store.flush()
            #expect(t.files.written.count == 1)
        }
    }

    // T-ace2e3ee F-026
    @Test func remembersTheFoldersThatAreOpenedAcrossRestarts() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            let store = Kit.store(path)
            #expect(store.folders().isEmpty)

            store.recordFolderVisit("/Users/demo/work", kind: .stay, now: 1_000)
            store.recordFolderVisit("/Users/demo/music", kind: .goTo, now: 2_000)
            store.recordFolderVisit("/Users/demo/work", kind: .goTo, now: 3_000)
            store.flush()

            let reloaded = Kit.store(path)
            let music = VisitedFolder(path: "/Users/demo/music", visits: [FolderVisit(at: 2_000, kind: .goTo)])
            #expect(
                reloaded.folders() == [
                    VisitedFolder(
                        path: "/Users/demo/work",
                        visits: [FolderVisit(at: 3_000, kind: .goTo), FolderVisit(at: 1_000, kind: .stay)]),
                    music,
                ])
            // Preferences and visits are saved together without disturbing each other.
            reloaded.updatePreferences(["viewMode": .string("details")])
            #expect(reloaded.forgetVisitedFolder("/Users/demo/work") == [music])
            reloaded.flush()
            let again = Kit.store(path)
            #expect(again.folders().map(\.path) == ["/Users/demo/music"])
            #expect(again.preferences().viewMode == .details)
            // The visited-folders file keeps one folder per line.
            let text = try String(contentsOfFile: folder + "/visited-folders.json", encoding: .utf8)
            #expect(text == "{\"folders\":[\n{\"path\":\"/Users/demo/music\",\"visits\":[[2000,\"goTo\"]]}\n]}\n")
        }
    }

    // T-6d50f244 F-011
    @Test func keepsEachWindowsTabsPanelsAndColumnWidthsToItself() throws {
        try Kit.withFolder { folder in
            let store = Kit.store(Kit.statePath(folder))
            store.addExplorerWindow(id: "window-b", bounds: Kit.bounds, session: store.createWindowSession())
            store.addExplorerWindow(id: "window-a", bounds: Kit.bounds, session: store.createWindowSession())
            let widths = store.preferences().detailColumnWidths

            var widened = widths
            widened.name = 410
            store.updateWindowPreferences(
                "window-a",
                [
                    "openTabs": Kit.tabs(["/Users/demo/work"]), "propertiesOpen": .bool(true),
                    "detailColumnWidths": try JSONNode.of(widened),
                    // Not a window's own: every window shares it.
                    "notificationsEnabled": .bool(false),
                ])

            let a = store.windowPreferences("window-a")
            let b = store.windowPreferences("window-b")
            #expect(a.openTabs.map(\.path) == ["/Users/demo/work"])
            #expect(a.propertiesOpen)
            #expect(a.detailColumnWidths.name == 410)
            #expect(b.openTabs.isEmpty)
            #expect(!b.propertiesOpen)
            #expect(b.detailColumnWidths.name == widths.name)
            #expect(!b.notificationsEnabled)
            // The app keeps the values set last, for a window that opens without its own.
            #expect(store.preferences().detailColumnWidths.name == 410)
            #expect(store.createWindowSession().propertiesOpen)
        }
    }

    // T-50f7477b F-011
    @Test func keepsTheWindowsFrontToBackAcrossARestartWithoutThoseClosed() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try #"{"preferences": {}, "windows": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            for id in ["window-c", "window-b", "window-a"] {
                store.addExplorerWindow(
                    id: id, bounds: Kit.bounds,
                    session: store.createWindowSession(overrides: ["openTabs": Kit.tabs(["/Users/demo/\(id)"])]))
            }
            store.setExplorerWindowOrder(["window-c", "window-a"])
            store.removeExplorerWindow("window-b")
            store.flush()

            let reloaded = Kit.store(path)
            #expect(reloaded.explorerWindows().map(\.id) == ["window-c", "window-a"])
            #expect(reloaded.windowPreferences("window-c").openTabs.first?.path == "/Users/demo/window-c")
        }
    }

    // T-51e0a908 F-011
    @Test func writesAWindowsPanelsAtOnceAndWhereItIsAtQuit() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try #"{"preferences": {}, "windows": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let timer = RecordingTimer()
            let store = Kit.store(path, timer: timer)
            store.addExplorerWindow(id: "window-a", bounds: Kit.bounds, session: store.createWindowSession())
            store.addExplorerWindow(id: "window-b", bounds: Kit.bounds, session: store.createWindowSession())
            #expect(timer.delays == [5 * 60 * 1000])
            timer.delays.removeAll()
            store.updateWindowPreferences("window-a", ["treeWidth": .number(333)])
            #expect(Set(timer.delays) == [150])
            timer.delays.removeAll()

            // The app already has this width (window A set it); window B's own changes, and is written promptly all the
            // same.
            store.updateWindowPreferences("window-b", ["treeWidth": .number(333)])
            #expect(timer.delays == [150])
        }
    }

    // T-c0f2b5e6 F-011
    @Test func remembersTheWindowClosedLastWithItsFrontTabAcrossARestart() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try #"{"preferences": {}, "windows": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            #expect(store.lastClosedWindow() == nil)
            let placed = StoredWindowState(x: 40, y: 60, width: 900, height: 600, maximized: false)
            store.addExplorerWindow(
                id: "window-a", bounds: placed,
                session: store.createWindowSession(overrides: [
                    "openTabs": Kit.tabs(["/Users/demo/work", "/Users/demo/music"]), "activeTabIndex": .number(1),
                    "propertiesOpen": .bool(true),
                ]))

            store.rememberClosedWindow("window-a")
            store.removeExplorerWindow("window-a")
            store.rememberClosedWindow("window-gone")
            store.flush()

            let reloaded = Kit.store(path)
            #expect(reloaded.explorerWindows().isEmpty)
            let lastClosed = reloaded.lastClosedWindow()
            #expect(lastClosed?.bounds == placed)
            #expect(lastClosed?.session.openTabs.map(\.path) == ["/Users/demo/music"])
            #expect(lastClosed?.session.activeTabIndex == 0)
            #expect(lastClosed?.session.propertiesOpen == true)
        }
    }

    // T-7b834aba F-011
    @Test func neverForgetsAWindowThatIsOpenHoweverManyAre() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try #"{"preferences": {}, "windows": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            for index in 0...AppStateReader.windowsLimit {
                store.addExplorerWindow(id: "window-\(index)", bounds: Kit.bounds, session: store.createWindowSession())
            }
            let ids = store.explorerWindows().map(\.id)
            #expect(ids.count == AppStateReader.windowsLimit + 1)
            // The window opened first, behind all the others, is still open.
            #expect(ids.last == "window-0")
        }
    }

    // T-bc1fb7c7 F-011
    @Test func takesAChangeFromAWindowItDoesntKnowAsTheAppsAlone() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try #"{"preferences": {}, "windows": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            store.addExplorerWindow(id: "window-a", bounds: Kit.bounds, session: store.createWindowSession())
            let before = store.explorerWindows()

            let preferences = store.updateWindowPreferences(
                "window-gone", ["treeWidth": .number(333), "openTabs": Kit.tabs(["/Users/demo/work"])])

            #expect(preferences.treeWidth == 333)
            #expect(store.preferences().openTabs.map(\.path) == ["/Users/demo/work"])
            #expect(store.explorerWindows() == before)
            #expect(store.windowPreferences("window-gone").treeWidth == 333)
        }
    }

    // T-c05abda2 F-011
    @Test func keepsRenameSettingsAndPresetsThatArentTheDefaultsAcrossARestart() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            let settings = Kit.json(
                """
                {"mode": "format", "find": "IMG_", "replaceWith": "Trip $1", "matchCase": true, "useRegex": true,
                 "addText": " (copy)", "addWhere": "before", "nameFormat": "date", "formatWhere": "before",
                 "customName": "Lisbon", "keepNames": true, "startAt": 0, "step": 10, "digits": "auto",
                 "separator": "", "dateSource": "taken", "dateFormat": "custom", "dateSeparator": ".",
                 "customDatePattern": "[Day] DD.MM.YYYY HH-mm-ss", "caseStyle": "title", "applyTo": "both",
                 "onConflict": "skip"}
                """)
            let presets = JSONNode.array([
                .object(["name": .string("Photos by date"), "settings": settings])
            ])
            let store = Kit.store(path)
            let changed = store.updatePreferences(["batchRenameSettings": settings, "batchRenamePresets": presets])
            store.flush()

            let reloaded = Kit.store(path).preferences()
            #expect(reloaded.batchRenameSettings == changed.batchRenameSettings)
            #expect(reloaded.batchRenamePresets == changed.batchRenamePresets)
        }
    }

    // T-85076d5a F-011
    // N/A T-85076d5a the zod schema check (appPreferencesSchema) has no counterpart; what remains is that a value the
    // sanitizers accepted is one they accept again. (A preset name cut to 80 characters can end in a space that the next
    // read trims, as in the original, so the value settles after one read back rather than none.)
    @Test func renameSettingsTheStoreHoldsAreStableUnderReSanitizing() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            var generator = SeededGenerator(seed: 1)
            for round in 0..<200 {
                let store = Kit.store(path + "-\(round % 3)")
                store.updatePreferences([
                    "batchRenameSettings": Self.garbageSettings(&generator),
                    "batchRenamePresets": Self.garbagePresets(&generator),
                ])
                store.flush()
                let reloaded = Kit.store(path + "-\(round % 3)").preferences()
                #expect(PreferencesSanitizer.apply([:], to: reloaded, defaults: reloaded) == reloaded)
            }
        }
    }

    // T-4842d062 F-011
    // N/A T-4842d062 the zod schema check has no counterpart; a damaged file reads back as preferences that are
    // themselves a fixed point of the sanitizer.
    @Test func renameSettingsOfADamagedFileReadBackAsPreferencesTheWindowAccepts() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            var generator = SeededGenerator(seed: 2)
            for seed in 1...50 {
                let damaged = JSONNode.object([
                    "preferences": .object([
                        "batchRenameSettings": Self.garbageSettings(&generator),
                        "batchRenamePresets": Self.garbagePresets(&generator),
                    ])
                ])
                try JSONEncoder().encode(damaged).write(to: URL(fileURLWithPath: path))
                let read = Kit.store(path).preferences()
                let again = PreferencesSanitizer.apply([:], to: read, defaults: read)
                #expect(PreferencesSanitizer.apply([:], to: again, defaults: again) == again, "seed \(seed)")
            }
        }
    }

    // MARK: Damaged values for the Rename sheet's settings

    struct SeededGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
        mutating func chance(_ probability: Double) -> Bool { Double(next() % 10_000) / 10_000 < probability }
        mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    }

    static func garbage(_ rng: inout SeededGenerator, depth: Int = 0) -> JSONNode {
        switch rng.next() % 8 {
        case 0: return .null
        case 1: return .bool(rng.chance(0.5))
        case 2: return .number(rng.pick([0, -1, 1, 2, 2.5, 5, 1e12, -1e12]))
        case 3:
            return .string(
                rng.pick(["", " ", "auto", "replace", "format", "date", "-", "_", String(repeating: "x", count: 300)]))
        // Not the original's 254 letters and an emoji: cut at 255 units that leaves half a pair, which a Swift String cannot hold.
        case 4: return .string(String(repeating: "a", count: 253) + "\u{1F600}")
        case 5: return depth < 2 ? .array([garbage(&rng, depth: depth + 1)]) : .array([])
        default: return depth < 2 ? .object(["value": garbage(&rng, depth: depth + 1)]) : .object([:])
        }
    }

    static func garbageSettings(_ rng: inout SeededGenerator) -> JSONNode {
        if rng.chance(0.1) { return garbage(&rng) }
        guard let defaults = BatchRenameSanitizers.defaultSettings.object else { return .null }
        var record: [String: JSONNode] = [:]
        for (key, value) in defaults where !rng.chance(0.2) {
            record[key] = rng.chance(0.3) ? value : garbage(&rng)
        }
        record["notASetting"] = garbage(&rng)
        return .object(record)
    }

    static func garbagePresets(_ rng: inout SeededGenerator) -> JSONNode {
        if rng.chance(0.1) { return garbage(&rng) }
        let names = ["", "   ", "Photos", "photos", " Photos ", String(repeating: "n", count: 79) + " tail", "x"]
        let count = Int(rng.next() % 60)
        return .array(
            (0..<count).map { index in
                if rng.chance(0.1) { return garbage(&rng) }
                let name =
                    rng.chance(0.8)
                    ? JSONNode.string(rng.pick(names) + (rng.chance(0.5) ? "\(index)" : "")) : garbage(&rng)
                return .object(["name": name, "settings": garbageSettings(&rng)])
            })
    }
}

/// Collects the errors a store reports.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []

    func add(_ error: any Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    var all: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}

/// A timer that only notes the delays asked for.
final class RecordingTimer: StateTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    var delays: [Int] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
        set {
            lock.lock()
            recorded = newValue
            lock.unlock()
        }
    }

    func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.lock()
        recorded.append(delay)
        lock.unlock()
        return {}
    }
}
