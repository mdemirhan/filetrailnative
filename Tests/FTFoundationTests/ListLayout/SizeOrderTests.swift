// Ports the sortEntriesBySize cases of apps/desktop/src/renderer/lib/explorerAppUtils.test.ts
import Foundation
import Testing

@testable import FTFoundation

struct SizeOrderTests {
    static func entry(_ name: String, folder: Bool = false, bundle: Bool = false, size: Int64? = nil) -> SizeSortKey {
        SizeSortKey(
            path: "/dest/\(name)", name: name, isDirectoryKind: folder, isFolderSizeEligible: folder || bundle,
            listedSize: size)
    }

    static let entries = [
        entry("blob_storage", folder: true), entry("Cache", folder: true), entry("live-status", folder: true),
        entry("Local Storage", folder: true), entry("Pending", folder: true), entry("App.app", bundle: true),
        entry("Preferences", size: 41), entry("codetrail.sqlite", size: 1_400_000_000),
        entry("Trust Tokens-journal", size: 0),
    ]

    static let folderSizes: [String: Int64] = [
        "/dest/blob_storage": 0, "/dest/Cache": 0, "/dest/live-status": 35_000_000, "/dest/Local Storage": 10_000,
        "/dest/App.app": 500,
    ]

    static func names(descending: Bool, foldersFirst: Bool) -> [String] {
        SizeOrder.sorted(
            entries, key: { $0 }, descending: descending, foldersFirst: foldersFirst,
            folderSizeBytes: { folderSizes[$0] }
        ).map(\.name)
    }

    // T-bb1a779b F-828 B-INFO-181
    @Test func foldersAreOrderedByTheirCalculatedSizeWithUnknownSizesLast() {
        #expect(
            Self.names(descending: false, foldersFirst: true) == [
                "blob_storage", "Cache", "Local Storage", "live-status", "Pending", "Trust Tokens-journal",
                "Preferences", "App.app", "codetrail.sqlite",
            ])
    }

    // T-edfcab3f
    @Test func unknownSizesStayLastWhenSortingLargestFirst() {
        #expect(
            Self.names(descending: true, foldersFirst: true) == [
                "live-status", "Local Storage", "Cache", "blob_storage", "Pending", "codetrail.sqlite", "App.app",
                "Preferences", "Trust Tokens-journal",
            ])
    }

    // T-8b3df64d
    @Test func foldersAndFilesMixBySizeWhenFoldersAreNotFirst() {
        #expect(
            Self.names(descending: false, foldersFirst: false) == [
                "blob_storage", "Cache", "Trust Tokens-journal", "Preferences", "App.app", "Local Storage",
                "live-status", "codetrail.sqlite", "Pending",
            ])
    }
}
