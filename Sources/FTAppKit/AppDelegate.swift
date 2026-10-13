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

        if arguments.contains("--bench-launch") {
            Benchmark.launch(controller)
        } else if arguments.contains("--bench-scroll") {
            Task { await Benchmark.scroll(in: controller) }
        } else if arguments.contains("--bench") {
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
