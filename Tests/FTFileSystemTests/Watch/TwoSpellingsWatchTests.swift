import FTFoundation
import FTTestSupport
import Foundation
import Testing

// Two folders whose names differ only in how an accent is spelled, which a disk can keep side by side: a window
// watches the one it shows, and a change in one is told of as that one's
@testable import FTFileSystem

private let composed = "/x/caf\u{E9}"
private let decomposed = "/x/cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

/// The watches with a stand-in for the streams: each watch started is kept with its folder as it was given.
@MainActor
private final class Streams {
    struct Stream {
        var path: DiskPath
        var onChange: @MainActor (String?) -> Void
        var isStopped = false
    }

    let scheduler = ManualScheduler()
    var streams: [Stream] = []
    var changes: [(windowID: Int, change: FolderChange)] = []
    var forgotten: [(path: String, changed: [String]?)] = []
    var watches: FolderWatches!

    init() {
        watches = FolderWatches(
            FolderWatches.Dependencies(
                watchFolder: { [self] path, onChange, _, onStart in
                    let index = streams.count
                    streams.append(Stream(path: DiskPath(path), onChange: onChange))
                    onStart()
                    return { [self] in MainActor.assumeIsolated { streams[index].isStopped = true } }
                },
                readModifiedTime: { _ in 1 },
                onFolderChanged: { [self] windowID, change in changes.append((windowID, change)) },
                forgetCachedListings: { [self] path, changed in forgotten.append((path, changed)) },
                scheduler: scheduler))
    }

    /// The folders watched now.
    var running: [DiskPath] { streams.filter { !$0.isStopped }.map(\.path) }

    /// A change of `name` in the folder watched at `path`.
    func change(_ path: String, _ name: String?) {
        for stream in streams where !stream.isStopped && stream.path == DiskPath(path) { stream.onChange(name) }
    }
}

@MainActor
struct TwoSpellingsWatchTests {
    // A window that goes from one folder to the other watches the other: it isn't taken for the folder it had.
    @Test func aWindowGoingToTheOtherFolderWatchesThatOne() {
        let streams = Streams()
        streams.watches.watch(windowID: 1, path: composed)
        #expect(streams.running == [DiskPath(composed)])
        streams.watches.watch(windowID: 1, path: decomposed)
        #expect(streams.running == [DiskPath(decomposed)])
        #expect(streams.watches.watchedPaths[1].map(DiskPath.init) == DiskPath(decomposed))
        // The same folder again keeps the watch it has.
        streams.watches.watch(windowID: 1, path: decomposed)
        #expect(streams.streams.count == 2)
        streams.watches.stopAll()
    }

    // A change in one folder is told to the window showing it, as that folder's, and its listings alone are let go.
    @Test func aChangeInOneFolderIsToldAsThatFolders() {
        let streams = Streams()
        streams.watches.watch(windowID: 1, path: composed)
        streams.watches.watch(windowID: 2, path: decomposed)
        streams.change(decomposed, "new.txt")
        streams.scheduler.advance(by: FolderWatches.settleMilliseconds)
        #expect(streams.changes.map(\.windowID) == [2])
        #expect(bytes(streams.changes.map(\.change.path)) == bytes([decomposed]))
        #expect(bytes(streams.changes.first?.change.changedPaths ?? []) == bytes([decomposed + "/new.txt"]))
        #expect(bytes(streams.forgotten.map(\.path)) == bytes([decomposed]))
        streams.watches.stopAll()
    }

    // What watching one folder covers changed: its watches start again, and the other folder's are left alone.
    @Test func startingOneFoldersWatchesAgainLeavesTheOthers() {
        let streams = Streams()
        streams.watches.watch(windowID: 1, path: composed)
        streams.watches.watch(windowID: 2, path: decomposed)
        streams.watches.restartWatches(of: composed)
        #expect(streams.streams.count == 3)
        #expect(streams.streams.map(\.isStopped) == [true, false, false])
        #expect(streams.streams.last?.path == DiskPath(composed))
        streams.scheduler.advance(by: FolderWatches.settleMilliseconds)
        #expect(streams.changes.map(\.windowID) == [1])
        streams.watches.stopAll()
    }

    // Two items of the folder named alike but for an accent's spelling both changed: both are named.
    @Test func twoItemsNamedAlikeAreBothToldOf() {
        let streams = Streams()
        streams.watches.watch(windowID: 1, path: "/x")
        streams.change("/x", "caf\u{E9}")
        streams.change("/x", "cafe\u{301}")
        streams.change("/x", "caf\u{E9}")
        streams.scheduler.advance(by: FolderWatches.settleMilliseconds)
        #expect(bytes(streams.changes.first?.change.changedPaths ?? []) == bytes([composed, decomposed]))
        #expect(bytes(streams.forgotten.first?.changed ?? []) == bytes([composed, decomposed]))
        streams.watches.stopAll()
    }
}

/// The stream on real folders: FSEvents names what changed as `realpath` names the folder, byte for byte, so a
/// folder with an accent in its name is told of its changes however the disk keeps the accent. (One folder can't hold
/// both spellings on this Mac's disk, so each has a folder of its own to be in.)
@MainActor
struct AccentedFolderStreamTests {
    /// Writes `text` to the file at `path`, named byte for byte as given: Foundation would spell the accents apart.
    private func write(_ text: String, to path: String) {
        let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard file >= 0 else { return }
        _ = text.withCString { Darwin.write(file, $0, strlen($0)) }
        close(file)
    }

    @Test(arguments: [true, false])
    func aFolderWithAnAccentInItsNameIsToldOfItsChanges(composedAccents: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let name = composedAccents ? "caf\u{E9}" : "cafe\u{301}"
            let made = DiskPath(directory.path).appending(name).string
            guard mkdir(made, 0o755) == 0 else {
                Issue.record("the folder couldn't be made")
                return
            }
            // The folder as a listing gives it: the path the window watches. The disk keeps the name as it was given.
            let folder = try NativeFileSystem().realpath(made)
            #expect(Array(DiskPath(folder).name.utf8) == Array(name.utf8))
            let item = composedAccents ? "\u{E9}t\u{E9}.txt" : "e\u{301}te\u{301}.txt"
            var told: [FolderChange] = []
            let watches = FolderWatches(.app(cache: ResponseCache()) { _, change in told.append(change) })
            watches.watch(windowID: 1, path: folder)
            defer { watches.stopAll() }
            // A stream is started in its own time, and a change made before it runs is never told: the file is
            // written until it is told of.
            let deadline = ContinuousClock.now + .seconds(8)
            var attempt = 0
            func isTold() -> Bool {
                told.contains { change in
                    change.changedPaths?.contains { DiskPath($0) == DiskPath(folder).appending(item) } == true
                }
            }
            while !isTold() && ContinuousClock.now < deadline {
                write("probe \(attempt)", to: folder + "/" + item)
                attempt += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
            #expect(isTold(), "told: \(told.map { $0.changedPaths ?? ["<anything>"] })")
            // The item is told of under the name its folder's listing gives it.
            let listed = try NativeFileSystem().readDirectory(folder).map(\.name)
            #expect(bytes(listed) == bytes([item]))
        }
    }
}
