import FTTestSupport
import Foundation
import Testing

// Port of packages/core/src/fs/explorerService.test.ts
@testable import FTFileSystem

struct ExplorerServiceTests {
    private func service(_ fileSystem: FakeFileSystem, describer: KindLabeler.Describer? = nil) -> DirectoryService {
        DirectoryService(fileSystem: fileSystem, cache: ResponseCache(), kinds: KindLabeler(describer: describer))
    }

    /// A fake whose `stat` says `workspace` is a folder and everything else is what `others` makes of it.
    private func workspace(
        _ records: [DirectoryRecord], stat: @escaping @Sendable (String) throws -> FileStats,
        lstat: @escaping @Sendable (String) throws -> FileStats = { _ in
            fakeStats(directory: false, file: true, size: 12)
        }
    ) -> FakeFileSystem {
        let fake = FakeFileSystem()
        fake.directory = { _ in records }
        fake.statHandler = stat
        fake.lstatHandler = lstat
        return fake
    }

    // T-7ec6b6b8 F-064 F-065 F-139 F-166 F-174
    @Test func sortsFoldersBeforeFilesAndHidesDotfilesByDefault() async throws {
        let fake = workspace(
            [
                fakeDirent("zeta.txt", file: true), fakeDirent(".secrets", directory: true),
                fakeDirent("Alpha", directory: true), fakeDirent("beta", file: true),
            ],
            stat: { path in
                fakeStats(
                    directory: path == "/workspace" || path.hasSuffix("Alpha"),
                    file: path.hasSuffix("beta") || path.hasSuffix("zeta.txt"), size: 12)
            })
        let service = service(fake)
        let snapshot = try await service.snapshot(path: "/workspace")
        #expect(snapshot.entries.map(\.name) == ["Alpha", "beta", "zeta.txt"])
        let tree = try await service.treeChildren(path: "/workspace")
        #expect(tree.children.map(\.name) == ["Alpha"])
    }

    // T-c0e9bbe1 F-170 F-171
    @Test func saysWhetherAFileWithoutAnExtensionIsExecutableAndLooksAtNoOtherEntry() async throws {
        let fake = workspace(
            [
                fakeDirent("folder", directory: true), fakeDirent("notes.txt", file: true),
                fakeDirent("Makefile", file: true), fakeDirent(".profile", file: true), fakeDirent("run", file: true),
            ],
            stat: { path in
                if path == "/workspace" { return fakeStats(directory: true, file: false, size: 0) }
                var stats = fakeStats(directory: false, file: true, size: 4)
                stats.mode = path.hasSuffix("run") ? 0o755 : 0o644
                return stats
            })
        let snapshot = try await service(fake).snapshot(path: "/workspace", includeHidden: true)
        let flags = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0.isExecutable) })
        #expect(flags["folder"] == .some(nil))
        #expect(flags["notes.txt"] == .some(nil))
        #expect(flags["Makefile"] == false)
        #expect(flags[".profile"] == false)
        #expect(flags["run"] == true)
        let looked = fake.lookedUp.map { String($0.split(separator: "/").last ?? "") }
        #expect(!looked.contains("notes.txt"))
        #expect(!looked.contains("folder"))
    }

    // T-a5c355cb F-140 F-173
    @Test func readsRealFileProperties() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.path + "/notes.txt"
            try "hello world".write(toFile: path, atomically: true, encoding: .utf8)
            let service = DirectoryService(kinds: KindLabeler(describer: nil))
            let item = await service.itemProperties(path: path)
            #expect(item.kind == .file)
            #expect(item.sizeBytes == 11)
            #expect(item.kindLabel == "TXT File")
            #expect(item.permissionMode != nil)
        }
    }

    // T-8ae57f6a F-169 F-173
    @Test func readsThePropertiesOfTheRootFolderNamedMacintoshHD() async {
        let item = await DirectoryService().itemProperties(path: "/")
        #expect(item.path == "/")
        #expect(item.name == "Macintosh HD")
        #expect(item.kind == .directory)
        #expect(item.createdAt != nil)
        #expect(item.modifiedAt != nil)
        #expect(item.permissionMode != nil)
    }

    // T-ad4406bb F-158
    @Test func namesKindsAsTheSystemDoesAskingOncePerExtension() async throws {
        try await withTemporaryDirectory { directory in
            for name in ["a.md", "b.md", "c.xyz"] {
                try "x".write(toFile: directory.path + "/" + name, atomically: true, encoding: .utf8)
            }
            let calls = CallCounter()
            let service = DirectoryService(
                kinds: KindLabeler(describer: { path in
                    calls.add()
                    return path.hasSuffix(".md") ? "Markdown Document" : nil
                }))
            var kinds: [String] = []
            for name in ["a.md", "b.md", "c.xyz"] {
                kinds.append(await service.itemProperties(path: directory.path + "/" + name).kindLabel)
            }
            // A kind the system doesn't know keeps the short form.
            #expect(kinds == ["Markdown Document", "Markdown Document", "XYZ File"])
            #expect(calls.count == 2)
        }
    }

    // T-271cbd94 F-064
    @Test func sortsFilesByModifiedTime() async throws {
        let fake = workspace(
            [fakeDirent("newer.txt", file: true), fakeDirent("older.txt", file: true)],
            stat: { path in
                if path == "/workspace" { return fakeStats(directory: true, file: false, size: 0) }
                return fakeStats(
                    directory: false, file: true, size: 5,
                    mtimeMs: path.hasSuffix("newer.txt") ? 1_706_832_000_000 : 1_704_067_200_000)
            })
        let snapshot = try await service(fake).snapshot(
            path: "/workspace", sortBy: .modified, sortDirection: .descending)
        #expect(snapshot.entries.map(\.name) == ["newer.txt", "older.txt"])
    }

    // T-59fe90f1 F-065
    @Test func sortsByKindLabelAndKeepsFoldersAheadOfFiles() async throws {
        let fake = workspace(
            [
                fakeDirent("archive.zip", file: true), fakeDirent("Folder", directory: true),
                fakeDirent("script.ts", file: true),
            ],
            stat: { path in
                fakeStats(
                    directory: path == "/workspace" || path.hasSuffix("Folder"),
                    file: path != "/workspace" && !path.hasSuffix("Folder"), size: 12)
            })
        let snapshot = try await service(fake).snapshot(path: "/workspace", sortBy: .kind)
        #expect(snapshot.entries.map(\.name) == ["Folder", "script.ts", "archive.zip"])
    }

    // T-b81f5543 F-064 F-171
    @Test func sortsBySizeDescendingForFiles() async throws {
        let fake = workspace(
            [fakeDirent("small.txt", file: true), fakeDirent("large.txt", file: true)],
            stat: { path in
                fakeStats(
                    directory: path == "/workspace", file: path != "/workspace",
                    size: path.hasSuffix("large.txt") ? 100 : 10)
            })
        let snapshot = try await service(fake).snapshot(path: "/workspace", sortBy: .size, sortDirection: .descending)
        #expect(snapshot.entries.map(\.name) == ["large.txt", "small.txt"])
    }

    // T-57e20151 F-172
    @Test func sortsALinkToAFolderByTheSizeOfTheLinkItself() async throws {
        let fake = workspace(
            [
                fakeDirent("Alias", symbolicLink: true), fakeDirent("Folder", directory: true),
                fakeDirent("note.txt", file: true),
            ],
            stat: { path in
                fakeStats(
                    directory: !path.hasSuffix(".txt"), file: path.hasSuffix(".txt"),
                    size: path.hasSuffix(".txt") ? 40 : 96)
            },
            lstat: { path in
                path.hasSuffix("Alias")
                    ? fakeStats(directory: false, file: false, size: 16, symbolicLink: true)
                    : fakeStats(directory: false, file: true, size: 40)
            })
        let snapshot = try await service(fake).snapshot(
            path: "/workspace", sortBy: .size, sortDirection: .descending, foldersFirst: false)
        #expect(snapshot.entries.map(\.name) == ["note.txt", "Alias", "Folder"])
        #expect(snapshot.entries.map(\.kind) == [.file, .symlinkDirectory, .directory])
        #expect(snapshot.entries.map(\.sizeBytes) == [40, 16, nil])
    }

    // T-db410023 F-064 F-171
    @Test func reportsFileSizesAndKeepsItemsWithoutASizeLastWhenSortingBySize() async throws {
        let fake = workspace(
            [
                fakeDirent("Folder", directory: true), fakeDirent("small.txt", file: true),
                fakeDirent("large.txt", file: true),
            ],
            stat: { path in
                fakeStats(
                    directory: path == "/workspace" || path.hasSuffix("Folder"), file: path.hasSuffix(".txt"),
                    size: path.hasSuffix("large.txt") ? 100 : 10)
            })
        let service = service(fake)
        let ascending = try await service.snapshot(
            path: "/workspace", sortBy: .size, sortDirection: .ascending, foldersFirst: false)
        #expect(ascending.entries.map(\.name) == ["small.txt", "large.txt", "Folder"])
        #expect(ascending.entries.map(\.sizeBytes) == [10, 100, nil])
        let descending = try await service.snapshot(
            path: "/workspace", sortBy: .size, sortDirection: .descending, foldersFirst: false)
        #expect(descending.entries.map(\.name) == ["large.txt", "small.txt", "Folder"])
        #expect(descending.entries.map(\.sizeBytes) == [100, 10, nil])
        // Sorted by name, no size is given.
        let byName = try await service.snapshot(path: "/workspace")
        #expect(byName.entries.allSatisfy { $0.sizeBytes == nil })
    }

    // T-c73d0ed0 F-064
    @Test func combinesFoldersAndFilesWhenFoldersFirstIsOff() async throws {
        let fake = workspace(
            [fakeDirent("zeta", directory: true), fakeDirent("alpha.txt", file: true)],
            stat: { path in
                fakeStats(
                    directory: path == "/workspace" || path.hasSuffix("zeta"), file: path.hasSuffix("alpha.txt"),
                    size: 12)
            })
        let snapshot = try await service(fake).snapshot(path: "/workspace", foldersFirst: false)
        #expect(snapshot.entries.map(\.name) == ["alpha.txt", "zeta"])
    }

    // T-6fad73c0 F-167 F-168 F-174
    @Test func includesSymlinkedDirectoriesInTreeChildrenAndMarksThemAsAliases() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in [fakeDirent("Alias", symbolicLink: true)] }
        fake.statHandler = { _ in fakeStats(directory: true, file: false, size: 0) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: false, size: 0, symbolicLink: true) }
        let tree = try await service(fake).treeChildren(path: "/workspace", includeHidden: true)
        #expect(
            tree.children == [
                TreeChild(
                    path: "/workspace/Alias", name: "Alias", kind: .symlinkDirectory, isHidden: false, isSymlink: true)
            ])
    }

    // T-a3b4b5e6 F-167
    @Test func keepsDanglingSymlinksInSortedSnapshotsWithoutFailingNavigation() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in [fakeDirent("dangling", symbolicLink: true), fakeDirent("notes.txt", file: true)] }
        fake.statHandler = { path in
            if path == "/workspace" { return fakeStats(directory: true, file: false, size: 0) }
            if path.hasSuffix("notes.txt") {
                return fakeStats(directory: false, file: true, size: 12, mtimeMs: 1_706_745_600_000)
            }
            throw FakeError()
        }
        fake.lstatHandler = { path in
            path.hasSuffix("dangling")
                ? fakeStats(directory: false, file: false, size: 7, symbolicLink: true, mtimeMs: 1_704_067_200_000)
                : fakeStats(directory: false, file: true, size: 12, mtimeMs: 1_706_745_600_000)
        }
        let service = service(fake)
        let modified = try await service.snapshot(
            path: "/workspace", includeHidden: true, sortBy: .modified, foldersFirst: false)
        let size = try await service.snapshot(
            path: "/workspace", includeHidden: true, sortBy: .size, foldersFirst: false)
        #expect(
            modified.entries.map { [$0.name, $0.kind.rawValue] } == [["dangling", "other"], ["notes.txt", "file"]])
        #expect(size.entries.map { [$0.name, $0.kind.rawValue] } == [["notes.txt", "file"], ["dangling", "other"]])
    }

    // T-6da49ddf F-172
    @Test func rejectsMetadataRequestsForPathsOutsideTheRequestedDirectory() async {
        let fake = FakeFileSystem()
        fake.statHandler = { _ in fakeStats(directory: true, file: false, size: 0) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: true, size: 12) }
        await #expect(throws: ExplorerError.outsideDirectory(path: "/other/file.txt", directory: "/workspace")) {
            try await service(fake).metadata(directoryPath: "/workspace", paths: ["/other/file.txt"])
        }
    }

    private func suggestionFileSystem(_ tree: [String: [String]]) -> FakeFileSystem {
        var directories: Set<String> = ["/"]
        for (path, names) in tree {
            directories.insert(path)
            for name in names { directories.insert(path == "/" ? "/" + name : path + "/" + name) }
        }
        let known = directories
        let fake = FakeFileSystem()
        fake.directory = { path in (tree[path] ?? []).map { fakeDirent($0, directory: true) } }
        fake.statHandler = { path in fakeStats(directory: known.contains(path), file: false, size: 0) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: false, size: 0) }
        return fake
    }

    // T-2ca64a85 F-175
    @Test func returnsDirectoryPathSuggestionsForTheActiveParentFolder() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in
            [
                fakeDirent("Documents", directory: true), fakeDirent("Downloads", directory: true),
                fakeDirent(".dotfiles", directory: true), fakeDirent("notes.txt", file: true),
            ]
        }
        fake.statHandler = { path in fakeStats(directory: path == "/Users/demo", file: path != "/Users/demo", size: 0) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: true, size: 0) }
        let response = try await service(fake).pathSuggestions(inputPath: "/Users/demo/Do")
        #expect(response.basePath == "/Users/demo")
        #expect(response.suggestions.map(\.path) == ["/Users/demo/Documents", "/Users/demo/Downloads"])
    }

    // T-ac631da9
    @Test func returnsAllImmediateChildDirectoriesForAnExistingTrailingSlashPath() async throws {
        let fake = suggestionFileSystem(["/Users/demo": ["Applications", "Desktop", "Pictures"]])
        let response = try await service(fake).pathSuggestions(inputPath: "/Users/demo/")
        #expect(response.basePath == "/Users/demo")
        #expect(
            response.suggestions.map(\.path) == [
                "/Users/demo/Applications", "/Users/demo/Desktop", "/Users/demo/Pictures",
            ])
    }

    // T-b2c5d677
    @Test func returnsAnExactDirectorySuggestionWhenTheFullPathExistsWithoutATrailingSlash() async throws {
        let fake = suggestionFileSystem([
            "/Users/demo": ["Desktop", "Pictures"],
            "/Users/demo/Pictures": ["Photos Library.photoslibrary", "Screenshots"],
        ])
        let response = try await service(fake).pathSuggestions(
            inputPath: "/Users/demo/Pictures/Photos Library.photoslibrary")
        #expect(response.basePath == "/Users/demo/Pictures")
        #expect(response.suggestions.map(\.path) == ["/Users/demo/Pictures/Photos Library.photoslibrary"])
    }

    // T-ec627d21
    @Test func filtersAgainstImmediateChildrenOfTheNearestExistingParentWhenTheFinalSegmentIsPartial() async throws {
        let fake = suggestionFileSystem([
            "/Users/demo/src/pythonproj": ["cch", "dux", "lotus123", "OutlookMcp_AppleScript"]
        ])
        let response = try await service(fake).pathSuggestions(inputPath: "/Users/demo/src/pythonproj/lotu")
        #expect(response.basePath == "/Users/demo/src/pythonproj")
        #expect(response.suggestions.map(\.path) == ["/Users/demo/src/pythonproj/lotus123"])
    }

    // T-176ff9e8
    @Test func fallsBackToTheNearestExistingParentInsteadOfABroaderLoadedAncestor() async throws {
        let fake = suggestionFileSystem([
            "/Users/demo": ["Applications", "Desktop", "src"],
            "/Users/demo/src": ["dotnet", "pythonproj", "tsproj"],
        ])
        let response = try await service(fake).pathSuggestions(inputPath: "/Users/demo/src/")
        #expect(response.basePath == "/Users/demo/src")
        #expect(
            response.suggestions.map(\.path) == [
                "/Users/demo/src/dotnet", "/Users/demo/src/pythonproj", "/Users/demo/src/tsproj",
            ])
    }

    // T-1f4a779f
    @Test func filtersHiddenDirectorySuggestionsUnlessHiddenItemsAreEnabled() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in [fakeDirent(".config", directory: true), fakeDirent("Desktop", directory: true)] }
        fake.statHandler = { path in fakeStats(directory: path == "/Users/demo", file: path != "/Users/demo", size: 0) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: true, size: 0) }
        let service = service(fake)
        let hiddenOff = try await service.pathSuggestions(inputPath: "/Users/demo/", includeHidden: false)
        let hiddenOn = try await service.pathSuggestions(inputPath: "/Users/demo/", includeHidden: true)
        #expect(hiddenOff.suggestions.map(\.name) == ["Desktop"])
        #expect(hiddenOn.suggestions.map(\.name) == [".config", "Desktop"])
    }

    // T-7b7245cf
    @Test func usesTheNearestExistingParentForPathSuggestions() async throws {
        let fake = suggestionFileSystem([
            "/Users/demo": ["Documents", "dotfiles"], "/Users/demo/dotfiles": ["scripts", "shell"],
        ])
        let service = service(fake)
        let parentMatches = try await service.pathSuggestions(inputPath: "/Users/demo/dotfiles")
        #expect(parentMatches.basePath == "/Users/demo")
        #expect(parentMatches.suggestions.map(\.path) == ["/Users/demo/dotfiles"])
        let childMatches = try await service.pathSuggestions(inputPath: "/Users/demo/dotfiles/")
        #expect(childMatches.basePath == "/Users/demo/dotfiles")
        #expect(childMatches.suggestions.map(\.path) == ["/Users/demo/dotfiles/scripts", "/Users/demo/dotfiles/shell"])
    }

    // T-da9ba256 F-140
    @Test func resolvesSymlinkTargetsForActivation() async {
        let fake = FakeFileSystem()
        fake.realpathHandler = { _ in "/resolved/path" }
        let resolved = await service(fake).resolvePath("/input/path")
        #expect(resolved == ResolvedPath(inputPath: "/input/path", resolvedPath: "/resolved/path"))
    }

    // T-2158f121 F-140
    @Test func fallsBackToTheResolvedInputPathWhenPathActivationCannotResolveAliases() async {
        let fake = FakeFileSystem()
        fake.realpathHandler = { _ in throw FakeError() }
        let resolved = await service(fake).resolvePath("/input/path")
        #expect(resolved == ResolvedPath(inputPath: "/input/path", resolvedPath: nil))
    }

    // T-4b9e11a6
    @Test func fallsBackToTheOriginalDirectoryPathWhenRealpathNormalizationFails() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in [fakeDirent("Desktop", directory: true)] }
        fake.statHandler = { path in
            fakeStats(directory: path == "/Users/demo" || path.hasSuffix("Desktop"), file: false, size: 0)
        }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: false, size: 0) }
        fake.realpathHandler = { _ in throw FakeError() }
        let snapshot = try await service(fake).snapshot(path: "/Users/demo")
        #expect(snapshot.path == "/Users/demo")
        #expect(snapshot.parentPath == "/Users")
        #expect(snapshot.entries.map(\.path) == ["/Users/demo/Desktop"])
    }

    // T-6d606cea F-173
    @Test func reportsSymlinkDirectoryPropertiesAndDropsInvalidDatesToNull() async {
        let fake = FakeFileSystem()
        fake.statHandler = { _ in fakeStats(directory: true, file: false, size: 0, mtimeMs: nil, birthtimeMs: nil) }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: false, size: 16, symbolicLink: true) }
        let item = await service(fake).itemProperties(path: "/Users/demo/Alias")
        #expect(
            item
                == ItemProperties(
                    path: "/Users/demo/Alias", name: "Alias", fileExtension: "", kind: .symlinkDirectory,
                    kindLabel: "Alias Folder", isHidden: false, isSymlink: true, createdAt: nil, modifiedAt: nil,
                    // The link itself, as measuring the folder it is in counts it.
                    sizeBytes: 16, sizeStatus: .ready, permissionMode: 0o755))
    }

    // T-e76b1aa9
    @Test func returnsUnavailableItemPropertiesForDanglingSymlinks() async {
        let fake = FakeFileSystem()
        fake.statHandler = { _ in throw FakeError() }
        fake.lstatHandler = { _ in
            fakeStats(directory: false, file: false, size: 7, symbolicLink: true, mtimeMs: 1_704_240_000_000)
        }
        let item = await service(fake).itemProperties(path: "/Users/demo/dangling")
        #expect(
            item
                == ItemProperties(
                    path: "/Users/demo/dangling", name: "dangling", fileExtension: "", kind: .other, kindLabel: "Item",
                    isHidden: false, isSymlink: true, createdAt: "2024-01-01T00:00:00.000Z",
                    modifiedAt: "2024-01-03T00:00:00.000Z", sizeBytes: nil, sizeStatus: .unavailable,
                    permissionMode: 0o644))
    }

    // T-6f8fafd9
    @Test func skipsBrokenAndNonDirectorySuggestionEntriesWhileApplyingTheResultLimit() async throws {
        let fake = FakeFileSystem()
        fake.directory = { _ in
            [
                fakeDirent("Desktop", directory: true), fakeDirent("Documents", directory: true),
                fakeDirent("notes.txt", file: true), fakeDirent("Downloads Alias", symbolicLink: true),
            ]
        }
        fake.statHandler = { path in
            if path == "/Users/demo" || path.hasSuffix("Desktop") || path.hasSuffix("Documents") {
                return fakeStats(directory: true, file: false, size: 0)
            }
            if path.hasSuffix("notes.txt") { return fakeStats(directory: false, file: true, size: 0) }
            throw FakeError()
        }
        fake.lstatHandler = { _ in fakeStats(directory: false, file: false, size: 0) }
        let response = try await service(fake).pathSuggestions(inputPath: "/Users/demo/D", limit: 1)
        #expect(response.basePath == "/Users/demo")
        #expect(response.suggestions.map(\.path) == ["/Users/demo/Desktop"])
    }

    // T-808743d3 F-172
    @Test func preservesRequestOrderForMetadataBatchesEvenWhenLstatIsUnavailable() async throws {
        let fake = FakeFileSystem()
        fake.statHandler = { path in
            if path == "/workspace" { return fakeStats(directory: true, file: false, size: 0) }
            return fakeStats(directory: false, file: true, size: path.hasSuffix("beta.txt") ? 4 : 2)
        }
        fake.lstatHandler = { _ in throw FakeError() }
        let response = try await service(fake).metadata(
            directoryPath: "/workspace", paths: ["/workspace/beta.txt", "/workspace/alpha.txt"])
        #expect(response.items.map(\.path) == ["/workspace/beta.txt", "/workspace/alpha.txt"])
        #expect(response.items.map(\.kindLabel) == ["TXT File", "TXT File"])
        #expect(response.items.map(\.sizeBytes) == [4, 2])
        #expect(response.items.map(\.sizeStatus) == [.ready, .ready])
    }

    // T-cb2d45b7 F-172
    @Test func sizesALinkToAFolderAsTheLinkItselfWhileFoldersWaitToBeCalculated() async throws {
        let fake = FakeFileSystem()
        fake.statHandler = { _ in fakeStats(directory: true, file: false, size: 96) }
        fake.lstatHandler = { path in
            path.hasSuffix("Alias")
                ? fakeStats(directory: false, file: false, size: 16, symbolicLink: true)
                : fakeStats(directory: true, file: false, size: 96)
        }
        let response = try await service(fake).metadata(
            directoryPath: "/workspace", paths: ["/workspace/Alias", "/workspace/Folder"])
        #expect(response.items.map(\.kindLabel) == ["Alias Folder", "Folder"])
        #expect(response.items.map(\.sizeBytes) == [16, nil])
        #expect(response.items.map(\.sizeStatus) == [.ready, .deferred])
    }

    // T-3eb178ad
    @Test func returnsUnavailableMetadataForDanglingSymlinksInsteadOfFailingTheBatch() async throws {
        let fake = FakeFileSystem()
        fake.statHandler = { path in
            if path == "/workspace" { return fakeStats(directory: true, file: false, size: 0) }
            if path.hasSuffix("notes.txt") { return fakeStats(directory: false, file: true, size: 12) }
            throw FakeError()
        }
        fake.lstatHandler = { path in
            path.hasSuffix("dangling")
                ? fakeStats(directory: false, file: false, size: 7, symbolicLink: true, mtimeMs: 1_704_240_000_000)
                : fakeStats(directory: false, file: true, size: 12)
        }
        let response = try await service(fake).metadata(
            directoryPath: "/workspace", paths: ["/workspace/dangling", "/workspace/notes.txt"])
        #expect(
            response.items[0]
                == EntryMetadata(
                    path: "/workspace/dangling", kindLabel: "Item", createdAt: "2024-01-01T00:00:00.000Z",
                    modifiedAt: "2024-01-03T00:00:00.000Z", sizeBytes: nil, sizeStatus: .unavailable,
                    permissionMode: 0o644))
        #expect(response.items[1].path == "/workspace/notes.txt")
        #expect(response.items[1].kindLabel == "TXT File")
        #expect(response.items[1].sizeBytes == 12)
        #expect(response.items[1].sizeStatus == .ready)
    }
}

/// How often a closure was called.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func add() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Port of packages/core/src/fs/explorerService.fixtures.test.ts, on the real file system.
struct ExplorerServiceFixtureTests {
    private func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // T-0bd98463
    @Test func listsRealDirectoriesAndDirectorySymlinksInTreeChildren() async throws {
        try await withTemporaryDirectory { directory in
            try makeFolder(directory.path + "/Documents")
            try write("notes", to: directory.path + "/Documents/notes.txt")
            try makeFolder(directory.path + "/.secret")
            try FileManager.default.createSymbolicLink(
                atPath: directory.path + "/Documents Alias", withDestinationPath: "Documents")
            let tree = try await DirectoryService().treeChildren(path: directory.path, includeHidden: false)
            #expect(
                tree.children.map { [$0.name, $0.kind.rawValue] } == [
                    ["Documents", "directory"], ["Documents Alias", "symlink_directory"],
                ])
        }
    }

    // T-0b96632f
    @Test func sortsByFileSizeAndReturnsMetadataForDirectoryEntries() async throws {
        try await withTemporaryDirectory { directory in
            try write("a", to: directory.path + "/alpha")
            try write("bbbb", to: directory.path + "/beta")
            try makeFolder(directory.path + "/Folder")
            let service = DirectoryService()
            let root = try NativeFileSystem().realpath(directory.path)
            let snapshot = try await service.snapshot(path: directory.path, sortBy: .size, sortDirection: .descending)
            #expect(snapshot.entries.map(\.name) == ["Folder", "beta", "alpha"])
            let metadata = try await service.metadata(
                directoryPath: directory.path, paths: [root + "/alpha", root + "/Folder"])
            #expect(metadata.items.map(\.path) == [root + "/alpha", root + "/Folder"])
            #expect(metadata.items.map(\.sizeBytes) == [1, nil])
            #expect(metadata.items.map(\.sizeStatus) == [.ready, .deferred])
            #expect(metadata.items.allSatisfy { $0.permissionMode != nil })
        }
    }

    // T-a8ad2b97
    @Test func readsDeferredFolderPropertiesAndReadyFileProperties() async throws {
        try await withTemporaryDirectory { directory in
            try makeFolder(directory.path + "/Folder")
            try write("hello world", to: directory.path + "/notes.txt")
            let service = DirectoryService()
            let folder = await service.itemProperties(path: directory.path + "/Folder")
            let file = await service.itemProperties(path: directory.path + "/notes.txt")
            #expect(folder.sizeStatus == .deferred)
            #expect(file.sizeStatus == .ready)
            #expect(file.sizeBytes == 11)
        }
    }

    // T-d408f522
    @Test func returnsImmediateChildDirectorySuggestionsForExistingAndPartialPaths() async throws {
        try await withTemporaryDirectory { directory in
            for name in ["lotus123/screenshots", "lotus123/specs", "dux", "tmp"] {
                try makeFolder(directory.path + "/" + name)
            }
            try write("print('hi')", to: directory.path + "/lotus123/main.py")
            let service = DirectoryService()
            let root = try NativeFileSystem().realpath(directory.path)
            let trailingSlash = try await service.pathSuggestions(inputPath: directory.path + "/")
            #expect(trailingSlash.suggestions.map(\.path) == [root + "/dux", root + "/lotus123", root + "/tmp"])
            let partial = try await service.pathSuggestions(inputPath: directory.path + "/lotu")
            #expect(partial.suggestions.map(\.path) == [root + "/lotus123"])
            let nested = try await service.pathSuggestions(inputPath: directory.path + "/lotus123/")
            #expect(nested.suggestions.map(\.path) == [root + "/lotus123/screenshots", root + "/lotus123/specs"])
        }
    }
}
