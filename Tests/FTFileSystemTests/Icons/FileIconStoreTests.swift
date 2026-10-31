import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// Gives every path an image of its own and remembers what it was asked for.
private final class RecordingSource: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let answer: @Sendable (String) -> NSImage?

    init(answer: @escaping @Sendable (String) -> NSImage? = { _ in NSImage(size: NSSize(width: 2, height: 2)) }) {
        self.answer = answer
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func icon(atPath path: String) -> NSImage? {
        lock.lock()
        recorded.append(path)
        lock.unlock()
        return answer(path)
    }
}

@MainActor
private func fetch(_ store: FileIconStore, _ request: IconRequest, deferLoad: Bool = false) async -> NSImage? {
    await withCheckedContinuation { continuation in
        store.load(request, deferLoad: deferLoad) { continuation.resume(returning: $0) }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func makeStore(source: RecordingSource, samples: TemporaryDirectory) -> FileIconStore {
    FileIconStore(source: source, samples: IconSamples(root: samples.appending("samples")))
}

private func entry(
    _ path: String, extension fileExtension: String = "", kind: IconEntryKind = .file, executable: Bool? = nil
)
    -> IconEntry
{
    IconEntry(
        path: path, name: (path as NSString).lastPathComponent, extension: fileExtension, kind: kind,
        isExecutable: executable)
}

@MainActor @Suite struct FileIconStoreTests {
    // T-30abdbfb F-224 T-7a3e2fb1
    @Test func anIconIsMissingUntilItArrivesAndNoneWhenMacOSHasNone() async throws {
        try await withTemporaryDirectory { directory in
            let store = makeStore(source: RecordingSource { _ in nil }, samples: directory)
            let request = IconRequest(entry: entry("/a/pending-folder", kind: .directory))
            guard case .missing = store.lookup(request) else {
                Issue.record("known before it was asked for")
                return
            }

            let image = await fetch(store, request)
            #expect(image == nil)
            guard case .none = store.lookup(request) else {
                Issue.record("not remembered as having none")
                return
            }
        }
    }

    // T-046b5caf F-224
    @Test func asksForAnIconOnceAndReusesIt() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let request = IconRequest(entry: entry("/usr/bin/icon-once"))
            #expect(request.cacheKey == "path:/usr/bin/icon-once")

            let first = await fetch(store, request)
            let second = await fetch(store, request)
            #expect(first != nil)
            #expect(first === second)
            #expect(source.paths == ["/usr/bin/icon-once"])
        }
    }

    // F-224
    @Test func overlappingRequestsForTheSameIconShareOneFetch() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let request = IconRequest(entry: entry("/a/shared.txt", extension: "txt"))
            async let first = fetch(store, request)
            async let second = fetch(store, request)
            let images = await [first, second]
            #expect(images[0] === images[1])
            #expect(source.paths.count == 1)
        }
    }

    // T-308244dc F-224 F-225 F-223
    @Test func executablesWithoutAnExtensionShareAnIconAndSoDoTheOtherFiles() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let samples = IconSamples(root: directory.appending("samples"))
            let entries = [
                entry("/usr/bin/ls", executable: true), entry("/usr/bin/zip", executable: true),
                entry("/usr/bin/hosts", executable: false), entry("/usr/bin/Makefile", executable: false),
                entry("/a/one.txt", extension: "txt"), entry("/a/two.txt", extension: "txt"),
            ]
            var images: [NSImage?] = []
            for item in entries {
                images.append(await fetch(store, IconRequest(entry: item)))
            }
            // Six files, three icons: asked for by kind, not by each file.
            let executablePath = try samples.path(for: .executable)
            let documentPath = try samples.path(for: .file)
            #expect(source.paths == [executablePath, documentPath, "/a/one.txt"])
            #expect(images.allSatisfy { $0 != nil })
            #expect(images[0] === images[1])
            #expect(images[2] === images[3])
            #expect(images[4] === images[5])
        }
    }

    // T-4a26a2f9 F-224
    @Test func thePlainFolderAndDocumentIconsAreReadyBeforeAnyItemAsksForThem() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let samples = IconSamples(root: directory.appending("samples"))

            store.preloadGenericIcons()
            store.preloadGenericIcons()
            await waitUntil { store.cachedCount == 2 }

            // Each kind once.
            let folderPath = try samples.path(for: .folder)
            let documentPath = try samples.path(for: .file)
            #expect(Set(source.paths) == [folderPath, documentPath])
            #expect(source.paths.count == 2)
            // Drawn from the first look, with nothing more asked for.
            guard case .image = store.lookup(entry("/a/folder", kind: .directory)) else {
                Issue.record("no folder icon")
                return
            }
            guard case .image = store.lookup(entry("/a/Makefile", executable: false)) else {
                Issue.record("no document icon")
                return
            }
            #expect(source.paths.count == 2)
        }
    }

    // T-0be0c077
    @Test func doesNothingWhenTheIconsCannotBeMade() async throws {
        try await withTemporaryDirectory { directory in
            // The samples cannot be made: their folder would have to be inside a file.
            let blocker = directory.appending("blocker")
            try Data().write(to: blocker)
            let source = RecordingSource()
            let store = FileIconStore(
                source: source, samples: IconSamples(root: blocker.appendingPathComponent("samples")))

            store.preloadGenericIcons()
            await waitUntil { store.cachedCount == 2 }
            #expect(source.paths.isEmpty)
            guard case .none = store.lookup(IconRequest.generic(.folder)) else {
                Issue.record("a failure should read as no icon")
                return
            }
        }
    }

    // T-41333069 F-225
    @Test func asksForEachSymlinkByPathSinceMacOSDrawsItAsWhatItPointsTo() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            for item in [
                entry("/a/link-one.txt", extension: "txt", kind: .symlinkFile),
                entry("/a/link-two.txt", extension: "txt", kind: .symlinkFile),
                entry("/a/link-to-folder", kind: .symlinkDirectory),
            ] {
                #expect(await fetch(store, IconRequest(entry: item)) != nil)
            }
            #expect(source.paths == ["/a/link-one.txt", "/a/link-two.txt", "/a/link-to-folder"])
        }
    }

    // T-4a058765 F-224
    @Test func waitsBeforeAskingWhenDeferredSoItemsPassedQuicklyAreNeverAskedFor() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            #expect(FileIconStore.deferredLoadDelay == .milliseconds(80))

            // The selection moves on before the delay is up: each earlier request is taken back.
            var handle: LoadHandle?
            for name in ["passed-1", "passed-2", "passed-3"] {
                handle?.cancel()
                handle = store.load(IconRequest(entry: entry("/usr/bin/\(name)")), deferLoad: true) { _ in
                    Issue.record("a request that was taken back answered")
                }
            }
            handle?.cancel()
            let landed = await fetch(store, IconRequest(entry: entry("/usr/bin/landed")), deferLoad: true)
            #expect(landed != nil)
            // Let any wrongly kept request run before checking.
            try await Task.sleep(for: .milliseconds(200))
            #expect(source.paths == ["/usr/bin/landed"])
        }
    }

    @Test func aCancelledLoadDoesNotAnswerButStillFillsTheCache() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let request = IconRequest(entry: entry("/a/cancelled.txt", extension: "txt"))
            let handle = store.load(request) { _ in Issue.record("answered after cancel") }
            handle.cancel()
            await waitUntil {
                if case .image = store.lookup(request) { return true }
                return false
            }
            guard case .image = store.lookup(request) else {
                Issue.record("not cached")
                return
            }
        }
    }
}

@Suite struct IconSamplesTests {
    // T-f0300b75 F-223
    @Test func samplesAreAnEmptyFolderAPlainFileAndAnExecutable() throws {
        try withTemporaryDirectory { directory in
            let samples = IconSamples(root: directory.appending("filetrail-icon-samples"))
            let folder = try samples.path(for: .folder)
            let document = try samples.path(for: .file)
            let executable = try samples.path(for: .executable)
            #expect(Set([folder, document, executable]).count == 3)
            #expect(folder.contains("filetrail-icon-samples"))

            var isFolder: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
            for (path, mode) in [(document, 0o644), (executable, 0o755)] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                #expect(attributes[.size] as? Int == 0)
                #expect(attributes[.posixPermissions] as? Int == mode)
                #expect((path as NSString).pathExtension.isEmpty)
            }
            // The same items every time.
            #expect(try samples.path(for: .folder) == folder)
        }
    }

    @Test func theDefaultFolderIsOneFixedFolderInTheTemporaryDirectory() {
        #expect(IconSamples.defaultRoot.lastPathComponent == "filetrail-icon-samples")
        #expect(IconSamples.defaultRoot.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path))
    }

    @Test func aFailureIsNotRemembered() throws {
        try withTemporaryDirectory { directory in
            let blocker = directory.appending("blocker")
            try Data().write(to: blocker)
            let samples = IconSamples(root: blocker.appendingPathComponent("samples"))
            #expect(throws: (any Error).self) { try samples.path(for: .folder) }
            try FileManager.default.removeItem(at: blocker)
            #expect(throws: Never.self) { try samples.path(for: .folder) }
        }
    }

    // T-77887acd F-156
    @Test @MainActor func theWorkspaceGivesAnItemItsOwnIcon() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending("a.txt")
            try Data("hi".utf8).write(to: file)
            let icon = WorkspaceIconSource().icon(atPath: file.path)
            #expect(icon != nil)
            #expect(icon.map { $0.size.width > 0 && $0.size.height > 0 } == true)
        }
    }
}
