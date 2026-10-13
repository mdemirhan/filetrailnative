import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var controllers: [MainWindowController] = []

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let arguments = CommandLine.arguments.dropFirst()
        let snapshot = arguments.firstIndex(of: "--snapshot").flatMap {
            arguments.index(after: $0) < arguments.endIndex ? arguments[arguments.index(after: $0)] : nil
        }
        let start =
            arguments.first { !$0.hasPrefix("-") && $0 != snapshot }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home
        let controller = openWindow(at: start)
        NSApp.activate()

        if arguments.contains("--bench") {
            Task { await Benchmark.run(in: controller, root: start) }
        }
        if let snapshot {
            Task { await Benchmark.snapshot(controller, to: URL(fileURLWithPath: snapshot)) }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(at: home) }
        return true
    }

    @discardableResult
    func openWindow(at url: URL) -> MainWindowController {
        let controller = makeController(at: url)
        controller.showWindow(nil)
        return controller
    }

    func openTab(at url: URL, nextTo existing: MainWindowController) {
        let controller = makeController(at: url)
        guard let window = controller.window else { return }
        existing.window?.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// File > New Window opens the front window's folder.
    @objc func newWindow(_ sender: Any?) {
        let front = NSApp.keyWindow?.windowController as? MainWindowController
        openWindow(at: front?.folder ?? home)
    }

    private func makeController(at url: URL) -> MainWindowController {
        let controller = MainWindowController(folder: url)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        return controller
    }
}

@MainActor
enum Benchmark {
    /// Opens each sub-folder of `root` and goes back, three times over, then
    /// prints the median timings and quits.
    static func run(in controller: MainWindowController, root: URL) async {
        let folders =
            ((try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles])) ?? [])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.path < $1.path }
            .prefix(20)

        try? await Task.sleep(for: .milliseconds(500))
        var opens: [NavigationTiming] = []
        var backs: [NavigationTiming] = []
        for _ in 0..<3 {
            for folder in folders {
                if let timing = await controller.navigate(to: folder) { opens.append(timing) }
                try? await Task.sleep(for: .milliseconds(50))
                if let timing = await controller.navigate(to: root, history: .back) {
                    backs.append(timing)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        report("open", opens)
        report("back", backs)
        NSApp.terminate(nil)
    }

    /// Draws the window (title bar and toolbar included) into a PNG, then quits.
    /// For checking the look where screen recording isn't allowed.
    static func snapshot(_ controller: MainWindowController, to file: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let frameView = controller.window?.contentView?.superview,
            let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        NSApp.terminate(nil)
    }

    private static func report(_ name: String, _ timings: [NavigationTiming]) {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let read = median(timings.map(\.read.milliseconds))
        let load = median(timings.map(\.load.milliseconds))
        let display = median(timings.map(\.display.milliseconds))
        let total = median(timings.map { ($0.load + $0.display).milliseconds })
        let worst = timings.map { ($0.load + $0.display).milliseconds }.max() ?? 0
        let items = median(timings.map { Double($0.itemCount) })
        print(
            String(
                format:
                    "%@: %d runs, median %.0f items: load %.1f ms (disk %.1f ms) + display %.1f ms = %.1f ms (worst %.1f ms)",
                name, timings.count, items, load, read, display, total, worst))
    }
}
