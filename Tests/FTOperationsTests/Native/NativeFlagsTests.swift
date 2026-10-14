// Port of the nativeGetFlags / nativeSetFlags cases of packages/native-fs/src/native-fs.test.ts, with the ACL calls
import Darwin
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private typealias Files = NativeTestFiles

struct NativeFlagsTests {
    private let immutable = UInt32(UF_IMMUTABLE)

    private func withFile(_ body: (TemporaryDirectory, String) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "native-fs-flags") { root in
            let path = root.appending("a.txt").path
            try Files.write(path, "content")
            defer { try? NativeFS.setFlags(path, 0) }
            try body(root, path)
        }
    }

    // T-cfcc8978 F-415 F-334
    @Test func locksAndUnlocksAnItemTheWayFindersLockedCheckboxDoes() throws {
        try withFile { root, path in
            #expect(try NativeFS.getFlags(path) == 0)
            try NativeFS.setFlags(path, immutable)
            #expect(try NativeFS.getFlags(path) == immutable)
            #expect(rename(path, root.appending("b.txt").path) != 0)
            try NativeFS.setFlags(path, 0)
            #expect(try NativeFS.getFlags(path) == 0)
        }
    }

    // T-d0bb8bbb F-415
    @Test func readsASymlinksOwnFlagsNotItsTargets() throws {
        try withFile { root, path in
            try FileManager.default.createSymbolicLink(atPath: root.appending("link").path, withDestinationPath: path)
            try NativeFS.setFlags(path, immutable)
            #expect(try NativeFS.getFlags(root.appending("link").path) == 0)
        }
    }

    // T-9d501eab F-415
    @Test func namesTheErrnoForAMissingItem() throws {
        try withFile { root, _ in
            let missing = root.appending("missing").path
            let read = #expect(throws: NativeError.self) { try NativeFS.getFlags(missing) }
            #expect(read?.code == "ENOENT" && read?.syscall == "lstat")
            let set = #expect(throws: NativeError.self) { try NativeFS.setFlags(missing, 0) }
            #expect(set?.code == "ENOENT" && set?.syscall == "lchflags")
        }
    }
}

struct NativeAclTests {
    // The entry a copy of ~/Documents carries, which keeps the Trash from taking it.
    // F-416
    @Test func readsTakesOffAndPutsBackAnItemsAccessControlList() throws {
        try withTemporaryDirectory(prefix: "native-fs-acl") { root in
            let path = root.appending("a.txt").path
            try Files.write(path, "a")
            #expect(try NativeFS.getAcl(path) == nil)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone deny delete", path]
            try chmod.run()
            chmod.waitUntilExit()
            #expect(chmod.terminationStatus == 0)

            let text = try #require(try NativeFS.getAcl(path))
            #expect(text.contains("everyone") && text.contains("deny") && text.contains("delete"))
            try NativeFS.setAcl(path, nil)
            #expect(try NativeFS.getAcl(path) == nil)
            try NativeFS.setAcl(path, text)
            #expect(try NativeFS.getAcl(path) == text)
            try NativeFS.setAcl(path, nil)
        }
    }

    // F-416
    @Test func tellsAMissingItemFromOneWithoutAnAcl() throws {
        try withTemporaryDirectory(prefix: "native-fs-acl") { root in
            let missing = root.appending("missing").path
            let read = #expect(throws: NativeError.self) { try NativeFS.getAcl(missing) }
            #expect(read?.code == "ENOENT" && read?.syscall == "lstat")
            let set = #expect(throws: NativeError.self) { try NativeFS.setAcl(missing, nil) }
            #expect(set?.code == "ENOENT" && set?.syscall == "acl_set_link_np")
            let bad = #expect(throws: NativeError.self) { try NativeFS.setAcl(root.path, "not an acl") }
            #expect(bad?.syscall == "acl_from_text")
        }
    }
}
