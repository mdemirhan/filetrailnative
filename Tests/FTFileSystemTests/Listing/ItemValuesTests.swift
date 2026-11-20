import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

/// One field read for each of a list of items: what search results ordered or grouped by it need, and nothing more.
struct ItemValuesTests {
    private func fake() -> FakeFileSystem {
        let fake = FakeFileSystem()
        fake.lstatHandler = { path in
            path.hasSuffix("Folder")
                ? fakeStats(directory: true, file: false, size: 96, mtimeMs: 9, birthtimeMs: 8)
                : fakeStats(directory: false, file: true, size: 42, mtimeMs: 2_000, birthtimeMs: 1_000)
        }
        fake.addedHandler = { $0.hasSuffix("a.txt") ? 5 : nil }
        fake.lastOpenedHandler = { $0.hasSuffix("a.txt") ? 7 : nil }
        fake.firstTagHandler = { $0.hasSuffix("a.txt") ? "Work" : nil }
        return fake
    }

    private let paths = ["/r/a.txt", "/r/b.txt", "/r/Folder"]

    @Test func eachFieldReadsItsOwnValueAndNothingElse() {
        let fake = fake()
        #expect(ExplorerListing.values(paths, field: .modified, fake) == [.number(2_000), .number(2_000), .number(9)])
        #expect(ExplorerListing.values(paths, field: .created, fake).map(\.number) == [1_000, 1_000, 8])
        // A folder's size is measured, not listed.
        #expect(ExplorerListing.values(paths, field: .size, fake).map(\.number) == [42, 42, nil])
        #expect(fake.tagNamesRead.isEmpty && fake.addedRead.isEmpty)
        #expect(ExplorerListing.values(paths, field: .added, fake).map(\.number) == [5, nil, nil])
        #expect(ExplorerListing.values(paths, field: .lastOpened, fake).map(\.number) == [7, nil, nil])
        let tags = ExplorerListing.values(paths, field: .tags, fake)
        #expect(tags.map(\.text) == ["Work", nil, nil] && tags.allSatisfy { $0.number == nil })
        #expect(fake.tagNamesRead == paths)
    }

    // A link is ordered and grouped by what its columns show: the dates and size of the file it leads to, its own
    // size when it leads to a folder, and its own when it leads nowhere.
    @Test func aLinkHasTheValuesOfWhatItLeadsTo() {
        let fake = FakeFileSystem()
        fake.lstatHandler = { _ in
            fakeStats(directory: false, file: false, size: 11, symbolicLink: true, mtimeMs: 1, birthtimeMs: 1)
        }
        fake.statHandler = { path in
            if path.hasSuffix("broken") { throw FakeError() }
            return path.hasSuffix("to-folder")
                ? fakeStats(directory: true, file: false, size: 96, mtimeMs: 300, birthtimeMs: 200)
                : fakeStats(directory: false, file: true, size: 2_000_000, mtimeMs: 500, birthtimeMs: 400)
        }
        let links = ["/r/to-file", "/r/to-folder", "/r/broken"]
        #expect(ExplorerListing.values(links, field: .size, fake).map(\.number) == [2_000_000, 11, 11])
        #expect(ExplorerListing.values(links, field: .modified, fake).map(\.number) == [500, 300, 1])
        #expect(ExplorerListing.values(links, field: .created, fake).map(\.number) == [400, 200, 1])
    }

    // An item that can't be looked at has no value.
    @Test func anItemThatCantBeReadHasNone() async {
        let fake = FakeFileSystem()
        let service = DirectoryService(fileSystem: fake, cache: ResponseCache(), kinds: KindLabeler(describer: nil))
        #expect(await service.values(of: ["/gone"], field: .modified) == [.number(nil)])
        #expect(ItemValue.text("x").number == nil && ItemValue.number(1).text == nil)
    }
}
