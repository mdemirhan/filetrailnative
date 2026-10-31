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
}
