// Checks NodePath against what Node's posix path module answers
import Testing

@testable import FTFoundation

struct NodePathTests {
    @Test func basename() {
        #expect(NodePath.basename("/a/b.txt") == "b.txt")
        #expect(NodePath.basename("b") == "b")
        #expect(NodePath.basename("/a/b/") == "b")
        #expect(NodePath.basename("/") == "")
        #expect(NodePath.basename("") == "")
        #expect(NodePath.basename("//") == "")
    }

    @Test func dirname() {
        #expect(NodePath.dirname("/a/b.txt") == "/a")
        #expect(NodePath.dirname("/a") == "/")
        #expect(NodePath.dirname("a") == ".")
        #expect(NodePath.dirname("/") == "/")
        #expect(NodePath.dirname("") == ".")
        #expect(NodePath.dirname("/a/b/") == "/a")
        #expect(NodePath.dirname("a/b") == "a")
        #expect(NodePath.dirname("//a") == "//")
    }

    @Test func extname() {
        #expect(NodePath.extname("a.txt") == ".txt")
        #expect(NodePath.extname("a.b.c") == ".c")
        #expect(NodePath.extname(".env") == "")
        #expect(NodePath.extname(".a.b") == ".b")
        #expect(NodePath.extname("a.") == ".")
        #expect(NodePath.extname("..") == "")
        #expect(NodePath.extname("...") == ".")
        #expect(NodePath.extname("a") == "")
        #expect(NodePath.extname("/x.y/z") == "")
    }

    @Test func joinAndNormalize() {
        #expect(NodePath.join("/target", "a copy.txt") == "/target/a copy.txt")
        #expect(NodePath.join("/target/", "a") == "/target/a")
        #expect(NodePath.join("/", "a") == "/a")
        #expect(NodePath.join("a", "..", "b") == "b")
        #expect(NodePath.join("/a", "../../b") == "/b")
        #expect(NodePath.join("", "") == ".")
        #expect(NodePath.join("a", "..") == ".")
        #expect(NodePath.join("/a//b", "./c") == "/a/b/c")
        #expect(NodePath.join("/a", "b/") == "/a/b/")
        #expect(NodePath.join("..", "x") == "../x")
        #expect(NodePath.join("/a", "..\u{301}") == "/a/..\u{301}")
        #expect(NodePath.resolve("/a/b//") == "/a/b")
        #expect(NodePath.resolve("/") == "/")
        #expect(NodePath.resolve("/a/../") == "/")
    }
}
