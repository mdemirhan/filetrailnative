import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct FinderTagsTests {
    private func withFile(_ body: (String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("a.txt").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try body(path)
    }

    private func systemTagNames(_ path: String) throws -> [String] {
        try URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func labelNumber(_ path: String) throws -> Int {
        try URL(fileURLWithPath: path).resourceValues(forKeys: [.labelNumberKey]).labelNumber ?? -1
    }

    @Test func readsWhatMacOSWrites() throws {
        try withFile { path in
            try (URL(fileURLWithPath: path) as NSURL).setResourceValue(
                ["Red", "Project", "Blue"], forKey: .tagNamesKey)
            #expect(
                try FinderTags.read(path) == [
                    FinderTag(name: "Red", color: .red), FinderTag(name: "Project", color: nil),
                    FinderTag(name: "Blue", color: .blue),
                ])
            #expect(FinderTags.colors(path) == [.red, .blue])
        }
    }

    // Groups of tags go by an item's first tag's name, with a color or not; an item without tags has none.
    @Test func theFirstTagNamesTheItemsGroup() throws {
        try withFile { path in
            #expect(FinderTags.firstName(path) == nil)
            try (URL(fileURLWithPath: path) as NSURL).setResourceValue(["Project", "Red"], forKey: .tagNamesKey)
            #expect(FinderTags.firstName(path) == "Project")
        }
        #expect(FinderTags.firstName("/no/such/file") == nil)
    }

    // Reading the tags of the home folder's Desktop, Documents or Downloads makes macOS ask for permission, so
    // showing the home folder leaves them unread; the folders inside them, and the others, are read.
    @Test func leavesTheFoldersMacOSAsksAboutUnread() {
        let home = "/Users/demo"
        for name in ["Desktop", "Documents", "Downloads"] {
            #expect(FinderTags.asksPermission("\(home)/\(name)", homePath: home), "\(name)")
            #expect(FinderTags.asksPermission("\(home)/\(name)/", homePath: home + "/"), "\(name)")
            #expect(!FinderTags.asksPermission("\(home)/\(name)/inner", homePath: home), "\(name)")
        }
        #expect(!FinderTags.asksPermission(home, homePath: home))
        #expect(!FinderTags.asksPermission("\(home)/Pictures", homePath: home))
        #expect(!FinderTags.asksPermission("\(home)/Desktops", homePath: home))
        #expect(!FinderTags.asksPermission("/Users/other/Desktop", homePath: home))
        #expect(FinderTags.colors(NSHomeDirectory() + "/Desktop") == [])
    }

    @Test func macOSReadsWhatIsWrittenWithTheLastColorAsTheLabel() throws {
        try withFile { path in
            try FinderTags.write(
                [FinderTag(name: "Red", color: .red), FinderTag(name: "Blue", color: .blue)], to: path)
            let names = try systemTagNames(path)
            #expect(names == ["Red", "Blue"])
            let label = try labelNumber(path)
            #expect(label == FinderTagColor.blue.rawValue)
        }
    }

    @Test func aCustomTagKeepsItsColorAndNameWhenAnotherColorIsAdded() throws {
        try withFile { path in
            try FinderTags.write(
                [FinderTag(name: "Work", color: .blue), FinderTag(name: "Note", color: nil)], to: path)
            FinderTags.toggle(.red, name: "Red", on: [path])
            #expect(
                try FinderTags.read(path) == [
                    FinderTag(name: "Work", color: .blue), FinderTag(name: "Note", color: nil),
                    FinderTag(name: "Red", color: .red),
                ])
        }
    }

    @Test func aColorOnEveryItemComesOffAndOneOnSomeGoesOnTheRest() throws {
        try withFile { first in
            let second = first + ".2"
            FileManager.default.createFile(atPath: second, contents: Data())
            FinderTags.toggle(.green, name: "Green", on: [first])
            #expect(FinderTags.states(of: [first, second]) == [.green: .some])
            FinderTags.toggle(.green, name: "Green", on: [first, second])
            #expect(FinderTags.colors(first) == [.green])
            #expect(FinderTags.colors(second) == [.green])
            #expect(FinderTags.states(of: [first, second]) == [.green: .all])
            FinderTags.toggle(.green, name: "Green", on: [first, second])
            #expect(FinderTags.colors(first).isEmpty)
            #expect(FinderTags.colors(second).isEmpty)
        }
    }

    @Test func theLastTagGoneLeavesNoAttributeAndNoLabel() throws {
        try withFile { path in
            FinderTags.toggle(.red, name: "Red", on: [path])
            FinderTags.toggle(.red, name: "Red", on: [path])
            #expect(getxattr(path, FinderTags.attribute, nil, 0, 0, 0) < 0)
            let label = try labelNumber(path)
            #expect(label == 0)
        }
    }

    @Test func aTagWithoutANumberHasNoColorAndAnAttributeNotUnderstoodIsNotWrittenOver() throws {
        #expect(FinderTag(stored: "Old") == FinderTag(name: "Old", color: nil))
        try withFile { path in
            let junk = Data("not a list".utf8)
            _ = junk.withUnsafeBytes { setxattr(path, FinderTags.attribute, $0.baseAddress, junk.count, 0, 0) }
            let failures = FinderTags.toggle(.red, name: "Red", on: [path])
            #expect(failures.count == 1)
            var stored = Data(count: junk.count)
            _ = stored.withUnsafeMutableBytes { getxattr(path, FinderTags.attribute, $0.baseAddress, junk.count, 0, 0) }
            #expect(stored == junk)
        }
    }

    @Test func aLockedFileIsReportedAndKeepsItsTags() throws {
        try withFile { path in
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
            #expect(FinderTags.toggle(.red, name: "Red", on: [path]).count == 1)
            #expect(FinderTags.colors(path).isEmpty)
        }
    }
    // The list of attributes is read first, and the tags only when it names them: whatever the item holds, the tags
    // read are those stored.
    @Test func readsTheTagsWhateverElseTheItemHolds() throws {
        try withFile { path in
            #expect(try FinderTags.read(path).isEmpty)
            #expect(!FinderTags.mayHaveTags(path))
            // Other attributes, but no tags.
            let other = Data("x".utf8)
            _ = other.withUnsafeBytes { setxattr(path, "com.example.other", $0.baseAddress, other.count, 0, 0) }
            #expect(try FinderTags.read(path).isEmpty)
            #expect(!FinderTags.mayHaveTags(path))
            // An attribute whose name holds the tags' name isn't them.
            _ = other.withUnsafeBytes {
                setxattr(path, FinderTags.attribute + ".copy", $0.baseAddress, other.count, 0, 0)
            }
            #expect(!FinderTags.mayHaveTags(path))
            try FinderTags.write([FinderTag(name: "Work", color: nil)], to: path)
            #expect(FinderTags.mayHaveTags(path))
            #expect(try FinderTags.read(path) == [FinderTag(name: "Work", color: nil)])
        }
    }

    // A list of attributes too long to read at once leaves the tags to be asked for, and they are read.
    @Test func manyAttributesStillGiveTheTags() throws {
        try withFile { path in
            let value = Data("x".utf8)
            for index in 0..<60 {
                let name = "com.example.a-rather-long-attribute-name-\(index)"
                _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, 0) }
            }
            #expect(listxattr(path, nil, 0, 0) > 1024)
            try FinderTags.write([FinderTag(name: "Red", color: .red)], to: path)
            #expect(try FinderTags.read(path) == [FinderTag(name: "Red", color: .red)])
        }
    }

    // A list of tags longer than one read is sized and read whole.
    @Test func aLongListOfTagsIsReadWhole() throws {
        try withFile { path in
            let tags = (0..<40).map { FinderTag(name: "A tag with a fairly long name \($0)", color: nil) }
            try FinderTags.write(tags, to: path)
            #expect(getxattr(path, FinderTags.attribute, nil, 0, 0, 0) > FinderTags.firstRead)
            #expect(try FinderTags.read(path) == tags)
        }
    }

    // A folder's tags are read as a file's are.
    @Test func aFoldersTagsAreRead() throws {
        try withFile { path in
            let folder = (path as NSString).deletingLastPathComponent + "/folder"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try FinderTags.write([FinderTag(name: "Blue", color: .blue)], to: folder)
            #expect(try FinderTags.read(folder) == [FinderTag(name: "Blue", color: .blue)])
        }
    }
}
