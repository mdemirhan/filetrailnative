import Foundation
import Testing

@testable import FTFileSystem

func testVolume(
    _ name: String, isLocal: Bool = true, isReadOnly: Bool = false, fileSystem: String = "apfs",
    canEject: Bool = true, disk: String? = "disk4"
) -> Volume {
    Volume(
        path: "/Volumes/\(name)", name: name, isLocal: isLocal, isReadOnly: isReadOnly, fileSystem: fileSystem,
        canEject: canEject, disk: disk)
}

/// Stands in for the folder watch and the timers, as the original's test does.
@MainActor private final class WatcherHarness {
    var mounted: [Volume]
    var folderChanged: (@MainActor () -> Void)?
    var timers: [Int: @MainActor () -> Void] = [:]
    var nextTimer = 0
    var changes: [[Volume]] = []
    var stopped = 0
    var watcher: VolumeWatcher!

    init(_ initial: [Volume]) {
        mounted = initial
        watcher = VolumeWatcher(
            VolumeWatcher.Dependencies(
                listVolumes: { [unowned self] in mounted },
                watchVolumesFolder: { [unowned self] onChange in
                    folderChanged = onChange
                    return { [unowned self] in stopped += 1 }
                },
                onVolumesChanged: { [unowned self] volumes in changes.append(volumes) },
                schedule: { [unowned self] _, callback in
                    nextTimer += 1
                    timers[nextTimer] = callback
                    return nextTimer
                },
                cancel: { [unowned self] handle in timers[handle] = {} }))
    }

    func settle() {
        let due = timers
        timers = [:]
        for key in due.keys.sorted() { due[key]?() }
    }
}

@MainActor @Suite struct VolumeWatcherTests {
    // T-b6961199
    @Test func listsDisksByNameNumbersInOrderAndLetterCaseAside() {
        let sorted = Volume.sorted([
            testVolume("disk 10"), testVolume("Backup"), testVolume("disk 9"), testVolume("archive"),
        ])
        #expect(sorted.map(\.name) == ["archive", "Backup", "disk 9", "disk 10"])
    }

    // T-ee02ae02
    @Test func readsTheListOnceABurstOfChangesSettlesAndTellsOfRealChangesOnly() {
        let harness = WatcherHarness([testVolume("Backup")])
        #expect(harness.watcher.getVolumes().map(\.name) == ["Backup"])

        harness.mounted = [testVolume("Backup"), testVolume("Archive")]
        harness.folderChanged?()
        harness.folderChanged?()
        #expect(harness.changes.isEmpty)
        harness.settle()
        #expect(harness.changes.count == 1)
        #expect(harness.watcher.getVolumes().map(\.name) == ["Archive", "Backup"])

        // /Volumes changed, but not the disks on it.
        harness.folderChanged?()
        harness.settle()
        #expect(harness.changes.count == 1)
    }

    // T-a8c12efd
    @Test func findsADiskTheWatchMissedWhenAskedToLookAgain() {
        let harness = WatcherHarness([])
        let install = testVolume("Install Xcode", isReadOnly: true, fileSystem: "hfs")
        harness.mounted = [install]
        harness.watcher.refresh()
        #expect(harness.changes == [[install]])
    }

    // T-997a880a
    @Test func stopsWatchingAndDropsAChangeStillSettling() {
        let harness = WatcherHarness([])
        harness.mounted = [testVolume("Backup")]
        harness.folderChanged?()
        harness.watcher.stop()
        harness.settle()
        #expect(harness.stopped == 1)
        #expect(harness.changes.isEmpty)
    }

    @Test func aListThatCannotBeReadIsEmpty() {
        struct Unreadable: Error {}
        let watcher = VolumeWatcher(
            VolumeWatcher.Dependencies(
                listVolumes: { throw Unreadable() }, watchVolumesFolder: { _ in {} }, onVolumesChanged: { _ in }))
        #expect(watcher.getVolumes().isEmpty)
    }
}
