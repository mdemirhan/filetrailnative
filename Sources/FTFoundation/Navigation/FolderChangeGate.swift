import Foundation

/// When a tab reads its folder again for changes made outside the app. A change waits while the list changing under
/// something would upset it: a dialog, a menu or a drag, a name being typed, a file operation running here or in
/// another window. It also waits for a read already under way, and for an opening of the same folder to end. What
/// waits is merged, and read once, as soon as nothing holds it.
///
/// The gate decides; the tab carries out what it is told (`Effect`) and says what happened.
public struct FolderChangeGate: Equatable, Sendable {
    /// What holds the changes and has no state of its own for the gate to ask: each lets go of its own hold only.
    public enum Hold: Hashable, Sendable {
        /// A dialog or sheet over the tab.
        case dialog
        /// A context menu open.
        case menu
        /// One of the tab's own items being dragged.
        case drag
    }

    /// The changes waiting to be read, merged: the set of changed items is the union, or nil (a full read) if any change
    /// did not say which items changed, or there are more than the limit.
    public struct Pending: Equatable, Sendable {
        /// The folder that changed.
        public var path: String
        public var changedPaths: Set<String>?

        public init(path: String, changedPaths: Set<String>?) {
            self.path = path
            self.changedPaths = changedPaths
        }

        /// What was waiting of another folder gives way.
        public static func merging(_ pending: Pending?, path: String, _ paths: [String]?, limit: Int) -> Pending {
            guard let pending, pending.path == path else {
                return Pending(path: path, changedPaths: paths.map(Set.init))
            }
            guard let existing = pending.changedPaths, let paths else {
                return Pending(path: path, changedPaths: nil)
            }
            let union = existing.union(paths)
            return Pending(path: path, changedPaths: union.count > limit ? nil : union)
        }
    }

    /// What the tab is doing about a read for changes.
    public enum Drain: Equatable, Sendable {
        case idle
        /// Its folder is being opened: the change is looked at again shortly (`retryElapsed`).
        case waitingToRetry
        /// A read for changes is under way (`readEnded`).
        case reading
    }

    /// The tab as it is at the moment of asking: what holds the changes and has a state of its own.
    public struct Situation: Equatable, Sendable {
        public enum Opening: Equatable, Sendable {
            case nothing
            /// The folder on screen is being read already, by a read that may have started before the change.
            case thisFolder
            /// Another folder is being opened, which leaves this one behind.
            case anotherFolder
        }

        /// The folder on screen.
        public var folderPath: String
        public var opening: Opening
        /// A name being typed in the list.
        public var renaming: Bool
        /// A file operation running here or in another window.
        public var writeLocked: Bool

        public init(folderPath: String, opening: Opening, renaming: Bool, writeLocked: Bool) {
            self.folderPath = folderPath
            self.opening = opening
            self.renaming = renaming
            self.writeLocked = writeLocked
        }
    }

    /// What the tab has to do next.
    public enum Effect: Equatable, Sendable {
        case none
        /// Calls `retryElapsed` shortly.
        case scheduleRetry
        /// Reads the folder again in place, for these items (nil: anything in it), then calls `readEnded`.
        case read(changedPaths: Set<String>?)
    }

    public private(set) var pending: Pending?
    public private(set) var holds: Set<Hold> = []
    public private(set) var drain: Drain = .idle
    /// Past this many changed items the read is a full one.
    public let maxChangedPaths: Int

    public init(maxChangedPaths: Int) {
        self.maxChangedPaths = maxChangedPaths
    }

    public var isHeld: Bool { !holds.isEmpty }

    /// The folder `path` changed, at `paths` (nil: anything in it may have).
    public mutating func changed(_ path: String, _ paths: [String]?, _ now: Situation) -> Effect {
        pending = Pending.merging(pending, path: path, paths, limit: maxChangedPaths)
        return flush(now)
    }

    /// Puts `hold` on, or takes it off; what waited is read once nothing holds it any more.
    public mutating func hold(_ hold: Hold, _ held: Bool, _ now: Situation) -> Effect {
        if held {
            holds.insert(hold)
            return .none
        }
        holds.remove(hold)
        return flush(now)
    }

    /// Something in `Situation` that held the changes may have let go: a name was typed, a file operation ended.
    public mutating func recheck(_ now: Situation) -> Effect {
        flush(now)
    }

    /// What waited is read now even though `hold` is on (the result sheet, so what the operation made shows behind it).
    public mutating func readDespite(_ hold: Hold, _ now: Situation) -> Effect {
        flush(now, despite: hold)
    }

    /// The wait for the folder's opening ran out.
    public mutating func retryElapsed(_ now: Situation) -> Effect {
        if drain == .waitingToRetry { drain = .idle }
        return flush(now)
    }

    /// The read for changes ended.
    public mutating func readEnded(_ now: Situation) -> Effect {
        if drain == .reading { drain = .idle }
        return flush(now)
    }

    /// The tab let go of its folder: nothing waits.
    public mutating func letGo() {
        pending = nil
    }

    private mutating func flush(_ now: Situation, despite: Hold? = nil) -> Effect {
        let holding = despite.map { holds.subtracting([$0]) } ?? holds
        guard let waiting = pending, drain == .idle, holding.isEmpty, !now.renaming, !now.writeLocked else {
            return .none
        }
        // Changes to a folder no longer on screen don't matter, and another folder being opened leaves this one
        // behind: reading it again would go back to it, or read the new one for them.
        guard waiting.path == now.folderPath, now.opening != .anotherFolder else {
            pending = nil
            return .none
        }
        // The folder on screen is being read already, by a read that may have started before the change: it is tried
        // again shortly.
        if now.opening == .thisFolder {
            drain = .waitingToRetry
            return .scheduleRetry
        }
        pending = nil
        drain = .reading
        return .read(changedPaths: waiting.changedPaths)
    }
}
