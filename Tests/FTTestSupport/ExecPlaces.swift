// Port of tools/parity/exec/places.ts: where a scenario runs. A fresh work folder holds the
// scenario's tree ("$ROOT"), a Trash folder ("$TRASH") and the journal file; top-level folders the
// scenario puts on another disk get a tree and a Trash on a mounted copy of a blank disk image.
import Darwin
import Foundation

public struct ExecPlaces: Sendable {
    public struct Volume: Sendable {
        /// The scenario's top-level folder that lives there ("destination").
        public let folder: String
        /// "apfs", "apfs-cs", "hfs", "fat32" or "exfat".
        public let format: String
        public let mount: String
        public let root: String
        public let trash: String
    }

    public let work: String
    /// The scenario's tree on the startup disk.
    public let root: String
    /// The Trash for items on the startup disk.
    public let trash: String
    /// The journal file the engine keeps (replace-journal.json), not made yet.
    public let journal: String
    public let volumes: [Volume]

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Makes the folders for `scenario`, attaching the disk images it names.
    public static func make(for scenario: ExecScenario) throws -> ExecPlaces {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let work = base.appendingPathComponent("ft-parity-\(UUID().uuidString)").path
        for folder in ["tree", "trash", "journal"] {
            try FileManager.default.createDirectory(atPath: work + "/" + folder, withIntermediateDirectories: true)
        }
        var volumes: [Volume] = []
        let names = (scenario.volumes ?? [:]).keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for folder in names {
            let format = scenario.volumes?[folder] ?? ""
            let mount = try ExecDiskImages.mount(format)
            let scenarioBase = mount + "/scenario-\(getpid())-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: scenarioBase + "/tree", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: scenarioBase + "/trash", withIntermediateDirectories: true)
            volumes.append(
                Volume(folder: folder, format: format, mount: mount, root: scenarioBase + "/tree", trash: scenarioBase + "/trash"))
        }
        return ExecPlaces(
            work: work, root: work + "/tree", trash: work + "/trash", journal: work + "/journal/replace-journal.json",
            volumes: volumes)
    }

    /// The absolute path of a scenario path ("destination/a.txt").
    public func resolve(_ relative: String) -> String {
        let top = relative.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? relative
        let base = volumes.first { $0.folder == top }?.root ?? root
        return base + "/" + relative
    }

    /// The Trash folder for an item at `path` (its disk's).
    public func trashFor(_ path: String) -> String {
        volumes.first { path.hasPrefix($0.mount + "/") }?.trash ?? trash
    }

    /// For ExecNormalize: each place and its token.
    public var tokens: [ExecNormalize.Place] {
        var places = [
            ExecNormalize.Place(path: root, token: "$ROOT"),
            ExecNormalize.Place(path: trash, token: "$TRASH"),
            ExecNormalize.Place(path: work + "/journal", token: "$JOURNAL"),
        ]
        for volume in volumes {
            places.append(ExecNormalize.Place(path: volume.root, token: "$ROOT"))
            places.append(ExecNormalize.Place(path: volume.trash, token: "$TRASH"))
        }
        return places
    }

    /// What the scenario's tree holds now, wherever its folders are.
    public func snapshotTree() throws -> [TreeSnapshot.Entry] {
        try Self.snapshot([root] + volumes.map(\.root))
    }

    /// What the Trash folders hold now.
    public func snapshotTrash() throws -> [TreeSnapshot.Entry] {
        try Self.snapshot([trash] + volumes.map(\.trash))
    }

    /// The journal file's contents, or [] when it was never written.
    public func readJournal() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: journal) else { return .array([]) }
        return try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: journal)))
    }

    /// Clears locks, opens every folder to its owner, and removes the work folder and the
    /// scenario's folders on disk images.
    public func remove() {
        for folder in [work] + volumes.map({ ($0.root as NSString).deletingLastPathComponent }) {
            Self.open(folder)
            try? FileManager.default.removeItem(atPath: folder)
        }
    }

    private static func open(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        lchflags(path, 0)
        if info.st_mode & S_IFMT == S_IFDIR {
            chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                open(path + "/" + name)
            }
        }
    }

    /// Snapshots of several roots, merged and sorted. Folders the owner can't list and files the
    /// owner can't read are opened for the snapshot and closed again, and keep their own mode in it.
    static func snapshot(_ roots: [String]) throws -> [TreeSnapshot.Entry] {
        var entries: [TreeSnapshot.Entry] = []
        for root in roots {
            var opened: [(relative: String, mode: mode_t)] = []
            defer {
                for item in opened.reversed() {
                    chmod(root + "/" + item.relative, item.mode)
                }
            }
            try openForSnapshot(root: root, relative: "", opened: &opened)
            let modes = Dictionary(
                opened.map { ($0.relative.decomposedStringWithCanonicalMapping, $0.mode) }, uniquingKeysWith: { a, _ in a })
            for var entry in try TreeSnapshot.entries(of: root) {
                if let mode = modes[entry.path] {
                    let digits = String(mode, radix: 8)
                    entry.mode = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
                }
                entries.append(entry)
            }
        }
        return entries.sorted { $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }
    }

    private static func openForSnapshot(root: String, relative: String, opened: inout [(relative: String, mode: mode_t)]) throws {
        let folder = relative.isEmpty ? root : root + "/" + relative
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            let path = root + "/" + childRelative
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Failure(description: "lstat(\(path)) failed") }
            let mode = info.st_mode & 0o7777
            let kind = info.st_mode & S_IFMT
            let needed: mode_t = kind == S_IFDIR ? 0o500 : kind == S_IFREG ? 0o400 : 0
            if mode & needed != needed {
                guard chmod(path, mode | needed) == 0 else { throw Failure(description: "can't open \(path) to snapshot it") }
                opened.append((childRelative, mode))
            }
            if kind == S_IFDIR {
                try openForSnapshot(root: root, relative: childRelative, opened: &opened)
            }
        }
    }
}

/// Copy-on-write clones of the blank disk images (tools/fixtures/disk-images.sh), each attached
/// once per process and detached when it exits.
public enum ExecDiskImages {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var mounts: [String: String] = [:]
        var folder: String?
    }

    private static let state = State()

    public static var blankImages: String {
        let cache =
            ProcessInfo.processInfo.environment["FILETRAIL_PORT_CACHE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/filetrail-port"
        return cache + "/fixtures/disks"
    }

    /// Whether the blank image for `format` exists.
    public static func isAvailable(_ format: String) -> Bool {
        FileManager.default.fileExists(atPath: blankImages + "/\(format).sparseimage")
    }

    /// Where the clone of `format` is mounted, attaching it the first time.
    public static func mount(_ format: String) throws -> String {
        state.lock.lock()
        defer { state.lock.unlock() }
        if let mount = state.mounts[format] {
            return mount
        }
        let blank = blankImages + "/\(format).sparseimage"
        guard FileManager.default.fileExists(atPath: blank) else {
            throw ExecPlaces.Failure(description: "no \(blank): run tools/fixtures/disk-images.sh")
        }
        if state.folder == nil {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            let folder = base.appendingPathComponent("ft-parity-disks-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            state.folder = folder
            atexit { ExecDiskImages.detachAll() }
        }
        let folder = state.folder ?? ""
        let image = folder + "/\(format).sparseimage"
        let mount = folder + "/" + format
        try run("/bin/cp", ["-c", blank, image])
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mount, image])
        state.mounts[format] = mount
        return mount
    }

    /// Detaches every image attached here and removes the clones.
    public static func detachAll() {
        state.lock.lock()
        defer { state.lock.unlock() }
        for mount in state.mounts.values {
            try? run("/usr/bin/hdiutil", ["detach", "-force", mount])
        }
        state.mounts = [:]
        if let folder = state.folder {
            try? FileManager.default.removeItem(atPath: folder)
            state.folder = nil
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExecPlaces.Failure(description: "\(tool) \(arguments.joined(separator: " ")) failed: \(message)")
        }
    }
}
