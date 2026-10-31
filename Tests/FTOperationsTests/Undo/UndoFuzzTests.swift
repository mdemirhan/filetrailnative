// Port of apps/desktop/src/main/bootstrap/undo.fuzz.test.ts: random runs of renames, batch renames, new folders, Trash,
// copies, moves and Replaces on a real disk, then Undo all the way back and Redo all the way forward:
// - With nothing changed in between, Undo gets back every item as it was (path, kind and file id), and Redo gets back
//   the end.
// - With random changes made outside the app between them, no item is ever lost or replaced, every item left as it
//   was says why, and nothing stays under a hidden name; and the same for Redo after more changes.
// - With writes that fail (no permission) and Undos stopped part way, trying again gets back to the start and Redo to
//   the end; with failures that look like changes outside (a name taken, an item gone), nothing is lost or replaced.
// The cases come from seeds, so a failure names the seed that makes it again.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// mulberry32 (`random` in batchRenameMemoryDisk.testkit.ts), shared by the test and the disk threads it holds up.
final class FuzzRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    func next() -> Double {
        lock.withLock {
            state = state &+ 0x6D2B_79F5
            var value = state
            value = (value ^ (value >> 15)) &* (value | 1)
            value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }
    }

    func chance(_ probability: Double) -> Bool { next() < probability }

    func integer(_ least: Int, _ most: Int) -> Int { least + Int((next() * Double(most - least + 1)).rounded(.down)) }

    func pick<T>(_ items: [T]) -> T { items[integer(0, items.count - 1)] }

    func shuffle<T>(_ items: [T]) -> [T] {
        var shuffled = items
        var index = shuffled.count - 1
        while index > 0 {
            let other = integer(0, index)
            shuffled.swapAt(index, other)
            index -= 1
        }
        return shuffled
    }
}

/// Writes that fail on their own, with these error codes, and Undos stopped after a write.
struct FuzzFailures: Sendable {
    var codes: [String]
    var chance: Double
    var stopChance: Double
}

/// One fuzzed case (`Case`).
@MainActor
final class UndoFuzzCase {
    enum Operation: String, CaseIterable {
        case rename, newFolder, trash, batch, copy, move, replace
    }

    struct Item {
        var path: String
        var isFolder: Bool
    }

    static let keepBoth = CopyPastePolicy(file: .keepBoth, directory: .keepBoth, mismatch: .keepBoth)

    let directory: TemporaryDirectory
    let root: String
    let trashDir: String
    let pasteTrashDir: String
    let history = UndoHistory()
    let window = TestWindow()
    let random: FuzzRandom
    var coordinator: WriteCoordinator!
    // One for the whole case: its Trash numbers items, so two never take one name there.
    let pasteFileSystem: NativeWriteFileSystem
    var log: [String] = []
    private var names = 0
    private var outsideNames = 0
    /// While set, the app's writes fail and stop at random (the operations themselves run before it is set, so only
    /// Undo and Redo meet it).
    private let failures = FuzzLocked<FuzzFailures?>(nil)

    init(seed: Int) throws {
        random = FuzzRandom(seed: UInt32(seed))
        directory = try TemporaryDirectory(prefix: "filetrail-undo-fuzz")
        root = directory.path
        trashDir = root + "/.Trash"
        pasteTrashDir = root + "/.PasteTrash"
        pasteFileSystem = NativePaste.withTrash(pasteTrashDir)
        try UndoDisk.mkdir(trashDir)
        try UndoDisk.mkdir(pasteTrashDir)
        for folder in ["A", "A/Sub", "B", "C"] { try UndoDisk.mkdir("\(root)/\(folder)") }
        for file in ["A/x.txt", "A/y.txt", "A/Sub/x.txt", "B/x.txt", "B/z.txt"] {
            try UndoDisk.write("\(root)/\(file)", file)
        }
        let fileSystem = UndoTestFileSystem(trashDir: trashDir)
        let base = fileSystem.base
        let failOrStop = makeFailOrStop()
        fileSystem.renameExclusiveImpl = { from, to in
            _ = try failOrStop(from) {
                try base.renameExclusive(from, to)
                return nil
            }
        }
        fileSystem.renameImpl = { from, to in
            _ = try failOrStop(from) {
                try base.rename(from, to)
                return nil
            }
        }
        fileSystem.trashImpl = { path in try failOrStop(path) { try base.trash?(path) ?? nil } }
        coordinator = WriteCoordinator(
            writeService: StubWriteService(), fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: root, recordUndo: { [history] in history.record($0) }, undoHistory: history))
    }

    func setFailures(_ value: FuzzFailures?) {
        failures.value = value
    }

    /// `failOrStop`: a write that may fail before it starts, or stop the operation once it is done.
    private func makeFailOrStop() -> @Sendable (String, () throws -> String?) throws -> String? {
        let failures = failures
        let random = random
        return { [weak self] path, write in
            let now = failures.value
            if let now, !NodePath.basename(path).hasPrefix(".filetrail"), random.chance(now.chance) {
                let code = random.pick(now.codes)
                throw codedError(code, "\(code): failed on purpose")
            }
            let written = try write()
            if let now, random.chance(now.stopChance) {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard let self, let running = self.coordinator.activeOperation else { return }
                        self.coordinator.cancel(running.operationId, window: self.window)
                    }
                }
            }
            return written
        }
    }

    func dispose() async {
        await coordinator.shutDown(maxWaitMs: 0)
        directory.remove()
    }

    private func relative(_ path: String) -> String {
        path == root ? "" : String(path.dropFirst(root.count + 1))
    }

    /// Every item but the Trash folders, as "path kind id".
    func snapshot() -> [String] {
        items().map { "\(relative($0.path)) \($0.isFolder ? "dir" : "file") \(UndoDisk.ino($0.path) ?? 0)" }
    }

    func items(_ folder: String? = nil) -> [Item] {
        var found: [Item] = []
        for name in UndoDisk.names(folder ?? root) {
            let path = "\(folder ?? root)/\(name)"
            if path == trashDir || path == pasteTrashDir { continue }
            let isFolder = UndoDisk.isDirectory(path)
            found.append(Item(path: path, isFolder: isFolder))
            if isFolder { found += items(path) }
        }
        return found
    }

    /// Every file id anywhere under the root, the Trash folders included.
    func ids(_ folder: String? = nil) -> Set<UInt64> {
        var ids: Set<UInt64> = []
        for name in UndoDisk.names(folder ?? root) {
            let path = "\(folder ?? root)/\(name)"
            if let ino = UndoDisk.ino(path) { ids.insert(ino) }
            if UndoDisk.isDirectory(path) { ids.formUnion(self.ids(path)) }
        }
        return ids
    }

    func hiddenLeftovers(_ folder: String? = nil) -> [String] {
        var found: [String] = []
        for name in UndoDisk.names(folder ?? root) {
            let path = "\(folder ?? root)/\(name)"
            if name.hasPrefix(".filetrail") { found.append(relative(path)) }
            if UndoDisk.isDirectory(path) { found += hiddenLeftovers(path) }
        }
        return found
    }

    func folders() -> [String] {
        [root] + items().filter(\.isFolder).map(\.path)
    }

    func freshName() -> String {
        names += 1
        return "n\(names)"
    }

    func finish(_ start: () async throws -> WriteOperationHandle) async throws -> WriteOperationEvent? {
        guard let handle = try? await start() else {
            // Refused before it started (a name taken, say): nothing happened.
            return nil
        }
        let deadline = Date().addingTimeInterval(20)
        while true {
            if let end = window.end(of: handle.operationId) { return end }
            if Date() >= deadline { throw OperationError("Timed out waiting for the end of the operation.") }
            try await Task.sleep(nanoseconds: 200_000)
        }
    }

    /// One random operation the person could make. Says which kind, when it went into the history.
    func operate() async throws -> Operation? {
        let before = history.generation
        let kind = try await operateOnce()
        return history.generation != before ? kind : nil
    }

    private func operateOnce() async throws -> Operation {
        let items = items()
        let kind = random.pick(Operation.allCases)
        let item = items.isEmpty ? nil : random.pick(items)
        switch kind {
        case .rename:
            guard let item else { return kind }
            let name = random.chance(0.2) ? NodePath.basename(item.path).uppercased() : freshName()
            log.append("rename \(relative(item.path)) -> \(name)")
            _ = try await finish {
                try await coordinator.rename(sourcePath: item.path, destinationName: name, window: window)
            }
        case .newFolder:
            let parent = random.pick(folders())
            let name = freshName()
            log.append("new folder \(relative("\(parent)/\(name)"))")
            _ = try await finish {
                try await coordinator.createFolder(parentDirectoryPath: parent, folderName: name, window: window)
            }
        case .trash:
            guard !items.isEmpty else { return kind }
            let picked = Array(random.shuffle(items).prefix(random.integer(1, 2))).map(\.path)
            log.append("trash \(picked.map(relative).joined(separator: ", "))")
            _ = try await finish { try await coordinator.trash(paths: picked, window: window) }
        case .batch:
            let folder = random.pick(folders())
            let children = items.filter { NodePath.dirname($0.path) == folder }
            guard !children.isEmpty else { return kind }
            let picked = Array(random.shuffle(children).prefix(random.integer(1, 3)))
            let swap = picked.count >= 2 && random.chance(0.5)
            let renames = picked.enumerated().map { index, each in
                BatchRenameRequest.Item(
                    sourcePath: each.path,
                    destinationName: swap ? NodePath.basename(picked[(index + 1) % picked.count].path) : freshName(),
                    isFolder: each.isFolder)
            }
            log.append(
                "batch \(renames.map { "\(relative($0.sourcePath))->\($0.destinationName)" }.joined(separator: ", "))")
            _ = try await finish {
                try await coordinator.batchRename(
                    BatchRenameRequest(items: renames, onConflict: .number, numberSeparator: " "), window: window)
            }
        case .copy, .move, .replace:
            guard let item else { return kind }
            let into = folders().filter { folder in
                folder != item.path && !folder.hasPrefix("\(item.path)/")
                    && (kind == .copy || folder != NodePath.dirname(item.path))
            }
            let targets =
                kind == .replace
                ? into.filter { folder in
                    let there = "\(folder)/\(NodePath.basename(item.path))"
                    return UndoDisk.exists(there) && UndoDisk.isDirectory(there) == item.isFolder
                } : into
            guard !targets.isEmpty else { return kind }
            let destination = random.pick(targets)
            let mode: CopyPasteMode = kind == .copy || (kind == .replace && random.chance(0.5)) ? .copy : .cut
            log.append("\(kind.rawValue) (\(mode.rawValue)) \(relative(item.path)) -> \(relative(destination))")
            let run = try await runPaste(
                mode: mode, sources: [item.path], into: destination,
                policy: kind == .replace ? NativePaste.replaceAll : Self.keepBoth, fileSystem: pasteFileSystem)
            if let result = run.result, let undoLog = result.undoLog {
                var changed = true
                if case .undoable(let units) = undoLog, units.isEmpty { changed = false }
                if changed {
                    history.record(
                        FinishedWrite(
                            action: .write(kind == .copy ? .copyTo : kind == .move ? .moveTo : .paste), log: undoLog,
                            items: result.items.map(WriteOperationItem.init)))
                }
            }
        }
        return kind
    }

    /// One random change made outside the app: what it removed for good, if anything.
    func changeOutside() throws -> Set<UInt64> {
        let items = items()
        var removed: Set<UInt64> = []
        guard !items.isEmpty else { return removed }
        let item = random.pick(items)
        switch random.integer(0, 4) {
        case 0:
            if item.isFolder { removed.formUnion(ids(item.path)) }
            if let ino = UndoDisk.ino(item.path) { removed.insert(ino) }
            log.append("outside: delete \(relative(item.path))")
            try FileManager.default.removeItem(atPath: item.path)
        case 1:
            outsideNames += 1
            let name = "outside \(outsideNames)"
            log.append("outside: rename \(relative(item.path)) -> \(name)")
            try UndoDisk.move(item.path, "\(NodePath.dirname(item.path))/\(name)")
        case 2:
            // Something new under a name an item had, or may get back.
            let name = random.pick(["x.txt", "y.txt", "z.txt", "n1", "n2", "Sub"])
            let path = "\(NodePath.dirname(item.path))/\(name)"
            if !UndoDisk.exists(path) {
                log.append("outside: new \(relative(path))")
                try UndoDisk.write(path, "new outside")
            }
        case 3:
            if !item.isFolder {
                log.append("outside: edit \(relative(item.path))")
                try UndoDisk.write(item.path, "edited outside")
            }
        default:
            // The Trash emptied, in part.
            let inTrash = UndoDisk.names(trashDir)
            if !inTrash.isEmpty {
                let name = random.pick(inTrash)
                let all = ids(trashDir)
                log.append("outside: empty \(name) from the Trash")
                try FileManager.default.removeItem(atPath: "\(trashDir)/\(name)")
                // Ids of what is still there stay counted.
                removed.formUnion(all.subtracting(ids(trashDir)))
            }
        }
        return removed
    }

    /// `undoAll`: undoes (or redoes) until there is nothing left, as many times as it takes: what failed or was
    /// stopped stays on the list for the next try. With `toEnd` off, only `tries` times, and what is left stays.
    func undoAll(_ direction: UndoDirection, tries: Int = 50, toEnd: Bool = true) async throws
        -> [WriteOperationEvent]
    {
        var results: [WriteOperationEvent] = []
        for _ in 0..<tries {
            let prepared = try await coordinator.prepareUndo(direction)
            guard let ticket = prepared.ticket else { return results }
            if let end = try await finish({ try await coordinator.startUndo(ticket: ticket, window: window) }) {
                results.append(end)
            }
        }
        if !toEnd { return results }
        throw OperationError("Undo never ran out of things to undo.")
    }

    /// What an Undo did to each item, for the log.
    func describe(_ result: WriteOperationEvent) -> String {
        (result.result?.items ?? []).map {
            "[\($0.status.rawValue) \($0.sourcePath.map(relative) ?? "-") \($0.destinationPath.map(relative) ?? "-")]"
        }.joined(separator: " ")
    }
}

/// A value the test and the disk threads share.
final class FuzzLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
@Suite
struct UndoFuzzTests {
    static let firstSeed = Int(ProcessInfo.processInfo.environment["UNDO_FUZZ_SEED"] ?? "") ?? 1
    static let cases = Int(ProcessInfo.processInfo.environment["UNDO_FUZZ_CASES"] ?? "") ?? 60

    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private func fail(_ seed: Int, _ testCase: UndoFuzzCase, _ message: String) -> Failure {
        Failure(
            description:
                "\(message)\nReproduce: UNDO_FUZZ_SEED=\(seed) UNDO_FUZZ_CASES=1\n\(testCase.log.joined(separator: "\n"))"
        )
    }

    /// Runs `body` for each seed, each case in a fresh folder; the first failure names its seed.
    private func eachCase(_ body: (Int, UndoFuzzCase) async throws -> Void) async throws {
        for seed in Self.firstSeed..<(Self.firstSeed + Self.cases) {
            let testCase = try UndoFuzzCase(seed: seed)
            do {
                try await body(seed, testCase)
            } catch let failure as Failure {
                await testCase.dispose()
                throw failure
            } catch {
                await testCase.dispose()
                throw fail(seed, testCase, "Stopped: \(error)")
            }
            await testCase.dispose()
        }
    }

    /// `checkSaidWhy`: every item left as it was says why.
    private func checkSaidWhy(_ seed: Int, _ testCase: UndoFuzzCase, _ results: [WriteOperationEvent]) throws {
        for result in results {
            for item in result.result?.items ?? []
            where (item.status == .skipped || item.status == .failed) && (item.error ?? "").isEmpty {
                throw fail(seed, testCase, "An item was left without saying why: \(item)")
            }
        }
    }

    private func checkNoHiddenLeftovers(_ seed: Int, _ testCase: UndoFuzzCase) throws {
        let hidden = testCase.hiddenLeftovers()
        if !hidden.isEmpty {
            throw fail(seed, testCase, "Hidden items left: \(hidden.joined(separator: ", "))")
        }
    }

    private func checkBackTo(
        _ expected: [String], _ seed: Int, _ testCase: UndoFuzzCase, _ what: String
    ) throws {
        let now = testCase.snapshot()
        if now != expected {
            throw fail(
                seed, testCase,
                "\(what)\nExpected:\n\(expected.joined(separator: "\n"))\nNow:\n\(now.joined(separator: "\n"))")
        }
    }

    // T-053e685f F-560
    @Test func getsBackToTheStartAndRedoToTheEndWhenNothingElseChanges() async throws {
        var recorded: Set<UndoFuzzCase.Operation> = []
        var undoneOperations = 0
        try await eachCase { seed, testCase in
            let start = testCase.snapshot()
            for _ in 0..<testCase.random.integer(1, 6) {
                if let kind = try await testCase.operate() { recorded.insert(kind) }
            }
            let end = testCase.snapshot()
            // Undo goes back only as far as the last operation that can't be undone.
            let fullyUndoable = !testCase.history.menu().cantUndo
            let undone = try await testCase.undoAll(.undo)
            undoneOperations += undone.count
            for result in undone where result.status != .completed {
                throw fail(seed, testCase, "An Undo ended \"\(result.status)\": \(result.result?.error ?? "")")
            }
            if fullyUndoable { try checkBackTo(start, seed, testCase, "Undo didn't get back to the start.") }
            _ = try await testCase.undoAll(.redo)
            try checkBackTo(end, seed, testCase, "Redo didn't get back to the end.")
            try checkNoHiddenLeftovers(seed, testCase)
        }
        // Every kind of operation went into the history and was undone, in a run long enough.
        if Self.cases >= 50 {
            #expect(recorded == Set(UndoFuzzCase.Operation.allCases))
            #expect(undoneOperations > Self.cases)
        }
    }

    // T-0b68d61e F-560
    @Test func losesAndReplacesNothingAndSaysWhyItLeftAnythingWhenThingsChangeOutside() async throws {
        try await eachCase { seed, testCase in
            for _ in 0..<testCase.random.integer(1, 6) {
                _ = try await testCase.operate()
                if testCase.random.chance(0.3) { _ = try testCase.changeOutside() }
            }
            var removedOutside: Set<UInt64> = []
            for _ in 0..<testCase.random.integer(0, 3) { removedOutside.formUnion(try testCase.changeOutside()) }
            let before = testCase.ids()
            let undone = try await testCase.undoAll(.undo)
            let after = testCase.ids()
            for id in before where !removedOutside.contains(id) && !after.contains(id) {
                throw fail(seed, testCase, "An item (id \(id)) was lost by Undo.")
            }
            try checkSaidWhy(seed, testCase, undone)
            try checkNoHiddenLeftovers(seed, testCase)
            // And Redo of what was undone, after more changes outside.
            for _ in 0..<testCase.random.integer(0, 2) { removedOutside.formUnion(try testCase.changeOutside()) }
            let redone = try await testCase.undoAll(.redo)
            let afterRedo = testCase.ids()
            for id in before where !removedOutside.contains(id) && !afterRedo.contains(id) {
                throw fail(seed, testCase, "An item (id \(id)) was lost by Redo.")
            }
            try checkSaidWhy(seed, testCase, redone)
            try checkNoHiddenLeftovers(seed, testCase)
        }
    }

    // T-0a92469f F-560
    @Test func getsBackToTheStartAndRedoToTheEndThroughFailedWritesAndStops() async throws {
        var failed = 0
        var stopped = 0
        try await eachCase { seed, testCase in
            let start = testCase.snapshot()
            for _ in 0..<testCase.random.integer(1, 6) { _ = try await testCase.operate() }
            let end = testCase.snapshot()
            let fullyUndoable = !testCase.history.menu().cantUndo
            // No permission, or the Trash refusing, now and then: what failed stays on the list and is tried again by
            // the next Undo.
            testCase.setFailures(FuzzFailures(codes: ["EACCES", "EPERM"], chance: 0.2, stopChance: 0.1))
            let undone = try await testCase.undoAll(.undo, tries: 500)
            if fullyUndoable { try checkBackTo(start, seed, testCase, "Undo didn't get back to the start.") }
            let redone = try await testCase.undoAll(.redo, tries: 500)
            try checkBackTo(end, seed, testCase, "Redo didn't get back to the end.")
            for result in undone + redone {
                let items = result.result?.items ?? []
                if items.contains(where: { $0.status == .failed }) { failed += 1 }
                if result.status == .partial, result.result?.error?.hasPrefix("Stopped") == true { stopped += 1 }
                // Only what failed is left, never anything skipped: nothing changed outside.
                if items.contains(where: { $0.status == .skipped }) {
                    throw fail(seed, testCase, "An item was skipped: \(items)")
                }
            }
            try checkSaidWhy(seed, testCase, undone + redone)
            try checkNoHiddenLeftovers(seed, testCase)
        }
        if Self.cases >= 50 {
            #expect(failed > 0)
            #expect(stopped > 0)
        }
    }

    // T-89587020 F-560
    @Test func staysInStepWhenUndoAndRedoTakeTurnsThroughFailedWritesAndStops() async throws {
        var turns = 0
        try await eachCase { seed, testCase in
            let start = testCase.snapshot()
            for _ in 0..<testCase.random.integer(2, 6) { _ = try await testCase.operate() }
            let end = testCase.snapshot()
            let fullyUndoable = !testCase.history.menu().cantUndo
            // Undo or Redo, either, while what failed is still left on the other list.
            testCase.setFailures(FuzzFailures(codes: ["EACCES", "EPERM"], chance: 0.3, stopChance: 0.1))
            for _ in 0..<testCase.random.integer(2, 10) {
                let direction: UndoDirection = testCase.random.chance(0.6) ? .undo : .redo
                guard let result = try await testCase.undoAll(direction, tries: 1, toEnd: false).first else { continue }
                turns += 1
                testCase.log.append("\(direction.rawValue): \(result.status) \(testCase.describe(result))")
                // Only what failed is left, never anything skipped: nothing changed outside.
                if (result.result?.items ?? []).contains(where: { $0.status == .skipped }) {
                    throw fail(seed, testCase, "An item was skipped: \(result.result?.items ?? [])")
                }
            }
            testCase.setFailures(nil)
            _ = try await testCase.undoAll(.undo)
            if fullyUndoable { try checkBackTo(start, seed, testCase, "Undo didn't get back to the start.") }
            _ = try await testCase.undoAll(.redo)
            try checkBackTo(end, seed, testCase, "Redo didn't get back to the end.")
            try checkNoHiddenLeftovers(seed, testCase)
        }
        if Self.cases >= 50 {
            #expect(turns > Self.cases)
        }
    }

    // T-afe2a12e F-560
    @Test func losesAndReplacesNothingWhenWritesFailAsIfThingsChangedOutside() async throws {
        try await eachCase { seed, testCase in
            for _ in 0..<testCase.random.integer(1, 6) { _ = try await testCase.operate() }
            let before = testCase.ids()
            testCase.setFailures(
                FuzzFailures(codes: ["EACCES", "EPERM", "ENOENT", "EEXIST"], chance: 0.2, stopChance: 0.1))
            let undone = try await testCase.undoAll(.undo, tries: 500)
            let redone = try await testCase.undoAll(.redo, tries: 500)
            // Nothing was deleted, and nothing taken a name from another item: every id is still somewhere.
            let after = testCase.ids()
            for id in before where !after.contains(id) {
                throw fail(seed, testCase, "An item (id \(id)) was lost.")
            }
            try checkSaidWhy(seed, testCase, undone + redone)
            try checkNoHiddenLeftovers(seed, testCase)
        }
    }
}
