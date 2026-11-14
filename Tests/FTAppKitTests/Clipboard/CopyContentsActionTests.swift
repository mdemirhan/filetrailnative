// Copy Contents in the app: real files read as an image or text, what goes on a private clipboard, and what is asked
// and said around it
import AppKit
import FTFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTAppKit

@MainActor
@Suite struct CopyContentsActionTests {
    /// A folder of its own for each test, removed after it.
    final class Folder {
        let path = NSTemporaryDirectory() + "filetrail-copy-contents-\(UUID().uuidString)"
        init() { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        @discardableResult
        func write(_ name: String, _ data: Data) -> String {
            let file = "\(path)/\(name)"
            FileManager.default.createFile(atPath: file, contents: data)
            return file
        }
    }

    /// A `width` by `height` image encoded as `type`, with its EXIF orientation when given.
    static func image(_ type: UTType, width: Int = 4, height: Int = 2, orientation: Int? = nil) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func size(ofPNG data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.png.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: Reading

    @Test func aPNGOrAJPEGIsCopiedAsItIsWithNothingElse() throws {
        let folder = Folder()
        let png = Self.image(.png)
        let read = FileContents.readNow(folder.write("shot.png", png), guess: .image)
        #expect(read == .success(.image(type: "public.png", data: png, png: nil)))
        let jpeg = Self.image(.jpeg)
        #expect(
            FileContents.readNow(folder.write("photo.jpg", jpeg), guess: .image)
                == .success(.image(type: "public.jpeg", data: jpeg, png: nil)))
    }

    @Test func anotherImageKeepsItsBytesAndGetsAPNGCopyTurnedAsItIsShown() throws {
        let folder = Folder()
        // A 4×2 TIFF that says it is shown turned a quarter (orientation 6): its PNG is 2×4.
        let tiff = Self.image(.tiff, orientation: 6)
        guard
            case .success(.image(let type, let data, let png)) = FileContents.readNow(
                folder.write("scan.tiff", tiff), guess: .image)
        else {
            Issue.record("not read as an image")
            return
        }
        #expect(type == "public.tiff" && data == tiff)
        let size = try #require(png.flatMap(Self.size(ofPNG:)))
        #expect(size == (2, 4))
    }

    @Test func aFileNamedAsAnImageThatIsntOneSaysSo() {
        let folder = Folder()
        #expect(
            FileContents.readNow(folder.write("fake.png", Data("not an image".utf8)), guess: .image)
                == .failure(.notAnImage))
    }

    @Test func textIsReadAsUTF8OrUTF16AndAnythingElseIsRefused() {
        let folder = Folder()
        #expect(
            FileContents.readNow(folder.write("notes.md", Data("# Notes\nhé".utf8)), guess: .text)
                == .success(.text("# Notes\nhé", rtf: nil)))
        let utf16 = "hé".data(using: .utf16)!
        #expect(FileContents.readNow(folder.write("a.txt", utf16), guess: .text) == .success(.text("hé", rtf: nil)))
        #expect(
            FileContents.readNow(folder.write("latin.txt", Data([0x63, 0x61, 0x66, 0xE9])), guess: .text)
                == .failure(.unknownEncoding))
    }

    @Test func anRTFFileKeepsItsStylesBesideItsText() throws {
        let folder = Folder()
        let styled = NSAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(
            FileContents.readNow(folder.write("letter.rtf", rtf), guess: .text) == .success(.text("Bold", rtf: rtf)))
    }

    @Test func aFileWhoseNameDoesntSayIsReadForAnImageThenForText() {
        let folder = Folder()
        let png = Self.image(.png)
        #expect(
            FileContents.readNow(folder.write("picture", png), guess: .unknown)
                == .success(.image(type: "public.png", data: png, png: nil)))
        #expect(
            FileContents.readNow(folder.write("Makefile", Data("all:\n\tmake\n".utf8)), guess: .unknown)
                == .success(.text("all:\n\tmake\n", rtf: nil)))
        #expect(
            FileContents.readNow(folder.write("blob", Data([0x50, 0x4B, 0x03, 0x04, 0x00])), guess: .unknown)
                == .failure(.notImageOrText))
        #expect(
            FileContents.readNow(folder.write("backup.zip", Data([0x50, 0x4B, 0x03, 0x04, 0x00])), guess: .other)
                == .failure(.notImageOrText))
    }

    @Test func anEmptyOrTooLargeFileIsNotRead() throws {
        let folder = Folder()
        #expect(FileContents.readNow(folder.write("empty.txt", Data()), guess: .text) == .failure(.empty))
        // Sparse: the size is all there is to it.
        let big = folder.write("big.log", Data())
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: big))
        try handle.truncate(atOffset: UInt64(CopyContents.textLimit + 1))
        try handle.close()
        #expect(FileContents.readNow(big, guess: .text) == .failure(.tooLarge(.text)))
        let huge = folder.write("huge.png", Data())
        let hugeHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: huge))
        try hugeHandle.truncate(atOffset: UInt64(CopyContents.imageLimit + 1))
        try hugeHandle.close()
        #expect(FileContents.readNow(huge, guess: .image) == .failure(.tooLarge(.image)))
    }

    @Test func aLinkIsReadForWhatItPointsToAndAMissingFileSaysWhy() throws {
        let folder = Folder()
        let target = folder.write("notes.txt", Data("linked".utf8))
        try FileManager.default.createSymbolicLink(atPath: "\(folder.path)/link.txt", withDestinationPath: target)
        #expect(
            FileContents.readNow("\(folder.path)/link.txt", guess: .text) == .success(.text("linked", rtf: nil)))
        guard case .failure(.unreadable(let reason)) = FileContents.readNow("\(folder.path)/gone.txt", guess: .text)
        else {
            Issue.record("a missing file was read")
            return
        }
        #expect(!reason.isEmpty)
    }

    // MARK: The clipboard

    static func privateBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("filetrail-test-\(UUID().uuidString)"))
    }

    @Test func anImageGoesOnTheClipboardInItsOwnFormatFirstAndPasteAsFileTakesItBack() {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        let heic = Data([1, 2, 3])
        let contents = FileContents.image(type: "public.heic", data: heic, png: Data([4, 5]))
        #expect(contents.write(to: board, concealed: false))
        let types = board.types?.map(\.rawValue) ?? []
        #expect(Array(types.prefix(2)) == ["public.heic", "public.png"])
        #expect(board.data(forType: NSPasteboard.PasteboardType("public.heic")) == heic)
        #expect(SystemClipboard(board).choice == .image(.heic))
    }

    @Test func textGoesOnAsPlainTextAndAnRTFFileAsItsStylesToo() {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        #expect(FileContents.text("hello", rtf: nil).write(to: board, concealed: false))
        #expect(board.string(forType: .string) == "hello")
        #expect(board.data(forType: .rtf) == nil)
        let rtf = Data("{\\rtf1 hi}".utf8)
        #expect(FileContents.text("hi", rtf: rtf).write(to: board, concealed: false))
        #expect(board.data(forType: .rtf) == rtf && board.string(forType: .string) == "hi")
        #expect(SystemClipboard(board).choice == .text)
    }

    @Test func aSecretIsMarkedAsPrivateOnTheClipboard() {
        let board = Self.privateBoard()
        defer { board.releaseGlobally() }
        #expect(FileContents.text("KEY=1", rtf: nil).write(to: board, concealed: true))
        #expect(PasteAsFile.isConcealed(types: board.types?.map(\.rawValue) ?? []))
        #expect(FileContents.text("plain", rtf: nil).write(to: board, concealed: false))
        #expect(!PasteAsFile.isConcealed(types: board.types?.map(\.rawValue) ?? []))
    }

    // MARK: The action

    @MainActor
    final class Fixture {
        let board = CopyContentsActionTests.privateBoard()
        let toasts = ToastCenter()
        let notices = NoticeSpy()
        var asked: [WriteQuestion] = []
        var answer = true
        let action: CopyContentsAction

        init() {
            let board = board
            let toasts = toasts
            action = CopyContentsAction(pasteboard: { board }, window: { nil }, toasts: { toasts })
            action.notices = notices
            action.confirm = { [unowned self] question, _ in
                asked.append(question)
                return answer
            }
        }

        isolated deinit { board.releaseGlobally() }

        var toastTitles: [String] { toasts.entries.map(\.title) }
    }

    @Test func aCopySaysSoAndNamesTheFile() async {
        let folder = Folder()
        let fixture = Fixture()
        let path = folder.write("notes.md", Data("hello".utf8))
        #expect(await fixture.action.copy(path))
        #expect(fixture.board.string(forType: .string) == "hello")
        #expect(fixture.toasts.entries.map(\.title) == ["Copied text"])
        #expect(fixture.toasts.entries.first?.message == "notes.md")
        #expect(fixture.asked.isEmpty)
        // The Info panel's button says it instead.
        #expect(await fixture.action.copy(path, announce: false))
        #expect(fixture.toasts.entries.count == 1)
    }

    @Test func aFileThatUsuallyHoldsASecretIsAskedAboutAndNotCopiedWhenDeclined() async {
        let folder = Folder()
        let fixture = Fixture()
        fixture.board.clearContents()
        fixture.board.setString("before", forType: .string)
        let path = folder.write(".env", Data("TOKEN=abc".utf8))
        fixture.answer = false
        #expect(!(await fixture.action.copy(path)))
        #expect(fixture.asked.map(\.title) == ["\u{201C}.env\u{201D} may hold a password or a key. Copy its text?"])
        #expect(fixture.asked.first?.cancelIsDefault == true)
        #expect(fixture.board.string(forType: .string) == "before")
        fixture.answer = true
        #expect(await fixture.action.copy(path))
        #expect(fixture.board.string(forType: .string) == "TOKEN=abc")
        #expect(PasteAsFile.isConcealed(types: fixture.board.types?.map(\.rawValue) ?? []))
    }

    @Test func whatCantBeCopiedIsAToastAndWhatWentWrongAnAlert() async {
        let folder = Folder()
        let fixture = Fixture()
        #expect(!(await fixture.action.copy(folder.write("empty.txt", Data()))))
        #expect(!(await fixture.action.copy(folder.write("blob", Data([0, 1, 2])))))
        #expect(fixture.toastTitles == ["The file is empty", "Not an image or text"])
        #expect(fixture.toasts.entries.map(\.message) == ["empty.txt", "blob"])
        #expect(!(await fixture.action.copy(folder.write("fake.png", Data("x".utf8)))))
        #expect(fixture.notices.shown.map(\.title) == ["Couldn\u{2019}t Copy the Image"])
        #expect(fixture.notices.shown.map(\.message) == ["It couldn\u{2019}t be opened as an image."])
    }

    @Test func aSlowReadSaysItIsCopyingUntilItIsDone() async {
        let fixture = Fixture()
        let release = AsyncStream<Void>.makeStream()
        fixture.action.slowDelay = .milliseconds(1)
        fixture.action.read = { _, _ in
            for await _ in release.stream { break }
            return .success(.text("late", rtf: nil))
        }
        let copy = Task { await fixture.action.copy("/Volumes/Slow/notes.txt") }
        while !fixture.toastTitles.contains("Copying\u{2026}") { await Task.yield() }
        release.continuation.yield()
        #expect(await copy.value)
        #expect(fixture.toastTitles == ["Copied text"])
    }

    @Test func theCopyAskedForLastIsTheOneThatLands() async {
        let fixture = Fixture()
        let started = AsyncStream<Void>.makeStream()
        let first = AsyncStream<Void>.makeStream()
        fixture.action.slowDelay = .seconds(60)
        fixture.action.read = { path, _ in
            if path.hasSuffix("first.txt") {
                started.continuation.yield()
                for await _ in first.stream { break }
            }
            return .success(.text(NodePath.basename(path), rtf: nil))
        }
        let slow = Task { await fixture.action.copy("/a/first.txt") }
        for await _ in started.stream { break }
        #expect(await fixture.action.copy("/a/second.txt"))
        first.continuation.yield()
        #expect(!(await slow.value))
        #expect(fixture.board.string(forType: .string) == "second.txt")
        #expect(fixture.toastTitles == ["Copied text"])
    }
}
