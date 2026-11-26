import AppKit
import FTFoundation
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

    // The views show an item's tags in the order they were put on in; an item without tags has none.
    @Test func anItemsTagsShowInTheirOrder() throws {
        try withFile { path in
            #expect(FinderTags.shown(path).isEmpty)
            try (URL(fileURLWithPath: path) as NSURL).setResourceValue(["Project", "Red"], forKey: .tagNamesKey)
            #expect(FinderTags.shown(path).map(\.name) == ["Project", "Red"])
        }
        #expect(FinderTags.shown("/no/such/file").isEmpty)
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

    // A tag of the Tags popover is its name, case aside: on every item it comes off them all, whatever its color on
    // each; otherwise it goes on those without it in its own color, the other tags staying.
    @Test func aNamedTagGoesOnTheItemsWithoutItAndComesOffWhenAllHaveIt() throws {
        try withFile { first in
            let second = first + ".2"
            FileManager.default.createFile(atPath: second, contents: Data())
            try FinderTags.write(
                [FinderTag(name: "work", color: .blue), FinderTag(name: "Red", color: .red)], to: first)
            let work = FinderTag(name: "Work", color: nil)
            #expect(FinderTags.toggle(work, on: [first, second]).isEmpty)
            #expect(
                try FinderTags.read(first) == [
                    FinderTag(name: "work", color: .blue), FinderTag(name: "Red", color: .red),
                ])
            #expect(try FinderTags.read(second) == [work])
            let both = FinderTags.onItems([first, second])
            #expect(both.itemCount == 2)
            #expect(both.count(of: work) == 2)
            #expect(both.count(of: FinderTag(name: "red", color: nil)) == 1)
            #expect(both.tags.map(\.name) == ["work", "Red"])
            FinderTags.toggle(work, on: [first, second])
            #expect(try FinderTags.read(first) == [FinderTag(name: "Red", color: .red)])
            #expect(try FinderTags.read(second).isEmpty)
        }
    }

    // Remove All Tags leaves no tag and no label; an item without tags isn't written.
    @Test func removeAllTakesEveryTagOff() throws {
        try withFile { first in
            let second = first + ".2"
            FileManager.default.createFile(atPath: second, contents: Data())
            try FinderTags.write(
                [FinderTag(name: "Work", color: nil), FinderTag(name: "Blue", color: .blue)], to: first)
            #expect(FinderTags.removeAll(from: [first, second]).isEmpty)
            #expect(try FinderTags.read(first).isEmpty)
            #expect(try labelNumber(first) == 0)
            #expect(FinderTags.onItems([first, second]).tags.isEmpty)
        }
    }

    // An item whose tags can't be read is reported, and counts as having none.
    @Test func anItemWhoseTagsCantBeReadIsReported() throws {
        try withFile { path in
            let junk = Data("not a list".utf8)
            _ = junk.withUnsafeBytes { setxattr(path, FinderTags.attribute, $0.baseAddress, junk.count, 0, 0) }
            let read = FinderTags.onItems([path])
            #expect(read.failures.map(\.path) == [path])
            #expect(read.tags.isEmpty)
            #expect(FinderTags.removeAll(from: [path]).count == 1)
        }
    }
}

@Suite struct FinderTagChecklistTests {
    private let colorNames: [FinderTagColor: String] = [
        .red: "Red", .orange: "Orange", .yellow: "Yellow", .green: "Green", .blue: "Blue", .purple: "Purple",
        .gray: "Gray",
    ]

    // One's own tags come first by name, then the seven colors in the color row's order; a tag named as a color keeps
    // the color's place; each row says how many items have it, and a name in use and on the items is listed once in
    // the items' color.
    @Test func ownTagsByNameThenTheSevenColors() {
        let items = FinderTagsOnItems(
            itemCount: 3,
            tags: [FinderTag(name: "Work", color: .blue), FinderTag(name: "red", color: .purple)],
            counts: ["work": 2, "red": 3], failures: [])
        let inUse = [
            FinderTag(name: "work", color: nil), FinderTag(name: "Home", color: .gray),
            FinderTag(name: "Important", color: .red), FinderTag(name: "Blue", color: .blue),
        ]
        let rows = FinderTagChecklist.rows(
            on: items, inUse: inUse, colorNames: colorNames, order: NameOrder(localeIdentifier: "en_US"))
        #expect(
            rows.map(\.tag.name) == [
                "Home", "Important", "Work", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray",
            ])
        #expect(rows.map(\.count) == [0, 0, 2, 3, 0, 0, 0, 0, 0, 0])
        #expect(rows.map(\.isColor) == [false, false, false] + Array(repeating: true, count: 7))
        #expect(rows[2].tag.color == .blue)
        #expect(rows[3].tag.color == .red)
    }

    // A color renamed in Finder's settings, or in another language, is the color's row under its name.
    @Test func aColorGoesByItsNameInThisLanguage() {
        var names = colorNames
        names[.red] = "Rot"
        let rows = FinderTagChecklist.rows(
            on: FinderTagsOnItems(
                itemCount: 1, tags: [FinderTag(name: "Red", color: .red)], counts: ["red": 1], failures: []),
            inUse: [], colorNames: names, order: NameOrder(localeIdentifier: "en_US"))
        #expect(rows.first?.tag == FinderTag(name: "Red", color: .red))
        #expect(rows.first?.isColor == false)
        #expect(rows[1].tag == FinderTag(name: "Rot", color: .red))
    }

    @Test func filterFindsANameAsTheFileFilterDoes() {
        let rows = ["Café", "Work", "Red"].map {
            FinderTagChecklistRow(tag: FinderTag(name: $0, color: nil), count: 0, isColor: false)
        }
        #expect(FinderTagChecklist.filter(rows, by: "cafe").map(\.tag.name) == ["Café"])
        #expect(FinderTagChecklist.filter(rows, by: "R").map(\.tag.name) == ["Work", "Red"])
        #expect(FinderTagChecklist.filter(rows, by: "").count == 3)
    }

    // A name stored in several colors is listed once, in the color most items have it in.
    @Test func aNameInSeveralColorsTakesTheCommonestOne() {
        let merged = FinderTagCatalog.merged([
            (FinderTag(name: "Work", color: nil), 3), (FinderTag(name: "work", color: .blue), 10),
            (FinderTag(name: "Home", color: .gray), 1), (FinderTag(name: "", color: nil), 5),
        ])
        #expect(merged == [FinderTag(name: "work", color: .blue), FinderTag(name: "Home", color: .gray)])
    }
}
