import Foundation

/// A window's tabs saved by name, to be opened again: the window's session (its tabs and their panes, the tab in
/// front, its panels and widths) and its size.
public struct Workspace: Codable, Equatable, Sendable {
    /// Kept while it is renamed and moved: a window opened from it knows it by this.
    public var id: String
    public var name: String
    /// The window's size and whether it was zoomed. It has no place on screen: it opens where a new window would.
    public var bounds: StoredWindowState
    public var session: WindowSession

    public init(id: String, name: String, bounds: StoredWindowState, session: WindowSession) {
        self.id = id
        self.name = name
        self.bounds = StoredWindowState(width: bounds.width, height: bounds.height, maximized: bounds.maximized)
        self.session = session
    }
}

/// The rules of the workspaces: their names, their keys, what is kept of them.
public enum Workspaces {
    /// How many are kept.
    public static let limit = 50
    /// How long a name can be, in UTF-16 units.
    public static let nameLimit = 80
    /// The commands that open the first workspaces in the list (Workspace 1 to 5), in order.
    public static let slotCommands: [ShortcutCommandID] = [
        .openWorkspace1, .openWorkspace2, .openWorkspace3, .openWorkspace4, .openWorkspace5,
    ]

    /// The commands that open the same five in the window the menu acts on, in order.
    public static let inThisWindowSlotCommands: [ShortcutCommandID] = [
        .openWorkspace1InThisWindow, .openWorkspace2InThisWindow, .openWorkspace3InThisWindow,
        .openWorkspace4InThisWindow, .openWorkspace5InThisWindow,
    ]

    /// Which workspace in the list a command opens, from 0; nil for any other command.
    public static func slot(of command: ShortcutCommandID) -> Int? {
        slotCommands.firstIndex(of: command)
    }

    /// Which workspace in the list a command opens in the window the menu acts on, from 0; nil for any other command.
    public static func inThisWindowSlot(of command: ShortcutCommandID) -> Int? {
        inThisWindowSlotCommands.firstIndex(of: command)
    }

    /// A new workspace's id.
    public static func newID() -> String {
        "workspace-\(UUID().uuidString.lowercased())"
    }

    /// A name as it is kept: trimmed, and cut at `nameLimit`.
    public static func cleanName(_ typed: String) -> String {
        BatchRenameTextRules.limited(JSString.trimmed(typed), to: nameLimit)
    }

    /// The workspace with this name, ignoring case.
    public static func index(named name: String, in workspaces: [Workspace]) -> Int? {
        let key = JSString.lowercased(cleanName(name))
        return workspaces.firstIndex { JSString.lowercased($0.name).utf16.elementsEqual(key.utf16) }
    }

    /// The workspace with this id.
    public static func index(id: String, in workspaces: [Workspace]) -> Int? {
        workspaces.firstIndex { $0.id.utf16.elementsEqual(id.utf16) }
    }

    /// Why `name` can't be the new name of the workspace `id`: another has it. Nil when it can.
    public static func renameRefusal(_ name: String, id: String, in workspaces: [Workspace]) -> String? {
        guard let taken = index(named: name, in: workspaces), !workspaces[taken].id.utf16.elementsEqual(id.utf16)
        else { return nil }
        return "There\u{2019}s already a workspace called \u{201C}\(workspaces[taken].name)\u{201D}."
    }

    /// What a workspace holds, in a few words: "4 tabs, 2 with two panes".
    public static func summary(_ session: WindowSession) -> String {
        let tabs = session.openTabs.count
        let split = session.openTabs.filter { $0.secondPane != nil }.count
        let count = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        if split == 0 { return count }
        if tabs == 1 { return "1 tab with two panes" }
        return "\(count), \(split) with two panes"
    }

    /// `workspaces` with `saved` in place of the one with its name, or at the end when none has it; past `limit`
    /// nothing is added.
    public static func saving(_ saved: Workspace, in workspaces: [Workspace]) -> [Workspace] {
        var result = workspaces
        if let existing = index(named: saved.name, in: result) {
            result[existing] = saved
        } else if result.count < limit {
            result.append(saved)
        }
        return result
    }

    // MARK: Opening

    /// Every folder of the session's tabs and their second panes, once each, in order.
    public static func folders(of session: WindowSession) -> [String] {
        var seen = Set<String>()
        var folders: [String] = []
        for tab in session.openTabs {
            for path in [tab.path, tab.secondPane?.path].compactMap({ $0 }) where seen.insert(path).inserted {
                folders.append(path)
            }
        }
        return folders
    }

    /// The session with each folder in `gone` shown as `nearest` says (the nearest folder above it that is there), and
    /// how many tabs had one. A tab moved off its favorite shows the folder, not the favorite.
    public static func replacingGoneFolders(
        _ session: WindowSession, gone: Set<String>, nearest: (String) -> String
    ) -> (session: WindowSession, tabs: Int) {
        guard !gone.isEmpty else { return (session, 0) }
        var result = session
        var moved = 0
        for index in result.openTabs.indices {
            var tab = result.openTabs[index]
            var changed = false
            if let path = tab.path, gone.contains(path) {
                tab.path = nearest(path)
                tab.favoritePath = nil
                changed = true
            }
            if let path = tab.secondPane?.path, gone.contains(path) {
                tab.secondPane?.path = nearest(path)
                changed = true
            }
            if changed {
                moved += 1
                result.openTabs[index] = tab
            }
        }
        if result.openTabs.indices.contains(result.frontTabIndex) {
            let front = result.openTabs[result.frontTabIndex]
            result.lastVisitedPath = front.path
            result.lastVisitedFavoritePath = front.favoritePath
        }
        return (result, moved)
    }

    // MARK: Reading

    /// Workspaces from a damaged file are kept as far as they make sense: one with no id, a name another has, or no
    /// tab is dropped. A session's missing value takes the one in `defaults`.
    public static func sanitize(_ value: JSONNode?, defaults: AppPreferences) -> [Workspace] {
        guard let candidates = value?.array, !candidates.isEmpty else { return [] }
        // The preferences the sessions are read over, without the workspaces themselves.
        var base = (try? JSONNode.of(defaults))?.object ?? [:]
        base[PreferenceKey.workspaces.rawValue] = nil
        var workspaces: [Workspace] = []
        for candidate in candidates {
            guard let record = candidate.object, let id = record["id"]?.string, !id.isEmpty,
                index(id: id, in: workspaces) == nil
            else { continue }
            let name = cleanName(record["name"]?.string ?? "")
            guard !name.isEmpty, index(named: name, in: workspaces) == nil else { continue }
            var merged = base
            let saved = record["session"]?.object ?? [:]
            for key in WindowSession.keys {
                if let value = saved[key.rawValue] { merged[key.rawValue] = value }
            }
            var session = PreferencesSanitizer.sanitize(.object(merged), defaults: defaults).windowSession
            guard !session.openTabs.isEmpty else { continue }
            session.activeTabIndex = session.frontTabIndex
            workspaces.append(
                Workspace(
                    id: id, name: name, bounds: AppStateReader.windowState(record["bounds"]), session: session))
            if workspaces.count == limit { break }
        }
        return workspaces
    }
}
