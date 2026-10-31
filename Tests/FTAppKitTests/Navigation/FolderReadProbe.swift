// A file system for the matrix tests of the folder on screen: its reads can be held, counted and refused
import AppKit
import FTFileSystem
import FTFoundation
import Foundation

@testable import FTAppKit

/// Holds the reads of a folder until the test lets them go, counts them, and can refuse them.
final class FolderReadProbe: ExplorerFileSystem, @unchecked Sendable {
    private struct Refused: Error {}

    private let real = NativeFileSystem()
    private let condition = NSCondition()
    private var held: Set<String> = []
    private var refused: Set<String> = []
    private var waiting = 0
    private var counts: [String: Int] = [:]
    private var propertyReads: [String: Int] = [:]

    func hold(_ path: String) {
        condition.withLock { _ = held.insert(path) }
    }

    func letGo() {
        condition.withLock {
            held = []
            condition.broadcast()
        }
    }

    func refuse(_ path: String?) {
        condition.withLock { refused = path.map { [$0] } ?? [] }
    }

    var isHolding: Bool { condition.withLock { waiting > 0 } }

    func reads(of path: String) -> Int { condition.withLock { counts[path] ?? 0 } }

    /// How many times an item's own details were asked for (what the Info panel reads).
    func detailReads(of path: String) -> Int { condition.withLock { propertyReads[path] ?? 0 } }

    private func wait(_ path: String) throws {
        condition.lock()
        defer { condition.unlock() }
        if refused.contains(path) { throw Refused() }
        guard held.contains(path) else { return }
        waiting += 1
        while held.contains(path) { condition.wait() }
        waiting -= 1
    }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        try wait(path)
        condition.withLock { counts[path, default: 0] += 1 }
        return try real.readDirectory(path)
    }

    func stat(_ path: String) throws -> FileStats {
        try wait(path)
        return try real.stat(path)
    }

    func lstat(_ path: String) throws -> FileStats {
        condition.withLock { propertyReads[path, default: 0] += 1 }
        return try real.lstat(path)
    }

    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

extension ExplorerHarness {
    /// The tab reads its folders through `probe` from now on.
    @MainActor
    func reading(through probe: FolderReadProbe, in tab: MainWindowController) {
        tab.servicesOverride = ExplorerServices(
            directoryService: DirectoryService(fileSystem: probe), folderWatches: nil, iconStore: nil,
            volumeWatcher: nil, clipboard: windows.clipboard, preferences: channel)
    }
}
