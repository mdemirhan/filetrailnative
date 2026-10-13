// Port of the step runner of tools/capture/electron/driver.ts, for this app; no TypeScript source.
#if DEBUG
    import AppKit
    import FTFoundation

    /// `FileTrail --automation <scenario.json> --out <dir>`: runs a capture scenario in the front window,
    /// waiting for each step to settle, writes `<out>/report.json`, and quits.
    @MainActor
    final class AutomationRunner {
        struct Options: Equatable, Sendable {
            var scenario: URL
            var out: URL
        }

        /// The `--automation` and `--out` values, or nil when automation wasn't asked for.
        nonisolated static func options(from arguments: [String]) -> Options? {
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                    return nil
                }
                return arguments[index + 1]
            }
            guard let scenario = value(after: "--automation") else { return nil }
            let out = value(after: "--out") ?? FileManager.default.currentDirectoryPath
            func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
            return Options(scenario: url(scenario), out: url(out))
        }

        /// Seconds a step may take before the run moves on without it.
        static let stepTimeout: Double = 30

        private let options: Options
        private let controller: () -> MainWindowController?
        private let report: ReportBox
        private var scenario: Scenario?
        private let watchdog = DispatchQueue(label: "filetrail.automation.watchdog")
        private var hardTimer: DispatchSourceTimer?

        init(options: Options, controller: @escaping () -> MainWindowController?) {
            self.options = options
            self.controller = controller
            let name = options.scenario.deletingPathExtension().lastPathComponent
            report = ReportBox(
                AutomationReport(scenario: name), file: options.out.appendingPathComponent("report.json"))
        }

        /// Reads the scenario before the window opens, so the window can open on its first folder.
        func load() -> Scenario? {
            do {
                try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
                let parsed = try Scenario.parse(Data(contentsOf: options.scenario))
                scenario = parsed
                report.update { $0.scenario = parsed.name }
                return parsed
            } catch {
                report.update { $0.error = "could not read the scenario: \(error)" }
                return nil
            }
        }

        /// The folder of the first `open` step, for the window to start on.
        var startFolder: URL? {
            guard let scenario else { return nil }
            for case .open(let path) in scenario.steps { return scenario.resolve(path) }
            return nil
        }

        func run() async {
            defer { finish() }
            guard let scenario else { return }
            await settle()
            for (offset, step) in scenario.steps.enumerated() {
                let started = ContinuousClock.now
                armHardWatchdog(index: offset + 1, step: step)
                let outcome = await runWithTimeout(step)
                hardTimer?.cancel()
                let elapsed = Int((ContinuousClock.now - started).milliseconds)
                report.update {
                    $0.steps.append(
                        .init(
                            index: offset + 1, step: step.kind, status: outcome.status, message: outcome.message,
                            milliseconds: elapsed))
                }
                report.write()
            }
        }

        private func finish() {
            report.write()
            let current = report.current
            FileHandle.standardError.write(
                Data(
                    "automation \(current.scenario): \(current.steps.count) steps, \(current.unsupportedCount) unsupported, \(current.failedCount) failed\n"
                        .utf8))
            NSApp.terminate(nil)
        }

        // MARK: Watchdogs

        private final class Once {
            private(set) var done = false
            func claim() -> Bool {
                defer { done = true }
                return !done
            }
        }

        /// Runs a step, settles, and gives up on it after `stepTimeout` (the step's task is left behind).
        private func runWithTimeout(_ step: Scenario.Step) async -> Outcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let once = Once()
                Task { @MainActor in
                    let outcome = await self.perform(step)
                    await self.settle()
                    if once.claim() { continuation.resume(returning: outcome) }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.stepTimeout))
                    if once.claim() {
                        continuation.resume(
                            returning: Outcome(.timeout, "did not finish within \(Int(Self.stepTimeout)) s"))
                    }
                }
            }
        }

        /// If the main thread itself hangs, a background timer writes the report and ends the process.
        private func armHardWatchdog(index: Int, step: Scenario.Step) {
            hardTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: watchdog)
            let report = report
            let kind = step.kind
            timer.schedule(deadline: .now() + Self.stepTimeout + 5)
            timer.setEventHandler {
                report.update {
                    $0.steps.append(
                        .init(
                            index: index, step: kind, status: .timeout, message: "the main thread stopped responding",
                            milliseconds: Int((Self.stepTimeout + 5) * 1000)))
                    $0.error = "stopped at step \(index): main thread hung"
                }
                report.write()
                exit(3)
            }
            timer.resume()
            hardTimer = timer
        }

        // MARK: Settling

        /// Waits until the window stops changing: navigation done, rows loaded, run loop idle.
        private func settle() async {
            let deadline = ContinuousClock.now + .seconds(5)
            var last = fingerprint()
            var stable = 0
            while stable < 3, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
                let current = fingerprint()
                if current == last {
                    stable += 1
                } else {
                    stable = 0
                    last = current
                }
            }
            guard let window = controller()?.window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        private func fingerprint() -> [String] {
            guard let controller = controller(), let window = controller.window else { return [] }
            let table = Views.folderTable(in: window)
            let collection = Views.first(NSCollectionView.self, in: window.contentView)
            return [
                controller.folder.path, window.title,
                String(describing: window.firstResponder.map(ObjectIdentifier.init)),
                "\(table?.numberOfRows ?? -1)", "\(table?.selectedRowIndexes.map { $0 } ?? [])",
                "\(collection?.numberOfItems(inSection: 0) ?? -1)", Views.statusText(in: window) ?? "",
                "\(window.contentView?.frame.size ?? .zero)",
            ]
        }

        // MARK: Steps

        struct Outcome {
            var status: AutomationReport.Status
            var message: String?

            init(_ status: AutomationReport.Status, _ message: String? = nil) {
                self.status = status
                self.message = message
            }
        }

        private func perform(_ step: Scenario.Step) async -> Outcome {
            guard let controller = controller(), let window = controller.window else {
                return Outcome(.failed, "no window")
            }
            switch step {
            case .window(let width, let height):
                window.setContentSize(NSSize(width: width, height: height))
                if let screen = window.screen ?? NSScreen.main,
                    !screen.visibleFrame.contains(window.frame)
                {
                    window.center()
                }
                return Outcome(.ok)
            case .prefs(let prefs):
                return applyPrefs(prefs, controller: controller, window: window)
            case .open(let path):
                guard let url = scenario?.resolve(path) else { return Outcome(.failed, "no scenario") }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return Outcome(.failed, "no folder at \(url.path)")
                }
                if url.comparablePath == controller.folder.comparablePath {
                    return Outcome(.ok)
                }
                let timing = await controller.navigate(to: url)
                return timing == nil ? Outcome(.failed, "could not open \(url.path)") : Outcome(.ok)
            case .select(let names):
                return select(names, in: window)
            case .key(let key, let modifiers):
                return press(key, modifiers: modifiers, window: window)
            case .type(let text):
                return type(text, window: window)
            case .command(let id):
                return AutomationCommands.run(id, controller: controller, window: window)
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return Outcome(.ok)
            case .snapshot(let name):
                return snapshot(window, to: options.out.appendingPathComponent(name + ".png"))
            case .geometry(let name, let allViews):
                AutomationTags.apply(in: window)
                let dump = GeometryDump(window: window, name: name, allViews: allViews)
                do {
                    try dump.encoded().write(to: options.out.appendingPathComponent(name + ".json"), options: .atomic)
                    return Outcome(.ok)
                } catch {
                    return Outcome(.failed, "could not write the geometry: \(error.localizedDescription)")
                }
            }
        }

        private func applyPrefs(
            _ prefs: [String: Scenario.PrefValue], controller: MainWindowController, window: NSWindow
        ) -> Outcome {
            var unsupported: [String] = []
            var failed: [String] = []
            for key in prefs.keys.sorted() {
                guard let value = prefs[key] else { continue }
                switch key {
                case "theme":
                    switch value.string {
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    case "auto", "system": NSApp.appearance = nil
                    default: failed.append("theme \(value)")
                    }
                case "viewMode":
                    switch value.string {
                    case "icons": controller.showAsIcons(nil)
                    case "details": controller.showAsList(nil)
                    default: unsupported.append("viewMode \(value.string ?? "?")")
                    }
                case "sortBy", "sortDirection":
                    continue
                case "zoomPercent":
                    if value.number != 100 { unsupported.append("zoomPercent \(value.number ?? 0)") }
                case "density":
                    if value.string != "comfortable" { unsupported.append("density \(value.string ?? "?")") }
                case "accent":
                    // The spike draws with the system accent color.
                    if value.string?.lowercased() != "#007aff" { unsupported.append("accent \(value.string ?? "?")") }
                case "favoritesPlacement":
                    // The spike's sidebar is the separate layout: Favorites and Locations lists.
                    if value.string != "separate" { unsupported.append("favoritesPlacement \(value.string ?? "?")") }
                default:
                    unsupported.append(key)
                }
            }
            if prefs["sortBy"] != nil || prefs["sortDirection"] != nil {
                let key = prefs["sortBy"]?.string ?? "name"
                let ascending = (prefs["sortDirection"]?.string ?? "asc") != "desc"
                if !AutomationCommands.sort(by: key, ascending: ascending, controller: controller, window: window) {
                    unsupported.append("sortBy \(key)")
                }
            }
            if !failed.isEmpty { return Outcome(.failed, "bad values: " + failed.joined(separator: ", ")) }
            if !unsupported.isEmpty { return Outcome(.partial, "unsupported: " + unsupported.joined(separator: ", ")) }
            return Outcome(.ok)
        }

        private func select(_ names: [String], in window: NSWindow) -> Outcome {
            var missing = Set(names)
            if let table = Views.folderTable(in: window) {
                let column = table.column(withIdentifier: .init("name"))
                guard column >= 0 else { return Outcome(.failed, "no Name column") }
                var rows = IndexSet()
                for row in 0..<table.numberOfRows {
                    let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
                    if let name = cell?.textField?.stringValue, missing.remove(name) != nil { rows.insert(row) }
                }
                table.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first { table.scrollRowToVisible(first) }
                window.makeFirstResponder(table)
            } else if let collection = Views.first(NSCollectionView.self, in: window.contentView),
                let source = collection.dataSource
            {
                var paths = Set<IndexPath>()
                for index in 0..<collection.numberOfItems(inSection: 0) {
                    let path = IndexPath(item: index, section: 0)
                    let item =
                        collection.item(at: path) ?? source.collectionView(collection, itemForRepresentedObjectAt: path)
                    if let name = item.textField?.stringValue, missing.remove(name) != nil { paths.insert(path) }
                }
                collection.selectionIndexPaths = paths
                window.makeFirstResponder(collection)
            } else {
                return Outcome(.failed, "no folder view")
            }
            return missing.isEmpty
                ? Outcome(.ok) : Outcome(.failed, "not found: " + missing.sorted().joined(separator: ", "))
        }

        private func press(_ name: String, modifiers names: [String], window: NSWindow) -> Outcome {
            guard let key = KeyEvents.key(named: name) else { return Outcome(.unsupported, "unknown key \(name)") }
            guard let modifiers = KeyEvents.modifiers(names) else {
                return Outcome(.failed, "unknown modifier in \(names)")
            }
            let events = KeyEvents.events(key, modifiers: modifiers, window: window)
            guard let down = events.first else { return Outcome(.failed, "could not make the key event") }
            // Delivered to the window directly: a run started from a terminal may not make the app active.
            if !modifiers.intersection([.command, .control]).isEmpty,
                NSApp.mainMenu?.performKeyEquivalent(with: down) == true || window.performKeyEquivalent(with: down)
            {
                return Outcome(.ok)
            }
            for event in events { window.sendEvent(event) }
            return Outcome(.ok)
        }

        private func type(_ text: String, window: NSWindow) -> Outcome {
            guard let editor = window.firstResponder as? NSTextView else {
                return Outcome(.failed, "no text field has the keyboard")
            }
            editor.insertText(text, replacementRange: editor.selectedRange())
            return Outcome(.ok)
        }

        /// Draws the window, title bar and toolbar included, at 2× whatever the screen.
        private func snapshot(_ window: NSWindow, to file: URL) -> Outcome {
            guard let frameView = window.contentView?.superview else { return Outcome(.failed, "no frame view") }
            window.displayIfNeeded()
            let bounds = frameView.bounds
            let bitmap: NSBitmapImageRep?
            if window.backingScaleFactor == 2 {
                bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds)
            } else {
                bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                bitmap?.size = bounds.size
            }
            guard let bitmap else { return Outcome(.failed, "could not make a bitmap") }
            frameView.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return Outcome(.failed, "could not encode the PNG")
            }
            do {
                try data.write(to: file, options: .atomic)
                return Outcome(.ok)
            } catch {
                return Outcome(.failed, "could not write \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Finding the window's views by kind.
    @MainActor
    enum Views {
        static func first<T: NSView>(_ type: T.Type, in view: NSView?, where accept: (T) -> Bool = { _ in true }) -> T?
        {
            guard let view, !view.isHidden else { return nil }
            if let match = view as? T, accept(match) { return match }
            for child in view.subviews {
                if let match = first(type, in: child, where: accept) { return match }
            }
            return nil
        }

        static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
            guard let view, !view.isHidden else { return [] }
            var found: [T] = []
            if let match = view as? T { found.append(match) }
            for child in view.subviews { found += all(type, in: child) }
            return found
        }

        /// The List view's table (the sidebar's outline is a table too).
        static func folderTable(in window: NSWindow) -> NSTableView? {
            first(NSTableView.self, in: window.contentView) { !($0 is NSOutlineView) }
        }

        static func statusText(in window: NSWindow) -> String? {
            first(NSTextField.self, in: window.contentView) {
                $0.accessibilityIdentifier() == AutomationTags.statusBar
            }?
            .stringValue
        }
    }
#endif
