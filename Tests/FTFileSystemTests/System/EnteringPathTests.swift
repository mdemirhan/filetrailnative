// Checks that a path the system hands the app (a panel's answer, another app's drag, an app Launch Services offers) is
// respelled as its disk has it before it is kept beside paths from listings
import AppKit
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct EnteringPathTests {
    @MainActor @Test func anAppChosenInAPanelIsNamedAsItsDiskHasIt() async throws {
        try await withTemporaryDirectory(prefix: "spelling-pick-app") { root in
            let place = try ComposedPlace(root)
            let app = place.root + "/Caf\u{E9}.app"
            try #require(mkdir(app, 0o755) == 0)
            // The panel's URL spells the accent its own way, as a URL made from a path does, and names the folder
            // as the system does (/var for /private/var).
            let panelURL = URL(fileURLWithPath: root.path + "/Cafe\u{301}.app")
            try #require(systemBytes(of: panelURL) != utf8Bytes(app))
            let choice = await SystemPickers.pickApplication(window: nil) { _, _ in [panelURL] }
            #expect(choice.appPath.map(utf8Bytes) == utf8Bytes(app))
            #expect(choice.appName.map(utf8Bytes) == utf8Bytes("Caf\u{E9}"))
        }
    }

    @MainActor @Test func aFolderChosenInAPanelIsSpelledAsItsDiskHasIt() async throws {
        try await withTemporaryDirectory(prefix: "spelling-pick-folder") { root in
            let place = try ComposedPlace(root)
            let panelURL = URL(fileURLWithPath: place.folderSpelledOtherwise, isDirectory: true)
            let choice = await SystemPickers.pickDirectory(defaultPath: place.folder, window: nil) { panel, _ in
                // The panel starts in the folder by its path's own bytes.
                #expect(panel.directoryURL.map { utf8Bytes($0.path) } == utf8Bytes(place.folder))
                return [panelURL]
            }
            #expect(choice.path.map(utf8Bytes) == utf8Bytes(place.folder))
            // A link chosen as a folder is the place it leads to.
            let link = place.root + "/link"
            try #require(symlink(place.folderSpelledOtherwise, link) == 0)
            let linked = await SystemPickers.pickDirectory(defaultPath: nil, window: nil) { _, _ in
                [URL(fileURLWithPath: link)]
            }
            #expect(linked.path.map(utf8Bytes) == utf8Bytes(place.folder))
        }
    }

    @Test func filesDraggedInFromAnotherAppAreSpelledAsTheDiskHasThem() throws {
        try withTemporaryDirectory(prefix: "spelling-drop") { root in
            let place = try ComposedPlace(root)
            let accented = try place.file("na\u{EF}ve.txt")
            let plain = try place.file("plain.txt")
            let other = try place.file("other.txt")
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("filetrail-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            // The other app spells every path its own way, and names one file twice, once in each spelling.
            let dragged = [
                place.folderSpelledOtherwise + "/nai\u{308}ve.txt", place.folderSpelledOtherwise + "/plain.txt",
                place.folder + "/na\u{EF}ve.txt", place.folderSpelledOtherwise + "/other.txt",
            ]
            pasteboard.writeObjects(
                dragged.map { path in
                    path.withCString {
                        URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
                    }
                        as NSURL
                })
            let contents = DragPasteboard.read(pasteboard)
            // Read as the URLs spell them, byte for byte.
            #expect(contents.paths.map(utf8Bytes) == dragged.map(utf8Bytes))

            let folders = DiskCalls()
            let names = DiskCalls()
            let counting = DragPasteboard.Respelling(
                folder: {
                    folders.add()
                    return $0.asOnDisk()
                },
                name: {
                    names.add()
                    return $0.namedAsOnDisk()
                })
            let answer = DragPasteboard.draggedIn(contents, respelling: counting)
            #expect(answer.items.map(\.path).map(utf8Bytes) == [accented, plain, other].map(utf8Bytes))
            #expect(answer.items.map(\.kind) == [.file, .file, .file])
            // The disk is asked for each spelling of the folder once, and for a name only where it has an accent.
            #expect(folders.count == 2)
            #expect(names.count == 2)
            // The app's own reading asks the disk the same way.
            #expect(
                DragPasteboard.draggedIn(contents).items.map(\.path).map(utf8Bytes)
                    == [accented, plain, other].map(utf8Bytes))
        }
    }

    @Test func aLargeDropAsksTheDiskForItsFolderOnce() {
        let paths = (0..<10_000).map { "/Volumes/Card/DCIM/IMG_\($0).JPG" }
        let folders = DiskCalls()
        let names = DiskCalls()
        let counting = DragPasteboard.Respelling(
            folder: {
                folders.add()
                return $0
            },
            name: {
                names.add()
                return $0
            })
        let answer = DragPasteboard.draggedIn(
            DragPasteboardContents(changeCount: 1, paths: paths),
            lstat: { _ in DragPasteboard.Stat(isDirectory: false, isSymbolicLink: false) }, respelling: counting)
        #expect(answer.items.count == 10_000)
        #expect(folders.count == 1)
        #expect(names.count == 0)
    }

    @Test func anAppIsOneKeyHoweverItsURLWasMade() throws {
        try withTemporaryDirectory(prefix: "spelling-apps") { root in
            let place = try ComposedPlace(root)
            let app = place.root + "/Caf\u{E9}.app"
            try #require(mkdir(app, 0o755) == 0)
            // A URL keeps the bytes it was made of: the key is the app's path as that URL spells it.
            #expect(utf8Bytes(OpenWithCatalog.appKey(DiskPath(app).fileURL())) == utf8Bytes(app))
            #expect(utf8Bytes(OpenWithCatalog.appKey(DiskPath(app + "/").url(isDirectory: true))) == utf8Bytes(app))
            #expect(OpenWithCatalog.appKey(DiskPath(place.root + "/./x/../Caf\u{E9}.app").fileURL()) == app)
            // A URL the system made from text holds the accent as the text had it, and so does its key.
            let fromText = try #require(URL(string: DiskPath(app).url(isDirectory: true).absoluteString))
            #expect(utf8Bytes(OpenWithCatalog.appKey(fromText)) == utf8Bytes(app))
            // A path saved with the accent spelled the other way is the same key to a dictionary and to `==`.
            let saved = place.root + "/Cafe\u{301}.app"
            let savedKey = OpenWithCatalog.appKey(DiskPath(saved).fileURL())
            #expect(utf8Bytes(savedKey) == utf8Bytes(saved))
            #expect(savedKey == OpenWithCatalog.appKey(DiskPath(app).fileURL()))
            #expect([savedKey: 1][OpenWithCatalog.appKey(DiskPath(app).fileURL())] == 1)

            // The catalog finds the app by either spelling of its path.
            let found = OpenWithCatalog().lookup(paths: [], appPaths: [app, saved]).appInfo
            #expect(found.first??.path.utf8.elementsEqual(app.utf8) == true)
            #expect(found.map { $0?.path } == [app, app])
            #expect(found.first??.name == "Caf\u{E9}")

            // A pinned app saved under the other spelling is still the app macOS offers: listed once, as pinned.
            let offered = ApplicationInfo(path: app, name: "Caf\u{E9}", bundleId: nil, version: nil)
            let lookup = OpenWithLookup(
                defaultApp: nil, apps: [offered],
                kinds: [OpenWithKind(contentType: "public.text", name: "text", isFolder: false)],
                pinnedApps: [ApplicationInfo(path: saved, name: "Caf\u{E9}", bundleId: nil, version: nil)])
            let sections = OpenWithMenu.sections(
                lookup: lookup, pinned: [OpenWithApplication(id: "cafe", appPath: saved, appName: "Caf\u{E9}")])
            #expect(sections.pinned.map(\.path).map(utf8Bytes) == [utf8Bytes(saved)])
            #expect(sections.others.isEmpty)
        }
    }
}
