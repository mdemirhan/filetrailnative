// What the permissions popover shows of its items, read from the disk
import Darwin
import FTFoundation
import Foundation

/// The items of the permissions popover as they are on the disk, and why they can't be changed, if they can't.
public struct PermissionsRead: Equatable, Sendable {
    public var checklist: PermissionsChecklist
    public var refusal: PermissionsRefusal?

    public init(checklist: PermissionsChecklist, refusal: PermissionsRefusal?) {
        self.checklist = checklist
        self.refusal = refusal
    }
}

public enum PermissionsReader {
    /// The items at `paths`, each itself and not where a link leads. A link is left out: its own mode isn't what
    /// opening it checks, and the popover doesn't change it. An item that can't be read is left out too.
    /// `inTrash`: the items are in the Trash, which is said before anything else.
    public static func read(_ paths: [String], inTrash: Bool = false) -> PermissionsRead {
        var items: [PermissionsItem] = []
        var readOnly = false
        var readable = true
        var writable = true
        var names = Names()
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
            let isYours = info.st_uid == getuid()
            items.append(
                PermissionsItem(
                    path: path, mode: Int(info.st_mode & 0o7777), locked: info.st_flags & UInt32(UF_IMMUTABLE) != 0,
                    hidden: info.st_flags & UInt32(UF_HIDDEN) != 0, isFolder: info.st_mode & S_IFMT == S_IFDIR,
                    owner: names.user(info.st_uid), group: names.group(info.st_gid), isYours: isYours))
            if !isYours {
                readable = readable && access(path, R_OK) == 0
                writable = writable && access(path, W_OK) == 0
            }
            if !readOnly { readOnly = isOnReadOnlyDisk(path) }
        }
        let checklist = PermissionsChecklist(items: items)
        let refusal: PermissionsRefusal?
        if inTrash {
            refusal = .inTrash
        } else if items.isEmpty {
            refusal = paths.isEmpty ? nil : .onlyLinks
        } else if !checklist.canChange {
            let others = PermissionsChecklist(items: items.filter { !$0.isYours })
            refusal = .notYours(
                owner: others.owner, youCan: PermissionsRefusal.youCan(read: readable, write: writable),
                several: items.count > 1)
        } else if readOnly {
            refusal = .readOnlyDisk
        } else {
            refusal = nil
        }
        return PermissionsRead(checklist: checklist, refusal: refusal)
    }

    private static func isOnReadOnlyDisk(_ path: String) -> Bool {
        var disk = statfs()
        return statfs(path, &disk) == 0 && disk.f_flags & UInt32(MNT_RDONLY) != 0
    }

    /// Users' and groups' names, each looked up once.
    private struct Names {
        var users: [uid_t: String] = [:]
        var groups: [gid_t: String] = [:]

        mutating func user(_ id: uid_t) -> String {
            if let known = users[id] { return known }
            let name = getpwuid(id).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? "\(id)"
            users[id] = name
            return name
        }

        mutating func group(_ id: gid_t) -> String {
            if let known = groups[id] { return known }
            let name = getgrgid(id).flatMap { String(validatingCString: $0.pointee.gr_name) } ?? "\(id)"
            groups[id] = name
            return name
        }
    }
}
