// The permissions popover's changes, written through the write slot and kept as one Undo for each time it is open
import Darwin
import FTFileSystem
import FTFoundation
import Foundation

/// An item whose permissions couldn't be changed, and why.
public struct PermissionsFailure: Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// What one change of the popover did: the items it changed, each as it was and is now, and those it couldn't.
public struct PermissionsWriteRun: Equatable, Sendable {
    public var items: [PermissionsUndoItem] = []
    public var failures: [PermissionsFailure] = []

    public init(items: [PermissionsUndoItem] = [], failures: [PermissionsFailure] = []) {
        self.items = items
        self.failures = failures
    }
}

/// One time the permissions popover is open: everything changed while it is open is one Undo. The first change
/// records it in the history; each change after it gives that same entry the items' newest settings, while it is
/// still the one Undo would take next. Once it isn't (an Undo took it, or another operation came after it), the next
/// change records a new one.
@MainActor
public final class PermissionsVisit {
    /// The history's entry for this visit, once one is recorded.
    public private(set) var entryId: Int?
    /// Each item changed, by path, with its setting before the visit's first change of it and its newest one.
    private var items: [PermissionsUndoItem] = []
    /// Where each item is in `items`, by its path: a change of thousands of items finds each at once, where looking
    /// through the list for each one took seconds a click.
    private var places: [NameKeys.Exact: Int] = [:]

    public init() {}

    /// The items as the entry holds them, for the history: those left as they were taken out.
    func merge(_ changed: [PermissionsUndoItem], restarting: Bool) -> [PermissionsUndoItem] {
        if restarting {
            items = []
            places = [:]
        }
        for item in changed {
            let key = NameKeys.Exact(item.path)
            if let index = places[key] {
                items[index].after = item.after
                items[index].id = item.id
            } else {
                places[key] = items.count
                items.append(item)
            }
        }
        if items.contains(where: { $0.before == $0.after }) {
            items.removeAll { $0.before == $0.after }
            places = Dictionary(
                items.enumerated().map { (NameKeys.Exact($0.element.path), $0.offset) },
                uniquingKeysWith: { first, _ in first })
        }
        return items
    }

    fileprivate func recorded(_ id: Int?) { entryId = id }
}

public enum PermissionsWrite {
    /// The flags the popover changes: Finder's Locked and the flag that hides an item whatever its name.
    static let lockedFlag = UInt32(UF_IMMUTABLE)
    static let hiddenFlag = UInt32(UF_HIDDEN)

    /// The item at `path` as it is now: its setting, its flags as they are and its id; nil for a link, which isn't
    /// changed. Throws when it can't be read.
    static func read(_ fileSystem: some WriteServiceFileSystem, _ path: String) throws -> (
        setting: PermissionsSetting, flags: UInt32, id: ItemId?
    )? {
        let stats = try fileSystem.lstat(path)
        if stats.isSymbolicLink { return nil }
        let flags = try fileSystem.getFlags(path)
        let setting = PermissionsSetting(
            mode: Int(stats.mode & 0o7777), locked: flags & lockedFlag != 0, hidden: flags & hiddenFlag != 0)
        return (setting, flags, itemIdOf(stats))
    }

    /// Gives the item at `path` the setting `target`, from `current` (with its `flags`). A locked item refuses a
    /// new mode: with `unlocking` (an Undo or Redo putting back what it had) it is unlocked first, its mode written,
    /// and then its flags; otherwise the refusal is the answer. Should the mode fail once unlocked, the lock goes
    /// back on.
    static func write(
        _ fileSystem: some WriteServiceFileSystem, _ path: String, from current: PermissionsSetting, flags: UInt32,
        to target: PermissionsSetting, unlocking: Bool
    ) throws {
        var flagsNow = flags
        let modeChanges = current.mode != target.mode
        if modeChanges, current.locked {
            guard unlocking else { throw LockedError() }
            flagsNow &= ~lockedFlag
            try fileSystem.setFlags(path, flagsNow)
        }
        if modeChanges {
            do {
                try fileSystem.chmod(path, UInt32(target.mode))
            } catch {
                if flagsNow != flags { try? fileSystem.setFlags(path, flags) }
                throw error
            }
        }
        var wanted = target.locked ? flagsNow | lockedFlag : flagsNow & ~lockedFlag
        wanted = target.hidden ? wanted | hiddenFlag : wanted & ~hiddenFlag
        if wanted != flagsNow { try fileSystem.setFlags(path, wanted) }
    }

    /// A locked item asked for a new mode by the popover.
    struct LockedError: Error {}

    /// The write was taken and the item is as it was: a disk that keeps no permissions (exFAT, FAT) answers so.
    struct NotKeptError: Error {}

    /// Why the write to the item at `path` failed, said about it.
    static func describe(_ error: any Error, _ path: String) -> String {
        if error is LockedError { return "It is locked. Turn off Locked to change its permissions." }
        if error is NotKeptError { return "Its disk doesn\u{2019}t keep these permissions." }
        if errorCode(error) == .errno(ENOENT) { return "It no longer exists." }
        if errorCode(error) == .errno(EROFS) { return "Its disk can only be read." }
        return describeCopyPasteError(error)
    }

    /// `change` made to each item at `paths`, each after the one before it: only what the change is about changes,
    /// each item's other bits stay. A link is left as it is, and so is an item the change leaves as it was. Reads
    /// and writes the disk: call it off the main actor.
    public static func change(
        _ change: PermissionsChange, paths: [String], fileSystem: some WriteServiceFileSystem
    ) -> PermissionsWriteRun {
        var run = PermissionsWriteRun()
        for path in paths {
            do {
                guard let now = try read(fileSystem, path) else { continue }
                var target = now.setting
                target.mode = change.applied(to: target.mode)
                switch change {
                case .locked(let on): target.locked = on
                case .hidden(let on): target.hidden = on
                case .bit, .mode: break
                }
                if target == now.setting { continue }
                try write(fileSystem, path, from: now.setting, flags: now.flags, to: target, unlocking: false)
                let after = (try? read(fileSystem, path))??.setting ?? target
                // Written without a refusal, and nothing changed: said, where it would otherwise pass as done with
                // the box going back by itself.
                if after == now.setting { throw NotKeptError() }
                run.items.append(PermissionsUndoItem(path: path, id: now.id, before: now.setting, after: after))
            } catch {
                run.failures.append(PermissionsFailure(path: path, message: describe(error, path)))
            }
        }
        return run
    }
}

extension WriteCoordinator {
    /// A change of the permissions popover: written with the write slot held (refused while another operation runs,
    /// as every write is), each item after the one before it, and kept for Undo as part of `visit`'s one entry.
    public func changePermissions(_ change: PermissionsChange, paths: [String], visit: PermissionsVisit) async throws
        -> PermissionsWriteRun
    {
        let fileSystem = self.fileSystem
        return try await prepareWithReservedSlot {
            options.caches.writeStarting()
            let run = await LocalOperations.onDisk {
                PermissionsWrite.change(change, paths: paths, fileSystem: fileSystem)
            }
            options.caches.writeEnded()
            if !run.items.isEmpty {
                options.caches.forget(run.items.map(\.path), [])
                recordPermissions(run.items, visit: visit)
            }
            return run
        } then: { run, _ in
            run
        }
    }

    /// The visit's entry given the newest settings while Undo would still take it next; otherwise a new entry.
    private func recordPermissions(_ changed: [PermissionsUndoItem], visit: PermissionsVisit) {
        let history = options.undoHistory
        let current = visit.entryId.flatMap { id in history?.top(.undo)?.id == id ? id : nil }
        var items = visit.merge(changed, restarting: current == nil)
        var units = items.isEmpty ? [] : [UndoUnit(steps: [.permissions(items: items)])]
        if let history, let current {
            if history.replaceTop(current, units: units) {
                visit.recorded(units.isEmpty ? nil : current)
                return
            }
            // Not last in the list after all (an operation that can't be undone came after it, and Undo has said
            // so): this change starts an entry of its own.
            items = visit.merge(changed, restarting: true)
            units = items.isEmpty ? [] : [UndoUnit(steps: [.permissions(items: items)])]
        }
        guard !units.isEmpty else { return }
        recordFinishedWrite(
            FinishedWrite(
                action: .write(.changePermissions), log: .undoable(units: units),
                items: items.map {
                    WriteOperationItem(sourcePath: $0.path, destinationPath: $0.path, status: .completed)
                }))
        visit.recorded(history?.top(.undo)?.id)
    }
}
