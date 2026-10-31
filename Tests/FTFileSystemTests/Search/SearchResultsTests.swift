// Port of apps/desktop/src/renderer/lib/searchResults.test.ts
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
    // T-920069db
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

    // T-4802ec5b
    // B-SRCH-101
    @Test func sortsByPathWhenRequested() {
        let items = [result("/Users/demo/project/z-dir/alpha.ts"), result("/Users/demo/project/a-dir/zeta.ts")]
        #expect(
            SearchResults.sort(items, by: .path, direction: .asc).map(\.path) == [
                "/Users/demo/project/a-dir/zeta.ts", "/Users/demo/project/z-dir/alpha.ts",
            ])
    }

    // T-bc11048e
    // B-SRCH-102
    @Test func sortsByNameInDescendingOrderWhenRequested() {
        let items = [
            result("/Users/demo/project/z-dir/alpha.ts"), result("/Users/demo/project/a-dir/zeta.ts"),
            result("/Users/demo/project/b-dir/beta.ts"),
        ]
        #expect(
            SearchResults.sort(items, by: .name, direction: .desc).map(\.name) == ["zeta.ts", "beta.ts", "alpha.ts"])
    }

    // T-cbadd337
    // B-SRCH-103
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

    @Test func keepsTheOrderOfEqualItems() {
        let first = result("/a/x.ts")
        let second = result("/a/X.ts")
        // Same name, same path ignoring case: the list's own order stands, whichever way it is sorted.
        #expect(SearchResults.sort([first, second], by: .path, direction: .asc) == [first, second])
        #expect(SearchResults.sort([first, second], by: .path, direction: .desc) == [first, second])
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
        return .some(range.map { String(text[Range($0.range, in: text)!]) })
    }

    // T-a2a3a813
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

    // T-7d602a4b
    // T-78d2429c
    @Test func saysWhichFolderAResultIsInFromWhereTheSearchStarted() {
        #expect(SearchResults.folderText(path: "/Users/demo/app/src/main.ts", rootPath: "/Users/demo/app") == "src")
        #expect(
            SearchResults.folderText(path: "/Users/demo/app/src/lib/a.ts", rootPath: "/Users/demo/app/") == "src › lib")
        // Right in the folder searched: that folder's name.
        #expect(SearchResults.folderText(path: "/Users/demo/app/README.md", rootPath: "/Users/demo/app") == "app")
        #expect(SearchResults.folderText(path: "/etc/hosts", rootPath: "/") == "etc")
        #expect(SearchResults.folderText(path: "/notes.txt", rootPath: "/") == "Macintosh HD")
    }

    // T-88a11cc8 T-56a22bbc
    // B-INFO-099 B-INFO-100 B-SRCH-109
    @Test func theSearchStatusLineIsTheFoundationOne() {
        let size = StatusSize.ready(sizeBytes: 3000)
        #expect(
            StatusSummary.search(isSearching: false, shown: 12, totalCount: 12, selectedCount: 2, selectionSize: size)
                == "12 results · 2 selected · 3.0 KB")
        #expect(
            StatusSummary.search(
                isSearching: false, shown: 12, totalCount: 12, selectedCount: 2, selectionSize: .calculating)
                == "12 results · 2 selected · Calculating…")
        #expect(
            StatusSummary.search(isSearching: false, shown: 12, totalCount: 12, selectedCount: 2, selectionSize: nil)
                == "12 results · 2 selected")
        #expect(
            StatusSummary.search(isSearching: false, shown: 12, totalCount: 12, selectedCount: 0, selectionSize: size)
                == "12 results")
    }

    // B-SRCH-113 B-SRCH-174 B-SRCH-176
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

// The order, the folder column and the highlight, against the reference. The order is the machine's locale's, so the
// golden is machine-local.
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
    // F-071
    // B-SRCH-101 B-SRCH-102 B-SRCH-103
    @Test func matchesTheReferenceForOrderFolderColumnAndHighlight() throws {
        let cases: [GoldenCase<SortInput, SortOutput>] = try Golden.load(suite: "search-sort")
        #expect(cases.count > 100)
        Golden.expectMatches(cases) { input in
            if let entries = input.items, let sortBy = input.sortBy, let direction = input.direction {
                let items = entries.map {
                    SearchResultItem(
                        path: $0.path, name: $0.name, fileExtension: $0.extension, kind: $0.kind, isHidden: false,
                        parentPath: "", relativeParentPath: "")
                }
                let order = SearchResults.sortedIndexes(items, by: sortBy, direction: direction)
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
                            String(text[Range($0.range, in: text)!])
                        }
                    })
            }
            return .none
        }
    }
}
