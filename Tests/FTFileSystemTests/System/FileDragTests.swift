// Port of apps/desktop/src/main/bootstrap/fileDrag.test.ts and of the nativeStartFileDrag and nativeReadDragPasteboard
// cases of packages/native-fs/src/native-fs.test.ts
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@MainActor
struct FileDragTests {
    private let rect = CGRect(x: 0, y: 0, width: 16, height: 16)

    private func image(index: Int) -> FileDragImage {
        FileDragImage(
            index: index, iconRect: rect, nameRect: rect, nameFontSize: 13, nameCentered: false, thumbnail: false)
    }

    private func mouseDown(in window: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: Starting

    // T-e58d38a7 (the page's zoom is N/A D-005: points are measured where they are drawn)
    @Test func answersWithWhatTheDropDidAndWhereItEnded() {
        var ended: [(FileDragEnd, FileDragEndedOver)] = []
        let source = FileDragSource(windowNumber: 7) { ended.append(($0, $1)) }
        source.isAppWindow = { [7, 8].contains($0) }
        source.windowNumberAt = { point in point.x < 0 ? 8 : point.x < 100 ? 7 : 3 }
        source.ended(at: NSPoint(x: -5, y: 0), operation: .move)
        source.ended(at: NSPoint(x: 50, y: 0), operation: [.copy, .move])
        source.ended(at: NSPoint(x: 500, y: 0), operation: .delete)
        source.ended(at: NSPoint(x: 500, y: 0), operation: .generic)
        source.ended(at: NSPoint(x: 500, y: 0), operation: .link)
        source.ended(at: NSPoint(x: 500, y: 0), operation: [])
        #expect(ended.map(\.0) == [.move, .move, .delete, .move, .link, .none])
        #expect(ended.map(\.1) == [.anotherWindow, .thisWindow, .elsewhere, .elsewhere, .elsewhere, .elsewhere])
        #expect(FileDrag.end(of: [.copy, .link]) == .copy)
        #expect(FileDrag.end(of: [.delete, .move]) == .delete)
    }

    // F-689: Copy and Move within the app, everything a drop elsewhere may do outside it; the keys narrow the drag
    // only away from the app's windows.
    @Test func allowsCopyAndMoveInsideTheAppAndMoreOutside() {
        #expect(FileDrag.sourceOperationMask(.withinApplication) == [.copy, .move])
        #expect(FileDrag.sourceOperationMask(.outsideApplication) == [.copy, .move, .generic, .link, .delete])
        let source = FileDragSource(windowNumber: 7) { _, _ in }
        source.isAppWindow = { $0 == 7 }
        source.mouseLocation = { NSPoint(x: 1, y: 1) }
        source.windowNumberAt = { _ in 7 }
        #expect(source.isAppWindow(source.windowNumberAt(source.mouseLocation())))
        source.windowNumberAt = { _ in 99 }
        #expect(!source.isAppWindow(source.windowNumberAt(source.mouseLocation())))
    }

    // T-12657965 T-a3e51508
    @Test func doesntStartAndNeverCallsBackWithoutAWindowOrWithTheButtonUp() async {
        var called = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(
            !FileDrag.start(
                from: view, event: mouseDown(), paths: ["/tmp/a.txt"], directories: [false], images: [],
                buttonDown: true
            ) { _, _ in called = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = view
        #expect(
            !FileDrag.start(
                from: view, event: mouseDown(in: window), paths: ["/tmp/a.txt"], directories: [false], images: [],
                buttonDown: false
            ) { _, _ in called = true })
        #expect(
            !FileDrag.start(
                from: view, event: mouseDown(in: window), paths: [], directories: [], images: [], buttonDown: true
            ) { _, _ in called = true })
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(!called)
    }

    // T-7b0702ec
    // N/A T-b7c6cc04 Swift's types hold the arguments to their kinds: a view, paths, flags, images and a callback.
    @Test func refusesAnImageForAPlaceNoPathCanHave() {
        let view = NSView()
        for index in [-1, Int(UInt32.max), Int.max] {
            #expect(!FileDrag.imagesAreValid([image(index: index)]))
            #expect(
                !FileDrag.start(
                    from: view, event: mouseDown(), paths: ["/tmp/a.txt"], directories: [false],
                    images: [image(index: index)], buttonDown: true
                ) { _, _ in })
        }
        #expect(FileDrag.imagesAreValid([image(index: 0), image(index: 5)]))
    }

    // F-688
    @Test func drawsTheNameAsACapsuleNoWiderThan240Points() {
        let short = FileDrag.labelImage("a.txt", fontSize: 13)
        let long = FileDrag.labelImage(String(repeating: "long name ", count: 40), fontSize: 13)
        #expect(short.size.width < 240)
        #expect(long.size.width == 240)
        #expect(long.size.height == short.size.height)
        #expect(
            FileDrag.fit(NSSize(width: 32, height: 16), in: NSRect(x: 0, y: 0, width: 16, height: 16))
                == NSRect(x: 0, y: 4, width: 16, height: 8))
        #expect(
            FileDrag.fit(.zero, in: NSRect(x: 1, y: 2, width: 3, height: 4)) == NSRect(x: 1, y: 2, width: 3, height: 4))
    }

    // N/A T-f72c34af a thumbnail is handed over as the image Quick Look made, never as a data URL.
    @Test func takesThumbnailsAsImages() {
        #expect(FileDrag.labelFontSize == 12)
    }

    // MARK: Afterwards

    // T-feb9d2aa
    @Test func findsTheItemsNoLongerThereAndHasWhatTheyLeftReadAgain() {
        let answer = FileDrag.findDraggedAway(
            ["/Users/demo/moved.txt", "/Users/demo/stayed.txt", "/Volumes/Asleep/a.txt"],
            lstatError: { path in
                path == "/Users/demo/moved.txt" ? ENOENT : path == "/Volumes/Asleep/a.txt" ? EIO : 0
            })
        // A disk that can't answer doesn't make its items gone.
        #expect(answer.gone == ["/Users/demo/moved.txt"])
        #expect(answer.cleared == ["/Users/demo/moved.txt"])
    }

    // T-404ee5d8
    // T-a560f3a4
    @Test func hasTheTrashMeasuredAgainWhenTheDocksTrashTookThem() {
        let answer = FileDrag.findDraggedAway(
            ["/Users/demo/old.zip"], intoTrash: true, homePath: "/Users/demo", lstatError: { _ in ENOENT })
        #expect(answer.cleared == ["/Users/demo/old.zip", "/Users/demo/.Trash"])
        #expect(answer.gone == ["/Users/demo/old.zip"])
    }

    // T-616177b9
    // T-626e8068
    @Test func leavesTheCachesAloneWhenEverythingIsStillThere() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-dragged-away")
        let file = folder.appending("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let answer = FileDrag.findDraggedAway([file.path])
        #expect(answer.gone.isEmpty && answer.cleared.isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(FileDrag.findDraggedAway([file.path]).gone == [file.path])
    }

    // T-26a08ce9
    @Test func givesEachDraggedItemsKindAsItIsOnDiskAndLeavesOutWhatIsntThere() {
        typealias Stat = DragPasteboard.Stat
        let onDisk: [String: Stat] = [
            "/Users/demo/a.txt": Stat(isDirectory: false, isSymbolicLink: false),
            "/Users/demo/Folder": Stat(isDirectory: true, isSymbolicLink: false),
            "/Users/demo/to-folder": Stat(isDirectory: false, isSymbolicLink: true),
            "/Users/demo/to-file": Stat(isDirectory: false, isSymbolicLink: true),
            "/Users/demo/broken": Stat(isDirectory: false, isSymbolicLink: true),
        ]
        let targets: [String: Stat] = [
            "/Users/demo/to-folder": Stat(isDirectory: true, isSymbolicLink: false),
            "/Users/demo/to-file": Stat(isDirectory: false, isSymbolicLink: false),
        ]
        let paths = [
            "/Users/demo/a.txt", "/Users/demo/Folder", "/Users/demo/to-folder", "/Users/demo/to-file",
            "/Users/demo/broken",
            "/Users/demo/gone.txt", "relative/path",
        ]
        let answer = DragPasteboard.draggedIn(
            DragPasteboardContents(changeCount: 7, paths: paths), lstat: { onDisk[$0] }, stat: { targets[$0] })
        #expect(answer.changeCount == 7)
        #expect(
            answer.items == [
                DraggedInItem(path: "/Users/demo/a.txt", kind: .file),
                DraggedInItem(path: "/Users/demo/Folder", kind: .directory),
                DraggedInItem(path: "/Users/demo/to-folder", kind: .symlinkDirectory),
                DraggedInItem(path: "/Users/demo/to-file", kind: .symlinkFile),
                DraggedInItem(path: "/Users/demo/broken", kind: .symlinkFile),
            ])
    }

    // T-c555af62
    @Test func hasNothingForADragWithoutFiles() {
        let answer = DragPasteboard.draggedIn(DragPasteboardContents(changeCount: 3, paths: []))
        #expect(answer.changeCount == 3)
        #expect(answer.items.isEmpty)
    }

    // T-bb9cb527
    @Test func refusesMoreItemsThanOneCopyTakesRatherThanDroppingSome() {
        let paths = (0...FileDragImages.maxPaths).map { "/f/\($0)" }
        let looked = Counter()
        let answer = DragPasteboard.draggedIn(
            DragPasteboardContents(changeCount: 1, paths: paths),
            lstat: { _ in
                looked.add()
                return nil
            })
        #expect(answer.items.isEmpty)
        #expect(looked.count == 0)
    }

    // T-d4fd334c
    @Test func readsTheFilesAnotherAppsDragCarriesFileReferencesAsPaths() throws {
        let folder = try TemporaryDirectory(prefix: "filetrail-drag-pasteboard")
        let file = folder.appending("a b.txt")
        let inner = folder.appending("Folder")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("filetrail-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let reference = (file as NSURL).fileReferenceURL() ?? file
        pasteboard.writeObjects([
            reference as NSURL, inner as NSURL, inner as NSURL, URL(string: "https://example.com/")! as NSURL,
        ])
        let contents = DragPasteboard.read(pasteboard)
        // A reference names the file where it really is (/var is /private/var).
        let real = try #require(realpath(file.path, nil))
        defer { free(real) }
        #expect(contents.paths == [String(cString: real), inner.path])
        #expect(contents.changeCount == pasteboard.changeCount)
    }

    // T-47384a01
    // T-0e1460d5
    @Test func findsNoFilesInADragOfText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("filetrail-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        #expect(
            DragPasteboard.read(pasteboard) == DragPasteboardContents(changeCount: pasteboard.changeCount, paths: []))
    }

    // T-4fa0cf14 T-0472eefd
    @Test func tellsWhichDragIsGoingOnByItsChangeCountAlone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("filetrail-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)
        let count = pasteboard.changeCount
        #expect(DragPasteboard.changeCount(pasteboard) == count)
        #expect(DragPasteboard.read(pasteboard).changeCount == count)
        pasteboard.clearContents()
        #expect(DragPasteboard.changeCount(pasteboard) != count)
    }

    // MARK: Bringing the window forward

    @MainActor
    private final class FakeWindow: FrontWindow {
        var focusedAfter: Bool
        var isGone = false
        var shown = 0

        init(focusedAfter: Bool) { self.focusedAfter = focusedAfter }
        func comeForward() { shown += 1 }
        var isFocused: Bool { focusedAfter }
    }

    // T-d7f434f3
    @Test func bringsTheAppAndTheWindowForward() async {
        let window = FakeWindow(focusedAfter: true)
        var focused = 0
        var bounced = 0
        let answer = await FileDrag.bringToFront(
            window, focusApp: { focused += 1 }, bounceDockIcon: { bounced += 1 }, waitMs: 0)
        #expect(answer)
        #expect(focused == 1 && window.shown == 1 && bounced == 0)
    }

    // T-efac16df
    @Test func bouncesTheDockIconWhenMacOSKeepsAnotherAppInFront() async {
        var bounced = 0
        let answer = await FileDrag.bringToFront(
            FakeWindow(focusedAfter: false), focusApp: {}, bounceDockIcon: { bounced += 1 }, waitMs: 0)
        #expect(!answer)
        #expect(bounced == 1)
    }

    // T-c6b44a0b
    @Test func doesNothingWithoutAWindowOrOnceItHasClosed() async {
        #expect(!(await FileDrag.bringToFront(nil, waitMs: 0)))
        let closed = FakeWindow(focusedAfter: false)
        closed.isGone = true
        var bounced = 0
        #expect(!(await FileDrag.bringToFront(closed, focusApp: {}, bounceDockIcon: { bounced += 1 }, waitMs: 0)))
        #expect(bounced == 0)
    }
}

/// Counts calls from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
