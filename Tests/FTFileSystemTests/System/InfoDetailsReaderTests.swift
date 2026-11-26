import CoreGraphics
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTFileSystem

@Suite("info details reader")
struct InfoDetailsReaderTests {
    private func write(_ text: String, to path: String) {
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    @Test func aTextFileSaysItsLinesOwnerAndPlace() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("notes.swift").path
            write("let a = 1\r\nlet b = 2\r\nprint(a + b)", to: path)
            let details = try #require(InfoDetailsReader.read(path))
            #expect(details.text == InfoDetails.Text(lines: 3, encoding: "UTF-8", lineEnding: "CRLF"))
            #expect(details.owner?.isYou == true)
            #expect(details.sizeOnDisk.map { $0 > 0 } == true)
            #expect(details.more.contentType == "public.swift-source")
            #expect(details.more.linkCount == 1)
            #expect(details.image == nil && details.media == nil && details.document == nil && details.app == nil)
        }
    }

    // An app updated while File Trail runs shows its new version: its Info.plist is read from the file each time,
    // where `Bundle` answered what it read first for as long as the app ran.
    @Test func anAppUpdatedSaysItsNewVersion() throws {
        try withTemporaryDirectory { folder in
            let app = folder.appending("Tool.app")
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            func write(_ version: String) throws {
                let list: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "demo.tool"]
                try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
                    .write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            try write("1.0")
            #expect(InfoDetailsReader.app(app.path).version == "1.0")
            try write("2.0")
            #expect(InfoDetailsReader.app(app.path).version == "2.0")
            #expect(InfoDetailsReader.app(app.path).identifier == "demo.tool")
        }
    }

    // A text file that hasn't changed isn't read whole again for the same answer (its folder read again asks for
    // its details again); one that changed is.
    @Test func aTextFileUnchangedIsCountedOnce() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("log.txt").path
            write("one\ntwo\n", to: path)
            var counted = 0
            func facts() -> InfoDetails.Text? {
                var info = stat()
                #expect(lstat(path, &info) == 0)
                return TextFacts.of(path, info) {
                    counted += 1
                    return InfoDetailsReader.textRead(path)
                }
            }
            #expect(facts()?.lines == 2)
            #expect(facts()?.lines == 2)
            #expect(counted == 1)
            write("one\ntwo\nthree\n", to: path)
            #expect(facts()?.lines == 3)
            #expect(counted == 2)
        }
    }

    // A read no longer wanted stops before the file is read, and what it would have answered isn't kept.
    @Test func aTextReadNoLongerWantedStops() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("gone.txt").path
            write("one\ntwo\n", to: path)
            let cancel = ReadCancel()
            cancel.cancel()
            #expect(InfoDetailsReader.text(path, cancel: cancel) == nil)
            #expect(InfoDetailsReader.read(path, cancel: cancel) == nil)
            var info = stat()
            #expect(lstat(path, &info) == 0)
            let unwanted = TextFacts.of(path, info, cancel: cancel) { InfoDetailsReader.textRead(path, cancel: cancel) }
            #expect(unwanted == nil)
            #expect(InfoDetailsReader.read(path)?.text?.lines == 2)
        }
    }

    // A text file that can't be read has no answer to keep: given Read (which changes neither its size nor its
    // time), it is counted.
    @Test func aTextFileMadeReadableIsCounted() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("locked.txt").path
            write("one\ntwo\n", to: path)
            #expect(chmod(path, 0) == 0)
            #expect(InfoDetailsReader.read(path)?.text == nil)
            #expect(chmod(path, 0o644) == 0)
            #expect(InfoDetailsReader.read(path)?.text?.lines == 2)
        }
    }

    // A framework keeps its Info.plist in Resources, and a bundle that doesn't name its program has it under its
    // own name.
    @Test func aFrameworkSaysItsVersionAndWhatItRunsOn() throws {
        let app = InfoDetailsReader.app("/System/Library/Frameworks/AppKit.framework")
        #expect(app.identifier == "com.apple.AppKit")
        #expect(app.version != nil)
        try withTemporaryDirectory { folder in
            let tool = folder.appending("Tool.app")
            try FileManager.default.createDirectory(
                at: tool.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": "1.0"], format: .xml, options: 0
            ).write(to: tool.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.copyItem(
                atPath: "/bin/ls", toPath: tool.appendingPathComponent("Contents/MacOS/Tool").path)
            #expect(InfoDetailsReader.app(tool.path).runsOn != nil)
        }
    }

    // A line with no ending counts; an empty file has none.
    @Test func linesAreCountedAsAnEditorShowsThem() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("a.txt").path
            write("one\ntwo\n", to: path)
            #expect(InfoDetailsReader.read(path)?.text?.lines == 2)
            write("one\ntwo", to: path)
            #expect(InfoDetailsReader.read(path)?.text?.lines == 2)
            write("", to: path)
            #expect(
                InfoDetailsReader.read(path)?.text == InfoDetails.Text(lines: 0, encoding: "UTF-8", lineEnding: "None"))
        }
    }

    @Test func aDownloadSaysWhereItCameFrom() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("a.pdf").path
            write("%PDF-1.4", to: path)
            let froms = try PropertyListSerialization.data(
                fromPropertyList: ["https://example.net/a.pdf", "https://example.net/"], format: .binary, options: 0)
            _ = froms.withUnsafeBytes { setxattr(path, DownloadMarks.whereFrom, $0.baseAddress, froms.count, 0, 0) }
            let mark = "0083;6a1f2c80;Safari;"
            _ = setxattr(path, DownloadMarks.quarantine, mark, mark.utf8.count, 0, 0)
            let download = try #require(InfoDetailsReader.read(path)?.download)
            #expect(download.from == "https://example.net/a.pdf")
            #expect(download.page == "https://example.net/")
            #expect(download.agent == "Safari")
            #expect(download.date == Date(timeIntervalSince1970: 0x6a1f_2c80))
            #expect(InfoDetailsReader.read(path)?.more.attributes.contains(DownloadMarks.quarantine) == true)
        }
    }

    // On a disk Spotlight doesn't index, a picture's size comes from its header.
    @Test func aPictureSaysItsSize() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("dot.png").path
            let context = try #require(
                CGContext(
                    data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            let read = try #require(InfoDetailsReader.read(path)?.image)
            #expect(read.width == 3 && read.height == 2)
        }
    }

    @Test func aCancelledReadAnswersNothing() throws {
        try withTemporaryDirectory { folder in
            let path = folder.appending("a.txt").path
            write("x", to: path)
            let cancel = ReadCancel()
            cancel.cancel()
            #expect(InfoDetailsReader.read(path, cancel: cancel) == nil)
        }
    }

    @Test func theSignerAsPeopleKnowIt() {
        #expect(
            InfoDetailsReader.signer("Developer ID Application: Lumen Labs (ABCDE12345)") == "Developer ID · Lumen Labs"
        )
        #expect(InfoDetailsReader.signer("Apple Mac OS Application Signing") == "Mac App Store")
        #expect(InfoDetailsReader.signer("Software Signing") == "Apple")
        #expect(InfoDetailsReader.signer("macOS Software Signing") == "Apple")
        #expect(InfoDetailsReader.signer("Apple Development: Someone (X)") == "Development")
    }

    @Test func anAppSaysItsVersionAndSigner() throws {
        let path = "/System/Applications/Calculator.app"
        try #require(FileManager.default.fileExists(atPath: path))
        let app = try #require(InfoDetailsReader.read(path)?.app)
        #expect(app.identifier == "com.apple.calculator")
        #expect(app.version != nil && app.runsOn != nil)
        #expect(InfoDetailsReader.signing(path)?.signedBy == "Apple")
    }

    @Test func codecsAndCamerasAsPeopleKnowThem() {
        #expect(InfoDetailsReader.codecName(0x6176_6331) == "H.264")  // avc1
        #expect(InfoDetailsReader.codecName(0x6161_6320) == "AAC")  // "aac "
        #expect(InfoDetailsReader.camera(make: "Apple", model: "iPhone 16 Pro") == "iPhone 16 Pro")
        #expect(InfoDetailsReader.camera(make: "FUJIFILM", model: "X-T5") == "FUJIFILM X-T5")
        #expect(InfoDetailsReader.camera(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(InfoDetailsReader.camera(make: nil, model: nil) == nil)
    }
}
