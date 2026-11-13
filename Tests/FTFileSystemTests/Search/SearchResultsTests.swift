import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private func result(_ path: String, kind: FTFileSystem.EntryKind = .file) -> SearchResultItem {
    let name = String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    let slash = path.lastIndex(of: "/")
    let parent = slash.map { String(path[..<$0]) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
    let ext = name.contains(".") ? String(name.split(separator: ".", omittingEmptySubsequences: false).last ?? "") : ""
    return SearchResultItem(
        path: path, name: name, fileExtension: ext, kind: kind, isHidden: name.hasPrefix("."), isSymlink: false,
        parentPath: parent, relativeParentPath: parent)
}

@Suite struct SearchResultsOrderingTests {
    @Test func appendsIncrementalBatchesWithoutReorderingTheExistingList() {
        let current = [result("/Users/demo/project/z-dir/alpha.ts"), result("/Users/demo/project/a-dir/zeta.ts")]
        let next = [result("/Users/demo/project/b-dir/beta.ts"), result("/Users/demo/project/a-dir/gamma.ts")]
        #expect(
            SearchResults.append(current, next).map(\.path) == [
                "/Users/demo/project/z-dir/alpha.ts", "/Users/demo/project/a-dir/zeta.ts",
                "/Users/demo/project/b-dir/beta.ts", "/Users/demo/project/a-dir/gamma.ts",
            ])
        #expect(SearchResults.append(current, []) == current)
    }

    @Test func sortsByPathWhenRequested() {
        let items = [result("/Users/demo/project/z-dir/alpha.ts"), result("/Users/demo/project/a-dir/zeta.ts")]
        #expect(
            SearchResults.sort(items, by: .path, direction: .asc).map(\.path) == [
                "/Users/demo/project/a-dir/zeta.ts", "/Users/demo/project/z-dir/alpha.ts",
            ])
    }

    @Test func sortsByNameInDescendingOrderWhenRequested() {
        let items = [
            result("/Users/demo/project/z-dir/alpha.ts"), result("/Users/demo/project/a-dir/zeta.ts"),
            result("/Users/demo/project/b-dir/beta.ts"),
        ]
        #expect(
            SearchResults.sort(items, by: .name, direction: .desc).map(\.name) == ["zeta.ts", "beta.ts", "alpha.ts"])
    }

    @Test func putsFoldersFirstThenFilesByExtensionThoseWithoutOneLast() {
        let items = [
            result("/Users/demo/project/b.ts"), result("/Users/demo/project/Makefile"),
            result("/Users/demo/project/a.md"),
            result("/Users/demo/project/zeta", kind: .directory), result("/Users/demo/project/a.ts"),
        ]
        #expect(
            SearchResults.sort(items, by: .kind, direction: .asc).map(\.name) == [
                "zeta", "a.md", "a.ts", "b.ts", "Makefile",
            ])
        #expect(
            SearchResults.sort(items, by: .kind, direction: .desc).map(\.name) == [
                "Makefile", "b.ts", "a.ts", "a.md", "zeta",
            ])
    }

    @Test func putsNumbersInNamesInOrderOfValueAsAFolderDoes() {
        let items = [result("/p/file10.txt"), result("/p/File2.txt"), result("/p/file1.txt")]
        #expect(
            SearchResults.sort(items, by: .name, direction: .asc).map(\.name) == [
                "file1.txt", "File2.txt", "file10.txt",
            ])
        #expect(
            SearchResults.sort(items, by: .path, direction: .desc).map(\.name) == [
                "file10.txt", "File2.txt", "file1.txt",
            ])
        let merged = SearchResults.merge(
            [result("/p/file1.txt"), result("/p/file10.txt")], [result("/p/file2.txt")], by: .name, direction: .asc)
        #expect(merged.map(\.name) == ["file1.txt", "file2.txt", "file10.txt"])
    }

    @Test func sortsNamesInTheAlphabetOfTheLanguage() {
        let items = [result("/p/öga"), result("/p/zebra"), result("/p/åsna"), result("/p/apa")]
        let swedish = NameOrder(localeIdentifier: "sv_SE")
        #expect(
            SearchResults.sort(items, by: .name, direction: .asc, order: swedish).map(\.name) == [
                "apa", "zebra", "åsna", "öga",
            ])
        #expect(
            SearchResults.sort(items, by: .name, direction: .asc, order: NameOrder(localeIdentifier: "en_US"))
                .map(\.name) == ["apa", "åsna", "öga", "zebra"])
        let merged = SearchResults.merge(
            [result("/p/apa"), result("/p/zebra")], [result("/p/åsna")], by: .name, direction: .asc, order: swedish)
        #expect(merged.map(\.name) == ["apa", "zebra", "åsna"])
    }

    @Test func ordersItemsTheLanguageHoldsEqualByTheirText() {
        let lower = result("/a/x.ts")
        let upper = result("/a/X.ts")
        // Same name and path ignoring case: byte by byte, "X" comes first, whatever order they arrive in; a descending
        // sort reverses it with the rest.
        for sortBy: SearchResultsSortByPreference in [.name, .path, .kind] {
            #expect(SearchResults.sort([lower, upper], by: sortBy, direction: .asc) == [upper, lower])
            #expect(SearchResults.sort([upper, lower], by: sortBy, direction: .asc) == [upper, lower])
            #expect(SearchResults.sort([upper, lower], by: sortBy, direction: .desc) == [lower, upper])
        }
    }
}

@Suite struct SearchResultsHelperTests {
    private func match(
        _ query: String, _ mode: SearchPatternModePreference, _ scope: SearchMatchScopePreference, in text: String
    )
        -> String??
    {
        guard let pattern = SearchResults.highlightPattern(query: query, patternMode: mode, matchScope: scope) else {
            return .none
        }
        let range = pattern.firstMatch(in: text)
        return .some(range.map { String(text[Range($0, in: text)!]) })
    }

    @Test func marksTheMatchedPartOfNamesForPlainTextAndRegexNameSearches() {
        #expect(match("app", .regex, .name, in: "MyApp.tsx") == .some("App"))
        #expect(match("App", .regex, .name, in: "MyApp.tsx") == .some("App"))
        #expect(match("App", .regex, .name, in: "myapp.tsx") == .some(nil))
        #expect(match("*.ts", .glob, .name, in: "a.ts") == nil)
        #expect(match("src/app", .regex, .path, in: "a") == nil)
        #expect(match("(", .regex, .name, in: "a") == nil)
        // Plain text is found as typed, with the same smart case.
        #expect(match("(1).pdf", .text, .name, in: "report (1).pdf") == .some("(1).pdf"))
        #expect(match("c++", .text, .name, in: "My C++ notes") == .some("C++"))
        #expect(match("C++", .text, .name, in: "my c++ notes") == .some(nil))
        #expect(match("a.c", .text, .name, in: "abc") == .some(nil))
    }

    @Test func saysWhichFolderAResultIsInFromWhereTheSearchStarted() {
        #expect(SearchResults.folderText(path: "/Users/demo/app/src/main.ts", rootPath: "/Users/demo/app") == "src")
        #expect(
            SearchResults.folderText(path: "/Users/demo/app/src/lib/a.ts", rootPath: "/Users/demo/app/") == "src › lib")
        // Right in the folder searched: that folder's name.
        #expect(SearchResults.folderText(path: "/Users/demo/app/README.md", rootPath: "/Users/demo/app") == "app")
        #expect(SearchResults.folderText(path: "/etc/hosts", rootPath: "/") == "etc")
        #expect(SearchResults.folderText(path: "/notes.txt", rootPath: "/") == "Macintosh HD")
        // A renamed startup disk is named as it is called.
        #expect(SearchResults.folderText(path: "/notes.txt", rootPath: "/", startupDiskName: "Data") == "Data")
        #expect(SearchResults.folderText(path: "/etc/hosts", rootPath: "/", startupDiskName: "Data") == "etc")
    }

    @Test func buildsItemsFromFdOutput() {
        let hidden = SearchResults.item(rootPath: "/Users/demo", outputPath: "/Users/demo/.config/.env.Local")
        #expect(hidden.name == ".env.Local")
        #expect(hidden.fileExtension == "local")
        #expect(hidden.isHidden)
        #expect(hidden.relativeParentPath == ".config")
        #expect(SearchResults.extensionOf(".env") == "")
        #expect(SearchResults.extensionOf("a.") == "")
        #expect(SearchResults.extensionOf("..a") == "a")
        #expect(SearchResults.extensionOf("x.TAR.GZ") == "gz")
        let root = SearchResults.item(rootPath: "/", outputPath: "/")
        #expect(root.path == "/")
        #expect(root.kind == .file)
        #expect(SearchResults.relative(from: "/a/b", to: "/a") == "..")
        #expect(SearchResults.relative(from: "/", to: "/x/y") == "x/y")
    }
}

// The order, the folder column and the highlight, against the golden. The order is that of US English, which the
// golden was recorded in.
private struct SortInput: Codable {
    struct Entry: Codable {
        var id: Int
        var path: String
        var name: String
        var `extension`: String
        var kind: FTFileSystem.EntryKind
    }
    struct Folder: Codable {
        var path: String
        var rootPath: String
    }
    struct Highlight: Codable {
        var query: String
        var patternMode: SearchPatternModePreference
        var matchScope: SearchMatchScopePreference
        var texts: [String]
    }
    var items: [Entry]?
    var sortBy: SearchResultsSortByPreference?
    var direction: SortDirectionPreference?
    var folder: Folder?
    var highlight: Highlight?
}

private enum SortOutput: Codable, Equatable {
    case ids([Int])
    case text(String)
    case matches([String?])
    case none

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let ids = try? container.decode([Int].self) {
            self = .ids(ids)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .matches(try container.decode([String?].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ids(let ids): try container.encode(ids)
        case .text(let text): try container.encode(text)
        case .matches(let matches): try container.encode(matches)
        case .none: try container.encodeNil()
        }
    }
}

@Suite struct SearchSortGoldenTests {
    @Test func matchesTheGoldenFileForOrderFolderColumnAndHighlight() throws {
        let cases: [GoldenCase<SortInput, SortOutput>] = try Golden.load(suite: "search-sort")
        #expect(cases.count > 100)
        Golden.expectMatches(cases) { input in
            if let entries = input.items, let sortBy = input.sortBy, let direction = input.direction {
                let items = entries.map {
                    SearchResultItem(
                        path: $0.path, name: $0.name, fileExtension: $0.extension, kind: $0.kind, isHidden: false,
                        parentPath: "", relativeParentPath: "")
                }
                let order = SearchResults.sortedIndexes(
                    items, by: sortBy, direction: direction, order: NameOrder(localeIdentifier: "en_US"))
                return .ids(order.map { entries[$0].id })
            }
            if let folder = input.folder {
                return .text(SearchResults.folderText(path: folder.path, rootPath: folder.rootPath))
            }
            if let highlight = input.highlight,
                let pattern = SearchResults.highlightPattern(
                    query: highlight.query, patternMode: highlight.patternMode, matchScope: highlight.matchScope)
            {
                return .matches(
                    highlight.texts.map { text in
                        pattern.firstMatch(in: text).map {
                            String(text[Range($0, in: text)!])
                        }
                    })
            }
            return .none
        }
    }
}
