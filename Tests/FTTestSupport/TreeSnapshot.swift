// Port of tools/parity/exec/snapshot.ts: a normalized description of a folder's tree, to compare what
// the Swift engine leaves on disk with what the reference engine leaves.
import CryptoKit
import Darwin
import Foundation

public enum TreeSnapshot {
    /// One item under the snapshot's root. Timestamps and inode numbers are left out on purpose.
    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the root, NFD.
        public var path: String
        /// "file", "dir", "symlink" or "other" (a pipe, socket or device).
        public var kind: String
        /// A symlink's target, as stored.
        public var target: String?
        /// A file's length, or a symlink's (its target's length in bytes).
        public var size: Int?
        /// A file's contents, as lowercase hex.
        public var sha256: String?
        /// `st_mode & 0o7777` in octal, four digits.
        public var mode: String
        /// The BSD flags compared: "hidden" and "uchg" (Finder's Locked), in that order.
        public var flags: [String]
        /// Whether the item has an extended ACL.
        public var acl: Bool
    }

    public struct Failure: Error, CustomStringConvertible {
        public let call: String
        public let path: String
        public let errno: Int32

        public var description: String { "\(call)(\(path)): \(String(cString: strerror(errno)))" }
    }

    /// Every item below `root` (not `root` itself), sorted by path as JavaScript sorts strings.
    public static func entries(of root: String) throws -> [Entry] {
        var entries: [Entry] = []
        try walk(root: root, relative: "", into: &entries)
        return entries.sorted { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }
    }

    /// The snapshot as snapshot.ts writes it: `JSON.stringify(entries, null, 2)` and a newline.
    public static func json(_ entries: [Entry]) -> String {
        JSONText.stringify(.array(entries.map(value))) + "\n"
    }

    private static func value(_ entry: Entry) -> JSONText.Value {
        var members: [JSONText.Member] = [
            .init("acl", .bool(entry.acl)),
            .init("flags", .array(entry.flags.map { .string($0) })),
            .init("kind", .string(entry.kind)),
            .init("mode", .string(entry.mode)),
            .init("path", .string(entry.path)),
        ]
        if let sha256 = entry.sha256 {
            members.append(.init("sha256", .string(sha256)))
        }
        if let size = entry.size {
            members.append(.init("size", .int(size)))
        }
        if let target = entry.target {
            members.append(.init("target", .string(target)))
        }
        return .object(members)
    }

    private static func walk(root: String, relative: String, into entries: inout [Entry]) throws {
        let folder = relative.isEmpty ? root : root + "/" + relative
        for name in try names(in: folder) {
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            let entry = try describe(root + "/" + childRelative, relative: childRelative)
            entries.append(entry)
            if entry.kind == "dir" {
                try walk(root: root, relative: childRelative, into: &entries)
            }
        }
    }

    private static func names(in folder: String) throws -> [String] {
        guard let stream = opendir(folder) else {
            throw Failure(call: "opendir", path: folder, errno: errno)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let item = readdir(stream) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    private static func describe(_ path: String, relative: String) throws -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Failure(call: "lstat", path: path, errno: errno)
        }
        var entry = Entry(
            path: relative.decomposedStringWithCanonicalMapping, kind: "other", mode: octal(info.st_mode & 0o7777),
            flags: flags(info.st_flags), acl: hasACL(path))
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            entry.kind = "file"
            entry.size = Int(info.st_size)
            entry.sha256 = try sha256(of: path)
        case S_IFDIR:
            entry.kind = "dir"
        case S_IFLNK:
            entry.kind = "symlink"
            entry.size = Int(info.st_size)
            entry.target = try linkTarget(path)
        default:
            break
        }
        return entry
    }

    private static func octal(_ mode: mode_t) -> String {
        let digits = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    private static func flags(_ raw: UInt32) -> [String] {
        var names: [String] = []
        if raw & UInt32(UF_HIDDEN) != 0 {
            names.append("hidden")
        }
        if raw & UInt32(UF_IMMUTABLE) != 0 {
            names.append("uchg")
        }
        return names
    }

    private static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func linkTarget(_ path: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count)
        guard length >= 0 else {
            throw Failure(call: "readlink", path: path, errno: errno)
        }
        return String(decoding: buffer[..<length], as: UTF8.self)
    }

    private static func sha256(of path: String) throws -> String {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Failure(call: "open", path: path, errno: errno)
        }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw Failure(call: "read", path: path, errno: errno)
            }
            if count == 0 {
                break
            }
            hasher.update(data: buffer[..<count])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
