// Convert Images' write: a converted copy of each picture beside it, under a free name, and its Undo
import CoreGraphics
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct ConvertImagesOperationTests {
    /// What is in the folder, the test's Trash left out.
    static func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0 != ".Trash" }.sorted()
    }

    /// A small PNG at `path`.
    static func picture(_ path: String, width: Int = 40, height: Int = 30) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func type(_ path: String) -> String? {
        CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceGetType($0) }
            as String?
    }

    @discardableResult
    static func convert(
        _ t: UndoTest, _ names: [String], _ options: ImageConversionOptions = ImageConversionOptions(format: .heic)
    ) async throws -> WriteOperationEvent {
        try await t.finish(
            t.coordinator.convertImages(paths: names.map { "\(t.root)/\($0)" }, options: options, window: t.window))
    }

    @Test func eachPictureGetsAConvertedCopyBesideItAndKeepsItsOriginal() async throws {
        try await withUndoFolder { root, trashDir in
            try Self.picture("\(root)/a.png")
            try Self.picture("\(root)/b.png")
            let original = try Data(contentsOf: URL(fileURLWithPath: "\(root)/a.png"))
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.convert(t, ["a.png", "b.png"])
            #expect(end.action == .convertImages)
            #expect(end.status == .completed)
            #expect(end.result?.targetPath == root)
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/a.heic", "\(root)/b.heic"])
            #expect(try Self.names(root) == ["a.heic", "a.png", "b.heic", "b.png"])
            #expect(Self.type("\(root)/a.heic") == UTType.heic.identifier)
            #expect(try Data(contentsOf: URL(fileURLWithPath: "\(root)/a.png")) == original)
            await t.shutDown()
        }
    }

    @Test func aTakenNameGivesTheNextFreeOneAndNothingIsReplaced() async throws {
        try await withUndoFolder { root, trashDir in
            try Self.picture("\(root)/photo.png")
            try UndoDisk.write("\(root)/photo.jpg", "mine")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.convert(t, ["photo.png"], ImageConversionOptions(format: .jpeg))
            #expect(end.result?.items.first?.destinationPath == "\(root)/photo 2.jpg")
            #expect(try String(contentsOfFile: "\(root)/photo.jpg", encoding: .utf8) == "mine")
            // Converted to its own format, a picture is numbered too.
            let same = try await Self.convert(t, ["photo.png"], ImageConversionOptions(format: .png, size: .scale(50)))
            #expect(same.result?.items.first?.destinationPath == "\(root)/photo 2.png")
            await t.shutDown()
        }
    }

    @Test func onePictureThatCantBeConvertedDoesntKeepTheOthersFromIt() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/broken.png", "not a picture")
            try Self.picture("\(root)/good.png")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.convert(t, ["broken.png", "good.png"])
            #expect(end.status == .partial)
            #expect(end.result?.items.map(\.status) == [.failed, .completed])
            #expect(end.result?.error == ConvertImagesText.notAnImage)
            #expect(try Self.names(root) == ["broken.png", "good.heic", "good.png"])
            await t.shutDown()
        }
    }

    @Test func anExactSizeLargerThanAPictureFailsIt() async throws {
        try await withUndoFolder { root, trashDir in
            try Self.picture("\(root)/small.png", width: 40, height: 30)
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.convert(
                t, ["small.png"],
                ImageConversionOptions(
                    format: .png, size: .custom(width: 50, height: 20, unit: .pixels, proportional: false)))
            #expect(end.status == .failed)
            #expect(end.result?.error == ConvertImagesText.tooSmall(PixelSize(width: 40, height: 30)))
            #expect(try Self.names(root) == ["small.png"])
            await t.shutDown()
        }
    }

    @Test func oneUndoMovesTheNewFilesToTheTrashAndRedoPutsThemBack() async throws {
        try await withUndoFolder { root, trashDir in
            try Self.picture("\(root)/a.png")
            try Self.picture("\(root)/b.png")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await Self.convert(t, ["a.png", "b.png"])
            #expect(t.history.menu().undo == "Convert 2 Images")
            let after = t.snapshot()
            try await t.undo()
            #expect(t.snapshot() == before)
            #expect(t.inTrash().count == 2)
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    @Test func picturesInSeveralFoldersAreEachConvertedInTheirOwn() async throws {
        try await withUndoFolder { root, trashDir in
            try FileManager.default.createDirectory(atPath: "\(root)/one", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: "\(root)/two", withIntermediateDirectories: false)
            try Self.picture("\(root)/one/a.png")
            try Self.picture("\(root)/two/a.png")
            let t = UndoTest(root: root, trashDir: trashDir)
            let end = try await Self.convert(t, ["one/a.png", "two/a.png"])
            #expect(end.result?.targetPath == nil)
            #expect(try Self.names("\(root)/one") == ["a.heic", "a.png"])
            #expect(try Self.names("\(root)/two") == ["a.heic", "a.png"])
            #expect(t.history.menu().undo == "Convert 2 Images")
            await t.shutDown()
        }
    }

    @Test func nothingIsMadeInTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            let trash = "\(root)/.Trash"
            try Self.picture("\(trash)/old.png")
            let t = UndoTest(root: root, trashDir: trashDir)
            await #expect(throws: (any Error).self) {
                try await t.coordinator.convertImages(
                    paths: ["\(trash)/old.png"], options: ImageConversionOptions(), window: t.window)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash) == ["old.png"])
            await t.shutDown()
        }
    }

    @Test func aFileThatCantBeGivenItsNameIsRemoved() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.renameExclusiveImpl = { from, _ in throw NativeError.errno(EEXIST, syscall: "rename", path: from) }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()
        _ = try await coordinator.convertImages(
            paths: ["/Users/demo/a.png"], options: ImageConversionOptions(), window: window,
            encode: { _, _ in Data([1, 2, 3]) })
        let end = await window.ended("write-op-1")
        #expect(end.status == .failed)
        #expect(end.result?.error == "An item named \u{201C}a.jpg\u{201D} already exists.")
        let partial = fileSystem.calls.writeNewFile.first
        #expect(partial?.hasPrefix("/Users/demo/.") == true)
        #expect(partial != nil && fileSystem.calls.rm.map(\.0) == [partial!])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func stoppingLeavesTheRestNotStarted() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()
        let gate = DispatchSemaphore(value: 0)
        let handle = try await coordinator.convertImages(
            paths: ["/Users/demo/a.png", "/Users/demo/b.png", "/Users/demo/c.png"], options: ImageConversionOptions(),
            window: window,
            encode: { _, _ in
                gate.wait()
                return Data([1])
            })
        _ = coordinator.cancel(handle.operationId, window: window)
        gate.signal()
        gate.signal()
        gate.signal()
        let end = await window.ended(handle.operationId)
        #expect(end.status == .cancelled)
        #expect(end.result?.items.filter { $0.status == .completed }.count ?? 0 <= 1)
        await coordinator.shutDown(maxWaitMs: 0)
    }
}
