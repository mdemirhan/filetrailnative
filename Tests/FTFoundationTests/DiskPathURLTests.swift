// Checks the path's way to a file URL and back: the URL made from a path holds the path's bytes, where Foundation's
// own initializers respell a composed accent
import Foundation
import Testing

@testable import FTFoundation

struct DiskPathURLTests {
    private let composed = "/tmp/caf\u{E9}/r\u{E9}sum\u{E9}.txt"
    private let decomposed = "/tmp/cafe\u{301}/re\u{301}sume\u{301}.txt"

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// The bytes a C call is given for the URL.
    private func representation(_ url: URL) -> [UInt8]? {
        url.withUnsafeFileSystemRepresentation { $0.map { Array(String(cString: $0).utf8) } }
    }

    @Test func aURLMadeFromAPathHoldsThePathsBytes() throws {
        let paths = [
            composed, decomposed, "/", "/a", "/a b/c#d?e%f", "/a/\u{1F600}/\u{D55C}\u{AE00}", "/a//b/./c/../d",
            "/A/a",
        ]
        for path in paths {
            for isDirectory in [false, true] {
                let url = DiskPath(path).url(isDirectory: isDirectory)
                #expect(url.isFileURL)
                #expect(url.hasDirectoryPath == (isDirectory || path == "/"), "\(path.debugDescription)")
                #expect(representation(url) == bytes(path), "\(path.debugDescription)")
                let back = try #require(DiskPath(urlSpelling: url))
                #expect(back == DiskPath(path), "\(path.debugDescription)")
            }
        }
    }

    // Why paths don't go through Foundation's own initializers: a composed accent comes back decomposed, which is
    // another path, and on a disk that keeps the name composed and looks it up byte for byte, no item's.
    @Test func foundationsOwnURLsRespellAComposedAccent() throws {
        let made = [
            URL(fileURLWithPath: composed, isDirectory: false), URL(filePath: composed, directoryHint: .notDirectory),
        ]
        for url in made {
            #expect(representation(url) != bytes(composed))
            #expect(representation(url) == bytes(decomposed))
            #expect(bytes(url.path) == bytes(decomposed))
            let spelled = try #require(DiskPath(urlSpelling: url))
            #expect(spelled != DiskPath(composed))
            #expect(spelled == DiskPath(decomposed))
        }
        #expect(representation(DiskPath(composed).url(isDirectory: false)) == bytes(composed))
    }

    @Test func aFoldersURLGivesThePathWithoutASlashAtItsEnd() throws {
        let url = DiskPath("/tmp/caf\u{E9}").url(isDirectory: true)
        #expect(url.absoluteString == "file:///tmp/caf%C3%A9/")
        #expect(try #require(DiskPath(urlSpelling: url)) == DiskPath("/tmp/caf\u{E9}"))
        let plain = try #require(URL(string: "file:///tmp/a%20b/"))
        #expect(DiskPath(urlSpelling: plain) == DiskPath("/tmp/a b"))
    }

    @Test func aURLThatIsNoFilesHasNoPath() throws {
        #expect(DiskPath(urlSpelling: try #require(URL(string: "https://example.com/a/b"))) == nil)
        #expect(DiskPath(urlSpelling: try #require(URL(string: "mailto:someone@example.com"))) == nil)
    }
}
