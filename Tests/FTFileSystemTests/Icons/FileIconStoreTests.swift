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

/// Holds its first answer until let go, and draws a new image each time it is asked.
private final class HeldSource: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var drawn: [NSImage] = []

    var images: [NSImage] {
        lock.lock()
        defer { lock.unlock() }
        return drawn
    }

    func letFirstAnswer() { gate.signal() }

    func icon(atPath path: String) -> NSImage? {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        lock.lock()
        drawn.append(image)
        let first = drawn.count == 1
        lock.unlock()
        if first { gate.wait() }
        return image
    }
}

/// Draws a type's icon at once, as the workspace does, and remembers which extensions it drew.
private final class TypeIconSource: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTypes: [String] = []
    private var recordedPaths: [String] = []

    var types: [String] { lock.withLock { recordedTypes } }
    var paths: [String] { lock.withLock { recordedPaths } }

    func icon(atPath path: String) -> NSImage? {
        lock.withLock { recordedPaths.append(path) }
        return NSImage(size: NSSize(width: 2, height: 2))
    }

    func typeIcon(forExtension fileExtension: String) -> NSImage? {
        lock.withLock { recordedTypes.append(fileExtension) }
        return NSImage(size: NSSize(width: 2, height: 2))
    }
}

@MainActor
private func fetch(_ store: FileIconStore, _ request: IconRequest, deferLoad: Bool = false) async -> NSImage? {
    await withCheckedContinuation { continuation in
        store.load(request, deferLoad: deferLoad) { continuation.resume(returning: $0) }
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

    // A file's icon by its extension comes from its type at once, the first time it is looked up, and only once; an
    // icon that depends on the item itself is still drawn later.
    @Test func aFilesTypeIconIsThereAtOnceWithoutReadingTheFile() async throws {
        try await withTemporaryDirectory { directory in
            let source = TypeIconSource()
            let store = FileIconStore(source: source, samples: IconSamples(root: directory.appending("samples")))
            let photo = IconRequest(entry: entry("/Volumes/Slow/photo.JPG", extension: "JPG"))
            guard case .image(let first) = store.lookup(photo) else {
                Issue.record("not there at once")
                return
            }
            var answered: NSImage?
            store.load(IconRequest(entry: entry("/Volumes/Slow/other.jpg", extension: "jpg"))) { answered = $0 }
            #expect(answered === first)
            #expect(source.types == ["jpg"])
            #expect(source.paths.isEmpty)

            let app = IconRequest(entry: entry("/Applications/Mail.app", kind: .bundle))
            guard case .missing = store.lookup(app) else {
                Issue.record("an app's own icon drawn at once")
                return
            }
            #expect(await fetch(store, app) != nil)
            #expect(source.paths == ["/Applications/Mail.app"])
        }
    }

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

    // An icon forgotten while it is being drawn (a custom icon set) is drawn again for the next request: the drawing
    // from before neither answers it nor comes back into the cache.
    @Test func anIconForgottenWhileItIsDrawnIsDrawnAgain() async throws {
        try await withTemporaryDirectory { directory in
            let source = HeldSource()
            let store = FileIconStore(source: source, samples: IconSamples(root: directory.appending("samples")))
            let request = IconRequest(entry: entry("/a/custom-icon"))
            store.load(request) { _ in }
            await pollUntil { source.images.count == 1 }
            store.forget(request)
            async let next = fetch(store, request)
            await pollUntil { source.images.count == 2 }
            source.letFirstAnswer()
            let image = await next
            #expect(source.images.count == 2)
            #expect(image === source.images.last)
            try? await Task.sleep(for: .milliseconds(50))
            guard case .image(let cached) = store.lookup(request) else {
                Issue.record("not cached")
                return
            }
            #expect(cached === source.images.last)
        }
    }

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

    @Test func thePlainFolderTaggedFolderAndDocumentIconsAreReadyBeforeAnyItemAsksForThem() async throws {
        try await withTemporaryDirectory { directory in
            let source = RecordingSource()
            let store = makeStore(source: source, samples: directory)
            let samples = IconSamples(root: directory.appending("samples"))
            let preloaded = 3 + FinderTagColor.allCases.count * 2

            store.preloadGenericIcons()
            store.preloadGenericIcons()
            await pollUntil { store.cachedCount == preloaded }

            // Each once: the plain folders, the document, and a folder of each tag color, holding something or not.
            var expected: Set<String> = [
                try samples.path(for: .folder), try samples.path(for: .emptyFolder), try samples.path(for: .file),
            ]
            for color in FinderTagColor.allCases {
                expected.insert(try samples.path(forTint: color))
                expected.insert(try samples.path(forTint: color, isEmpty: true))
            }
            #expect(Set(source.paths) == expected)
            #expect(source.paths.count == preloaded)
            // Drawn from the first look, with nothing more asked for.
            let lookups = [
                entry("/a/folder", kind: .directory), entry("/a/Makefile", executable: false),
                IconEntry(path: "/a/red", kind: .directory, tagColor: .red),
                IconEntry(path: "/a/gray", kind: .directory, tagColor: .gray, isEmptyFolder: true),
            ]
            for item in lookups {
                guard case .image = store.lookup(IconRequest(entry: item)) else {
                    Issue.record("no icon for \(item.path)")
                    return
                }
            }
            #expect(source.paths.count == preloaded)
        }
    }

    @Test func doesNothingWhenTheIconsCannotBeMade() async throws {
        try await withTemporaryDirectory { directory in
            // The samples cannot be made: their folder would have to be inside a file.
            let blocker = directory.appending("blocker")
            try Data().write(to: blocker)
            let source = RecordingSource()
            let store = FileIconStore(
                source: source, samples: IconSamples(root: blocker.appendingPathComponent("samples")))

            store.preloadGenericIcons()
            await pollUntil { store.cachedCount == 3 + FinderTagColor.allCases.count * 2 }
            #expect(source.paths.isEmpty)
            guard case .none = store.lookup(IconRequest.generic(.folder)) else {
                Issue.record("a failure should read as no icon")
                return
            }
        }
    }

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
            await pollUntil {
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
    @Test func samplesAreAFolderWithAnItemAnEmptyFolderAPlainFileAndAnExecutable() throws {
        try withTemporaryDirectory { directory in
            let samples = IconSamples(root: directory.appending("filetrail-icon-samples"))
            let folder = try samples.path(for: .folder)
            let emptyFolder = try samples.path(for: .emptyFolder)
            let document = try samples.path(for: .file)
            let executable = try samples.path(for: .executable)
            #expect(Set([folder, emptyFolder, document, executable]).count == 4)
            #expect(folder.contains("filetrail-icon-samples"))

            var isFolder: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["item"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: emptyFolder).isEmpty)
            let red = try samples.path(forTint: .red)
            let redEmpty = try samples.path(forTint: .red, isEmpty: true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: red) == ["item"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: redEmpty).isEmpty)
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

    @Test func theWorkspaceDrawsATypesIconWithoutAFile() {
        #expect(WorkspaceIconSource().typeIcon(forExtension: "jpg").map { $0.size.width > 0 } == true)
        #expect(WorkspaceIconSource().typeIcon(forExtension: "no-such-type-here").map { $0.size.width > 0 } == true)
    }

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
