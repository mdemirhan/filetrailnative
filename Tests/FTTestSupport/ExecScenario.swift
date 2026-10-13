// The execution scenarios tools/parity/exec/run.ts runs through the reference engine (format in
// tools/parity/README.md), and what it recorded, so the Swift engine can run the same ones.
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
    }

    public struct Paste: Codable, Equatable, Sendable {
        /// "copy" or "cut".
        public var mode: String
        public var sources: [String]
        public var destination: String
    }

    public struct Policy: Codable, Equatable, Sendable {
        public var file: String
        public var directory: String
        public var mismatch: String
    }

    public struct StopPoint: Codable, Equatable, Sendable {
        public var afterEvent: Int
    }

    public var name: String
    public var tree: [Item]
    public var paste: Paste
    public var policy: Policy
    /// Answers to runtime questions in the order asked; "skip" once they run out.
    public var answers: [String]?
    public var stopAt: StopPoint?

    /// The reference's outcome. `result` and `questions` are kept as raw JSON for now.
    public struct Outcome: Decodable, Sendable {
        public var before: [TreeSnapshot.Entry]
        public var after: [TreeSnapshot.Entry]
        public var statuses: [String]
    }

    public struct BuildFailure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Makes the scenario's tree under `root`, as run.ts does: items in order, then modes and flags
    /// deepest first.
    public func build(in root: String) throws {
        for item in tree {
            let path = root + "/" + item.path
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            switch item.kind {
            case "file":
                guard FileManager.default.createFile(atPath: path, contents: Data((item.content ?? "").utf8)) else {
                    throw BuildFailure(description: "can't make \(path)")
                }
            case "dir":
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            case "symlink":
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: item.target ?? "")
            default:
                throw BuildFailure(description: "unknown kind \(item.kind)")
            }
        }
        for item in tree.reversed() where item.kind != "symlink" {
            let path = root + "/" + item.path
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
}
