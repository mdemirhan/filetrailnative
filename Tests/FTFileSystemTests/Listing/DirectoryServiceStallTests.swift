import FTTestSupport
import Foundation
import Testing

// A folder whose read never answers (a network share that stopped responding) holds up nothing but itself.
@testable import FTFileSystem

/// Holds every look at a path under /slow until the test lets them go, as a stalled disk would.
private final class DiskGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var held = 0

    func hold() {
        condition.lock()
        held += 1
        while !open { condition.wait() }
        condition.unlock()
    }

    /// How many looks at the disk are being held now or were.
    var holding: Int {
        condition.lock()
        defer { condition.unlock() }
        return held
    }

    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// What the windows ask the directory service for.
enum DirectoryRequest: CaseIterable, Sendable {
    case listing, tree, properties, suggestions, hiddenFlag, details

    func run(_ service: DirectoryService, folder: String) async {
        switch self {
        case .listing: _ = try? await service.snapshot(path: folder)
        case .tree: _ = try? await service.treeChildren(path: folder)
        case .properties: _ = await service.itemProperties(path: folder + "/a.txt")
        case .suggestions: _ = try? await service.pathSuggestions(inputPath: folder + "/")
        case .hiddenFlag: _ = await service.hasHiddenFlag(path: folder)
        case .details: _ = try? await service.metadata(directoryPath: folder, paths: [folder + "/a.txt"])
        }
    }
}

struct DirectoryServiceStallTests {
    /// /fast holds a file and a folder. A read of /slow waits for `gate` and finds one file named by `version` as it
    /// was when the read started; with `holdsLookups`, every other look under /slow waits too.
    private func fileSystem(
        gate: DiskGate, reads: CallCounter, version: VersionBox = VersionBox(), holdsLookups: Bool = true
    ) -> FakeFileSystem {
        let fake = FakeFileSystem()
        let isSlow: @Sendable (String) -> Bool = { $0 == "/slow" || $0.hasPrefix("/slow/") }
        let stats: @Sendable (String) -> FileStats = { path in
            if holdsLookups && isSlow(path) { gate.hold() }
            let isFolder = path == "/fast" || path == "/slow" || path.hasSuffix("/Sub")
            return fakeStats(directory: isFolder, file: !isFolder, size: 4)
        }
        fake.statHandler = stats
        fake.lstatHandler = stats
        fake.realpathHandler = { path in
            if holdsLookups && isSlow(path) { gate.hold() }
            return path
        }
        fake.directory = { path in
            guard isSlow(path) else { return [fakeDirent("a.txt", file: true), fakeDirent("Sub", directory: true)] }
            reads.add()
            let name = "version-\(version.value).txt"
            gate.hold()
            return [fakeDirent(name, file: true)]
        }
        return fake
    }

    private func service(_ fake: FakeFileSystem) -> DirectoryService {
        DirectoryService(fileSystem: fake, cache: ResponseCache(), kinds: KindLabeler(describer: nil))
    }

    @Test(arguments: DirectoryRequest.allCases)
    func aHeldReadOfOneFolderLetsEveryRequestForAnotherFinish(held: DirectoryRequest) async {
        let gate = DiskGate()
        let service = service(fileSystem(gate: gate, reads: CallCounter()))
        let slow = Task { await held.run(service, folder: "/slow") }
        await pollUntil { gate.holding > 0 }

        let others = DirectoryRequest.allCases.map { request in
            let finished = Flag()
            let task = Task {
                await request.run(service, folder: "/fast")
                finished.set()
            }
            return (request, finished, task)
        }
        await pollUntil(timeout: .seconds(10)) { others.allSatisfy { $0.1.isSet } }
        for (request, finished, _) in others {
            #expect(finished.isSet, "\(request) of another folder waited for the held \(held)")
        }

        gate.release()
        await slow.value
        for (_, _, task) in others { await task.value }
    }

    @Test func aListingAskedForAfterAWriteDoesNotTakeTheAnswerOfAReadFromBefore() async throws {
        let gate = DiskGate()
        let reads = CallCounter()
        let version = VersionBox()
        let service = service(fileSystem(gate: gate, reads: reads, version: version, holdsLookups: false))
        let before = Task { try await service.snapshot(path: "/slow") }
        await pollUntil { gate.holding > 0 }

        version.value = 2
        service.cache.clear()
        let after = Task { try await service.snapshot(path: "/slow") }
        await pollUntil { gate.holding > 1 }
        gate.release()

        #expect(try await after.value.entries.map(\.name) == ["version-2.txt"])
        #expect(try await before.value.entries.map(\.name) == ["version-1.txt"])
        // What the read from before the write found is not kept.
        #expect(try await service.snapshot(path: "/slow").entries.map(\.name) == ["version-2.txt"])
        #expect(reads.count == 2)
    }
}

private final class VersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 1

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}
