// Port of the history of apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts (applyHistoryUpdate :315-335, goBack, goForward and goToHistoryIndex :735-768)
import Foundation

/// A tab's history: an ordered list of folder paths and the index of the one on screen.
public struct NavigationHistory: Equatable, Sendable {
    /// How a navigation changes the history.
    public enum Mode: Equatable, Sendable {
        /// A new step: the entries after the current one are cut off and the folder is added. The folder already on
        /// screen is added again, as a second entry (B-NAV-003).
        case push
        /// Overwrites the current entry (a reload-type read: Refresh, a new sort, hidden files, Folders First).
        case replace
        /// Touches nothing (Back, Forward, a jump, a tab brought back).
        case skip
    }

    /// A spot in the history (`SearchReturnPlace`): its position and the folder there, since a later step can put
    /// another folder at that position.
    public struct Place: Equatable, Sendable {
        public let index: Int
        public let path: String

        public init(index: Int, path: String) {
            self.index = index
            self.path = path
        }
    }

    public private(set) var paths: [String]
    /// The entry on screen; -1 while the history is empty.
    public private(set) var index: Int

    public init() {
        paths = []
        index = -1
    }

    /// A history of `paths` with `index` on screen; an index outside them is brought into range.
    public init(paths: [String], index: Int) {
        self.paths = paths
        self.index = paths.isEmpty ? -1 : max(0, min(paths.count - 1, index))
    }

    /// `[path]` at index 0: a tab that starts at a folder.
    public init(startingAt path: String) {
        paths = [path]
        index = 0
    }

    public var current: String? { paths.indices.contains(index) ? paths[index] : nil }

    /// `canGoBack`: `historyIndex > 0`.
    public var canGoBack: Bool { index > 0 }

    /// `canGoForward`: `historyIndex >= 0 && historyIndex < historyPaths.length - 1`.
    public var canGoForward: Bool { index >= 0 && index < paths.count - 1 }

    /// The folder Back goes to; nil at the first entry.
    public var backTarget: String? { canGoBack ? paths[index - 1] : nil }

    /// The folder Forward goes to; nil at the last entry.
    public var forwardTarget: String? { canGoForward ? paths[index + 1] : nil }

    /// Whether `place` is still as it was: the same folder at the same position.
    public func holds(_ place: Place) -> Bool {
        paths.indices.contains(place.index) && paths[place.index] == place.path
    }

    /// `applyHistoryUpdate`: a folder was opened and drawn.
    public mutating func record(_ path: String, mode: Mode) {
        switch mode {
        case .push:
            paths = Array(paths.prefix(index + 1)) + [path]
            index += 1
        case .replace:
            if paths.isEmpty {
                paths = [path]
            } else {
                paths[max(0, index)] = path
            }
            if index < 0 { index = 0 }
        case .skip:
            break
        }
    }

    /// `goBack`: the index moves at once, before the folder is read. Returns the folder to open.
    @discardableResult
    public mutating func goBack() -> String? {
        guard let target = backTarget else { return nil }
        index -= 1
        return target
    }

    /// `goForward`.
    @discardableResult
    public mutating func goForward() -> String? {
        guard let target = forwardTarget else { return nil }
        index += 1
        return target
    }

    /// `goToHistoryIndex`: a jump within the history from the Back and Forward hold menus; nothing is added.
    @discardableResult
    public mutating func jump(to target: Int) -> String? {
        guard paths.indices.contains(target), target != index else { return nil }
        index = target
        return paths[target]
    }

    /// Rewrites every entry (a folder renamed or moved by any window takes the history along).
    public mutating func mapPaths(_ transform: (String) -> String) {
        paths = paths.map(transform)
    }
}
