// Checks the path type: two spellings of one name are two paths wherever paths are compared, hashed or ordered, a
// path is the bare string in JSON, and its parts follow NodePath's rules
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct DiskPathTests {
    private let composed = "/tmp/caf\u{E9}"
    private let decomposed = "/tmp/cafe\u{301}"

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Equality, hashing, order

    @Test func twoSpellingsOfOneNameAreTwoPaths() {
        // What the type is for: `String` takes them for one.
        #expect(composed == decomposed)
        #expect(Set([composed, decomposed]).count == 1)

        #expect(DiskPath(composed) != DiskPath(decomposed))
        #expect(DiskPath(composed) == DiskPath("/tmp/caf\u{E9}"))
        #expect(Set([DiskPath(composed), DiskPath(decomposed), DiskPath(composed)]).count == 2)
        var byPath: [DiskPath: Int] = [:]
        byPath[DiskPath(composed)] = 1
        byPath[DiskPath(decomposed)] = 2
        #expect(byPath.count == 2)
        #expect(byPath[DiskPath(composed)] == 1)
        #expect(byPath[DiskPath(decomposed)] == 2)
        #expect([DiskPath(composed)].contains(DiskPath(decomposed)) == false)
    }

    @Test func aPathKeepsItsTextUnchanged() {
        for text in [composed, decomposed, "", "/", "/a//b/", "/a/./b/..", "relative/x", "/a b#?%"] {
            #expect(bytes(DiskPath(text).string) == bytes(text))
        }
        #expect(DiskPath("/a//b/") != DiskPath("/a/b"))
        #expect(DiskPath("/a/") != DiskPath("/a"))
        #expect(DiskPath("/A") != DiskPath("/a"))
    }

    @Test func pathsAreOrderedByTheirBytes() {
        // "e" then the accent (65 CC 81) comes before the composed letter (C3 A9); `String` puts neither first.
        #expect(DiskPath(decomposed) < DiskPath(composed))
        #expect(!(DiskPath(composed) < DiskPath(decomposed)))
        #expect(!(composed < decomposed) && !(decomposed < composed))
        #expect(DiskPath("/a") < DiskPath("/a/b"))
        #expect(DiskPath("/a/b") < DiskPath("/ab"))
        #expect(DiskPath("") < DiskPath("/"))
        #expect(!(DiskPath("/a") < DiskPath("/a")))
        #expect(DiskPath("/Z") < DiskPath("/a"))
        let sorted = [DiskPath(composed), "/tmp/cafz", DiskPath(decomposed), "/tmp/caf", "/tmp"].sorted()
        #expect(sorted == ["/tmp", "/tmp/caf", DiskPath(decomposed), "/tmp/cafz", DiskPath(composed)])
    }

    @Test func aStringFromFoundationIsTheSamePathAsASwiftOne() throws {
        // Saved state and the journal are read by JSONSerialization, whose strings hold UTF-16.
        let data = Data("[\"/tmp/caf\\u00e9\", \"/tmp/cafe\\u0301\"]".utf8)
        let read = try #require(try JSONSerialization.jsonObject(with: data) as? [String])
        let paths = read.map(DiskPath.init)
        #expect(paths == [DiskPath(composed), DiskPath(decomposed)])
        #expect(paths[0].hashValue == DiskPath(composed).hashValue)
        #expect(Set(paths).contains(DiskPath(decomposed)))
        #expect(paths[0] != paths[1])
        for path in paths {
            #expect(path.string.utf8.withContiguousStorageIfAvailable { _ in true } == true)
        }
        let bridged = NSString(string: decomposed) as String
        #expect(DiskPath(bridged) == DiskPath(decomposed))
        #expect(DiskPath(bridged).hashValue == DiskPath(decomposed).hashValue)
    }

    // MARK: JSON

    private struct Saved: Codable {
        var path: String
        var others: [String]
        var none: String?
    }

    private struct Typed: Codable, Equatable {
        var path: DiskPath
        var others: [DiskPath]
        var none: DiskPath?
    }

    @Test func aPathIsTheBareStringInJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for text in [composed, decomposed, "", "/a \"b\"/\u{1F600}"] {
            #expect(try encoder.encode(DiskPath(text)) == encoder.encode(text))
            let saved = Saved(path: text, others: [text, "/x"], none: nil)
            let typed = Typed(path: DiskPath(text), others: [DiskPath(text), "/x"], none: nil)
            #expect(try encoder.encode(typed) == encoder.encode(saved))
        }
        #expect(String(decoding: try encoder.encode([DiskPath("a")]), as: UTF8.self) == "[\"a\"]")
    }

    @Test func aSavedStringIsReadAsThePathItWas() throws {
        for text in [composed, decomposed, "/a//b/"] {
            let saved = try JSONEncoder().encode(Saved(path: text, others: [text], none: text))
            let typed = try JSONDecoder().decode(Typed.self, from: saved)
            #expect(bytes(typed.path.string) == bytes(text))
            #expect(typed == Typed(path: DiskPath(text), others: [DiskPath(text)], none: DiskPath(text)))
            #expect(typed.path.string.utf8.withContiguousStorageIfAvailable { _ in true } == true)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([DiskPath].self, from: Data("[1]".utf8)) }
    }

    // MARK: Written as text

    @Test func aPathIsWrittenAsALiteralAndReadAsItsText() {
        let name = "cafe\u{301}"
        let literal: DiskPath = "/tmp/caf\u{E9}"
        let interpolated: DiskPath = "/tmp/\(name)"
        #expect(literal == DiskPath(composed))
        #expect(interpolated == DiskPath(decomposed))
        #expect("\(interpolated)" == decomposed && bytes("\(interpolated)") == bytes(decomposed))
        #expect(String(describing: literal) == "/tmp/caf\u{E9}")
        #expect(String(reflecting: DiskPath("/a \"b\"")) == String(reflecting: "/a \"b\""))
        // `init(_:)`, though the literal's initializer takes a string too.
        #expect(["/a", "/b"].map(DiskPath.init) == ["/a", "/b"])
    }

    // MARK: Parts

    @Test func theNameAndTheParentAreNodePaths() {
        let cases: [(path: String, name: String, parent: String)] = [
            ("/a/b.txt", "b.txt", "/a"), ("b", "b", "."), ("/a/b/", "b", "/a"), ("/", "", "/"), ("", "", "."),
            ("//", "", "/"), ("/a", "a", "/"), ("a", "a", "."), ("a/b", "b", "a"), ("//a", "a", "//"),
            (composed, "caf\u{E9}", "/tmp"), (decomposed, "cafe\u{301}", "/tmp"),
            ("/caf\u{E9}/x", "x", "/caf\u{E9}"), ("/cafe\u{301}/x", "x", "/cafe\u{301}"),
            // A mark after the slash is the name's first scalar, not part of the slash.
            ("/a/\u{301}b", "\u{301}b", "/a"),
        ]
        for (path, name, parent) in cases {
            #expect(bytes(DiskPath(path).name) == bytes(name), "name of \(path.debugDescription)")
            #expect(DiskPath(path).parent == DiskPath(parent), "parent of \(path.debugDescription)")
            #expect(bytes(DiskPath(path).name) == bytes(NodePath.basename(path)))
            #expect(bytes(DiskPath(path).parent.string) == bytes(NodePath.dirname(path)))
        }
    }

    @Test func appendingANameJoinsAsNodePathDoes() {
        let cases: [(folder: String, name: String, path: String)] = [
            ("/target", "a copy.txt", "/target/a copy.txt"), ("/target/", "a", "/target/a"), ("/", "a", "/a"),
            ("/a", "b/", "/a/b/"), ("/a", "..\u{301}", "/a/..\u{301}"), ("/a//b", "c", "/a/b/c"),
            ("/tmp", "caf\u{E9}", composed), ("/tmp", "cafe\u{301}", decomposed),
            ("/caf\u{E9}", "x", "/caf\u{E9}/x"), ("/cafe\u{301}", "x", "/cafe\u{301}/x"),
        ]
        for (folder, name, path) in cases {
            #expect(DiskPath(folder).appending(name) == DiskPath(path), "\(folder.debugDescription) + \(name)")
            #expect(bytes(DiskPath(folder).appending(name).string) == bytes(NodePath.join(folder, name)))
        }
        #expect(DiskPath(composed).parent.appending(DiskPath(composed).name) == DiskPath(composed))
        #expect(DiskPath(decomposed).parent.appending(DiskPath(decomposed).name) == DiskPath(decomposed))
    }

    @Test func insideAFolderIsToldPartByPart() {
        #expect(DiskPath("/a/b").isInside("/a"))
        #expect(DiskPath("/a/b/c/d").isInside("/a/b"))
        #expect(!DiskPath("/ab").isInside("/a"))
        #expect(!DiskPath("/a b").isInside("/a"))
        #expect(!DiskPath("/a").isInside("/a"))
        #expect(!DiskPath("/a").isInside("/a/b"))
        #expect(DiskPath("/a").isInside("/"))
        #expect(DiskPath("//").isInside("/"))
        #expect(!DiskPath("/").isInside("/"))
        #expect(!DiskPath("relative").isInside("/"))
        #expect(!DiskPath("/a").isInside(""))
        #expect(!DiskPath("/a/b").isInside("/a/"))
        #expect(DiskPath("/a//b").isInside("/a/"))
        #expect(DiskPath("a/b").isInside("a"))
        #expect(!DiskPath("/A/b").isInside("/a"))
        // The folder's spelling counts: the other one is another folder.
        #expect(DiskPath("/caf\u{E9}/x").isInside("/caf\u{E9}"))
        #expect(!DiskPath("/cafe\u{301}/x").isInside("/caf\u{E9}"))
        #expect(!DiskPath("/caf\u{E9}/x").isInside("/cafe\u{301}"))
        // "/a" then a mark is another name, not "/a" and something in it.
        #expect(!DiskPath("/a\u{301}/b").isInside("/a"))
        #expect(DiskPath("/a/\u{301}").isInside("/a"))

        #expect(DiskPath("/a").isAtOrInside("/a"))
        #expect(DiskPath("/a/b").isAtOrInside("/a"))
        #expect(DiskPath("/").isAtOrInside("/"))
        #expect(!DiskPath("/ab").isAtOrInside("/a"))
        #expect(!DiskPath(decomposed).isAtOrInside(DiskPath(composed)))
    }

    /// The paths picked without those inside another one picked, told with `isInside`: the golden file's cases
    /// say which path is inside which, the root, doubled slashes and both spellings among them.
    @Test func insideAgreesWithTheNestedPathsGoldenFile() throws {
        let cases: [GoldenCase<[String], [String]>] = try Golden.load(suite: "paths-nested")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { input in
            let picked = input.map(DiskPath.init)
            var seen = Set<DiskPath>()
            return picked.filter { path in
                !picked.contains { path.isInside($0) } && seen.insert(path).inserted
            }.map(\.string)
        }
    }

    // MARK: Text that isn't a path

    @Test func anExactNameKeepsTheTwoSpellingsApartToo() {
        let composedName = NameKeys.Exact("caf\u{E9}")
        let decomposedName = NameKeys.Exact("cafe\u{301}")
        #expect(composedName != decomposedName)
        #expect(composedName == NameKeys.Exact("caf\u{E9}"))
        #expect(Set([composedName, decomposedName, NameKeys.Exact("caf\u{E9}")]).count == 2)
        #expect(NameKeys.Exact(NSString(string: "cafe\u{301}") as String) == decomposedName)
        #expect(NameKeys.Exact(NSString(string: "cafe\u{301}") as String).hashValue == decomposedName.hashValue)
        #expect(NameKeys.Exact("A") != NameKeys.Exact("a"))
        // A key made to be compared has one spelling for both.
        #expect(NameKeys.exactDestinationKey(composed) == NameKeys.exactDestinationKey(decomposed))
    }
}
