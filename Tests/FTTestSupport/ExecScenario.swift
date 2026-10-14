// Port of the scenario format of tools/parity/exec/places.ts (described in tools/parity/README.md):
// the execution and analysis scenarios the reference engine was run on, and how their trees and
// their changes on disk are made, so the Swift engine runs the same ones.
import Darwin
import Foundation

public struct ExecScenario: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        /// "file", "dir" or "symlink".
        public var kind: String
        public var content: String?
        /// Octal, "0644"; files default to 0644 and folders to 0755.
        public var mode: String?
        /// "uchg" and "hidden".
        public var flags: [String]?
        public var target: String?

        public init(
            path: String, kind: String, content: String? = nil, mode: String? = nil, flags: [String]? = nil,
            target: String? = nil
        ) {
            self.path = path
            self.kind = kind
            self.content = content
            self.mode = mode
            self.flags = flags
            self.target = target
        }
    }

    public struct Paste: Codable, Equatable, Sendable {
        /// "copy" or "cut".
        public var mode: String
        public var sources: [String]
        public var destination: String

        public init(mode: String, sources: [String], destination: String) {
            self.mode = mode
            self.sources = sources
            self.destination = destination
        }
    }

    public struct Policy: Codable, Equatable, Sendable {
        public var file: String
        public var directory: String
        public var mismatch: String

        public init(file: String, directory: String, mismatch: String) {
            self.file = file
            self.directory = directory
            self.mismatch = mismatch
        }
    }

    /// A per-item choice from the review, by analysis node id ("item-1/sub/a.txt").
    public struct Override: Codable, Equatable, Sendable {
        public var nodeId: String
        public var action: String
    }

    /// Stop the paste right after its n-th progress event, as the Stop button does.
    public struct StopPoint: Codable, Equatable, Sendable {
        public var afterEvent: Int
    }

    /// Kill the engine right after its n-th write of the journal file, then run recovery.
    public struct CrashPoint: Codable, Equatable, Sendable {
        public var journalWrite: Int
    }

    /// Changes made on disk while the paste runs: after the review (no `afterEvent`), or right
    /// after the n-th progress event, before the engine goes on.
    public struct Change: Codable, Equatable, Sendable {
        public struct Op: Codable, Equatable, Sendable {
            /// "write", "mkdir", "remove" or "chmod".
            public var op: String
            public var path: String
            public var content: String?
            /// For "chmod": octal, "0000".
            public var mode: String?
        }

        public var afterEvent: Int?
        public var ops: [Op]
    }

    public var name: String
    public var tree: [Item]
    public var paste: Paste
    public var policy: Policy
    public var overrides: [Override]?
    /// Answers to runtime questions in the order asked; "skip" once they run out.
    public var answers: [String]?
    /// For each answer, by position: true when it is given "for the rest of this operation" (the
    /// question's "Apply to remaining"); missing ones are false.
    public var applyToRemaining: [Bool]?
    public var stopAt: StopPoint?
    public var crashAt: CrashPoint?
    public var changes: [Change]?
    /// false: the engine has no Trash at all.
    public var trash: Bool?
    /// Top-level folders made on a disk image of their own: ["destination": "fat32"].
    public var volumes: [String: String]?
    /// Folders of `volumes` whose disk has no Trash: moving an item there to the Trash fails as on
    /// such a disk (ENOTSUP), and a Replace asks before deleting for good.
    public var volumesWithoutTrash: [String]?

    public init(
        name: String, tree: [Item], paste: Paste, policy: Policy, overrides: [Override]? = nil,
        answers: [String]? = nil, applyToRemaining: [Bool]? = nil,
        stopAt: StopPoint? = nil, crashAt: CrashPoint? = nil, changes: [Change]? = nil, trash: Bool? = nil,
        volumes: [String: String]? = nil, volumesWithoutTrash: [String]? = nil
    ) {
        self.name = name
        self.tree = tree
        self.paste = paste
        self.policy = policy
        self.overrides = overrides
        self.answers = answers
        self.applyToRemaining = applyToRemaining
        self.stopAt = stopAt
        self.crashAt = crashAt
        self.changes = changes
        self.trash = trash
        self.volumes = volumes
        self.volumesWithoutTrash = volumesWithoutTrash
    }

    public struct BuildFailure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Makes the scenario's tree, as places.ts does: items in order, then modes and flags deepest
    /// first (equally deep ones last item first).
    public func build(in places: ExecPlaces) throws {
        for item in tree {
            let path = places.resolve(item.path)
            let parent = (path as NSString).deletingLastPathComponent
            try Self.makeDirectories(parent)
            switch item.kind {
            case "file":
                guard Self.writeFile(path, item.content ?? "") else {
                    throw BuildFailure(description: "can't make \(path)")
                }
            case "dir":
                try Self.makeDirectories(path)
            case "symlink":
                guard symlink(item.target ?? "", path) == 0 else {
                    throw BuildFailure(description: "can't make \(path)")
                }
            default:
                throw BuildFailure(description: "unknown kind \(item.kind)")
            }
        }
        let depth = { (item: Item) in item.path.split(separator: "/", omittingEmptySubsequences: false).count }
        let deepestFirst = Array(tree.reversed()).enumerated()
            .sorted { a, b in
                depth(a.element) != depth(b.element) ? depth(a.element) > depth(b.element) : a.offset < b.offset
            }
            .map(\.element)
        for item in deepestFirst where item.kind != "symlink" {
            let path = places.resolve(item.path)
            let mode = item.mode ?? (item.kind == "dir" ? "0755" : "0644")
            guard let bits = mode_t(mode, radix: 8), chmod(path, bits) == 0 else {
                throw BuildFailure(description: "can't set mode \(mode) on \(path)")
            }
            var flags: UInt32 = 0
            for flag in item.flags ?? [] {
                flags |= flag == "uchg" ? UInt32(UF_IMMUTABLE) : flag == "hidden" ? UInt32(UF_HIDDEN) : 0
            }
            if flags != 0 && lchflags(path, flags) != 0 {
                throw BuildFailure(description: "can't set flags on \(path)")
            }
        }
    }

    /// The changes due at `afterEvent` (nil: after the review), made on disk now.
    public func applyChanges(afterEvent: Int?, in places: ExecPlaces) throws {
        for change in changes ?? [] where change.afterEvent == afterEvent {
            try Self.apply(change.ops, in: places)
        }
    }

    /// `mkdir -p` with the names spelled exactly as given, as Node's mkdir makes them: FileManager
    /// would store "Café" decomposed.
    static func makeDirectories(_ path: String) throws {
        var made = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            made += "/" + part
            if mkdir(made, 0o777) != 0 && errno != EEXIST {
                throw BuildFailure(description: "can't make \(made)")
            }
        }
    }

    /// Writes `content` in place as Node's writeFile does (open, truncate, write): an existing
    /// file keeps its inode, which the engine's fingerprints compare.
    static func writeFile(_ path: String, _ content: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(content.utf8)
        return bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count
    }

    public static func apply(_ ops: [Change.Op], in places: ExecPlaces) throws {
        for op in ops {
            let path = places.resolve(op.path)
            switch op.op {
            case "write":
                guard Self.writeFile(path, op.content ?? "") else {
                    throw BuildFailure(description: "can't write \(path)")
                }
            case "mkdir":
                try makeDirectories(path)
            case "remove":
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            case "chmod":
                guard let bits = mode_t(op.mode ?? "", radix: 8), chmod(path, bits) == 0 else {
                    throw BuildFailure(description: "can't set mode \(op.mode ?? "") on \(path)")
                }
            default:
                throw BuildFailure(description: "unknown change \(op.op)")
            }
        }
    }
}
