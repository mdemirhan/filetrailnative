// Port of apps/desktop/src/main/explorerWindows.ts
import FTFoundation
import Foundation

// The open explorer windows, front to back. A window moves to the front when it gets the focus, so the first one is
// the one the person used last: where New Window takes its folder from, where the menu sends commands while Settings
// has the keyboard, and where a running operation goes when the window that started it closes.

/// What a window opens with: the launch folder for the window in front at startup, whether it opens the tabs it was
/// given, and a menu command to run once it has opened (`app:getLaunchContext`).
public struct ExplorerLaunchContext: Equatable, Sendable {
    /// The folder File Trail was launched with, given to the window in front at startup.
    public var startupFolderPath: String?
    /// Opened while the app runs: it opens the tabs it was given, whatever the restore setting says.
    public var restoreTabs: Bool
    /// A place of the Go menu chosen while no window was open.
    public var initialCommand: RendererCommand?

    public init(startupFolderPath: String? = nil, restoreTabs: Bool = false, initialCommand: RendererCommand? = nil) {
        self.startupFolderPath = startupFolderPath
        self.restoreTabs = restoreTabs
        self.initialCommand = initialCommand
    }
}

/// One open explorer window: its id kept between launches, and what it was opened with.
@MainActor
public final class ExplorerWindowEntry<W: AnyObject> {
    public let id: String
    public let window: W
    /// The window's own number while the app runs (the original's web contents id).
    public let windowID: Int
    public var launch: ExplorerLaunchContext

    public init(id: String, window: W, windowID: Int, launch: ExplorerLaunchContext = ExplorerLaunchContext()) {
        self.id = id
        self.window = window
        self.windowID = windowID
        self.launch = launch
    }
}

/// `ExplorerWindowList`: the windows, front to back.
@MainActor
public final class ExplorerWindowOrder<W: AnyObject> {
    public enum Place: Sendable { case front, back }

    public private(set) var all: [ExplorerWindowEntry<W>] = []

    public init() {}

    /// Adds a window in front, or behind the others (windows brought back at startup).
    public func add(_ entry: ExplorerWindowEntry<W>, _ place: Place = .front) {
        let others = all.filter { !Self.same($0.id, entry.id) }
        all = place == .front ? [entry] + others : others + [entry]
    }

    public func remove(_ id: String) {
        all.removeAll { Self.same($0.id, id) }
    }

    /// Returns whether the order changed.
    @discardableResult
    public func moveToFront(_ id: String) -> Bool {
        guard let entry = byID(id), all.first !== entry else { return false }
        all = [entry] + all.filter { $0 !== entry }
        return true
    }

    public var front: ExplorerWindowEntry<W>? { all.first }
    public var count: Int { all.count }

    public func byID(_ id: String) -> ExplorerWindowEntry<W>? {
        all.first { Self.same($0.id, id) }
    }

    public func byWindowID(_ windowID: Int?) -> ExplorerWindowEntry<W>? {
        guard let windowID else { return nil }
        return all.first { $0.windowID == windowID }
    }

    public func byWindow(_ window: W) -> ExplorerWindowEntry<W>? {
        all.first { $0.window === window }
    }

    // Ids are compared as JavaScript compares strings: unit by unit.
    private static func same(_ left: String, _ right: String) -> Bool {
        left.utf16.elementsEqual(right.utf16)
    }
}

/// A window's place and size, with the origin at the top left of the main screen, y growing down (Electron's
/// coordinates, which `app-state.json` keeps).
public struct WindowBounds: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ExplorerWindowPlacement {
    /// NEW_WINDOW_OFFSET: how far a new window sits down and to the right of the one it comes from, as Finder's.
    public static let newWindowOffset: Double = 22

    /// `placeNewWindow`: a step down and to the right of `from`, the same size. A window that would reach past the
    /// bottom or right of the screen's usable area starts again from its top left, as Finder's do.
    public static func placeNewWindow(from: WindowBounds, workArea: WindowBounds) -> WindowBounds {
        let width = min(from.width, workArea.width)
        let height = min(from.height, workArea.height)
        var x = from.x + newWindowOffset
        var y = from.y + newWindowOffset
        if x + width > workArea.x + workArea.width || y + height > workArea.y + workArea.height {
            x = workArea.x
            y = workArea.y
        }
        return WindowBounds(x: x, y: y, width: width, height: height)
    }
}
