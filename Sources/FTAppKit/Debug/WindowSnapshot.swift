// --snapshot: the window drawn into a PNG, for checking the look where screen recording isn't allowed
import AppKit

@MainActor
enum WindowSnapshot {
    /// Draws the window (title bar and toolbar included) into a PNG once its folder has settled, then quits.
    static func write(_ controller: MainWindowController, to file: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let frameView = controller.window?.contentView?.superview,
            let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        // From a run-loop turn: inside a main-actor task, `terminate` waits for the quit coordinator's own main-actor
        // task, which can't run until this one ends, so the app would hang.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
