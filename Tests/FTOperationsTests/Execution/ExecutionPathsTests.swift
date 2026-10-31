// The engine's dirname and basename answer as Node's path module does (Sources/FTOperations/Execution/ExecutionPaths.swift)
import FTFoundation
import Testing

@testable import FTOperations

struct ExecutionPathsTests {
    @Test(arguments: [
        "/", "/a", "/a/b", "/a/b/", "/a//b", "//a", "a", "a/b", "", "/Café/naïve.txt", "/a/.hidden", "/a/b c/d e.txt",
        "/🎉/👩‍👩‍👧‍👦.txt", "///", "/a/b//",
    ])
    func answersAsNodePathDoes(path: String) {
        #expect(dirnameOf(path).unicodeScalars.elementsEqual(NodePath.dirname(path).unicodeScalars))
        #expect(basenameOf(path).unicodeScalars.elementsEqual(NodePath.basename(path).unicodeScalars))
    }
}
