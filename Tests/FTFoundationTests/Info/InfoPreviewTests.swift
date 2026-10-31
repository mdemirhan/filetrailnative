// Port of apps/desktop/src/renderer/lib/infoPreview.test.ts
import Testing

@testable import FTFoundation

@Suite("infoPreview")
struct InfoPreviewTests {
    static let entry = InfoEntry(path: "/Users/demo/notes.txt", name: "notes.txt", fileExtension: "txt", kind: .file)
    static let metadata = InfoMetadata(
        kindLabel: "Plain Text Document", createdAt: nil, modifiedAt: "2026-03-02T10:30:00.000Z", sizeBytes: 12,
        sizeStatus: .ready, permissionMode: 0o644)
    static let properties = InfoItem(
        path: entry.path, name: "notes.txt", fileExtension: "txt", kind: .file, kindLabel: "Plain Text Document",
        createdAt: "2026-03-01T09:00:00.000Z", modifiedAt: "2026-03-02T10:30:00.000Z", sizeBytes: 12,
        sizeStatus: .ready,
        permissionMode: 0o644)

    // T-1a0ba4b2
    // B-INFO-004
    @Test func usesTheItemsPropertiesOnceTheyMatchTheTarget() {
        let resolved = InfoPreview.resolve(
            path: Self.entry.path, currentPath: "/Users/demo", entries: [Self.entry], metadataByPath: [:],
            properties: Self.properties)
        #expect(resolved == InfoPreview.Resolved(item: Self.properties, pending: false))
    }

    // T-f59e299b
    // B-INFO-003 B-INFO-004
    @Test func previewsAListedItemFromTheListingWhileItsPropertiesLoad() throws {
        var stale = Self.properties
        stale.path = "/Users/demo/other.txt"
        let resolved = try #require(
            InfoPreview.resolve(
                path: Self.entry.path, currentPath: "/Users/demo", entries: [Self.entry],
                metadataByPath: [Self.entry.path: Self.metadata], properties: stale))
        #expect(resolved.pending)
        #expect(resolved.item.name == "notes.txt")
        #expect(resolved.item.kindLabel == "Plain Text Document")
        #expect(resolved.item.sizeBytes == 12)
        #expect(resolved.item.permissionMode == 0o644)
        #expect(resolved.item.createdAt == nil)
    }

    // T-19c2787c
    // B-INFO-003 B-INFO-007 B-INFO-195
    @Test func previewsTheFolderOnScreenWhenNothingIsSelected() throws {
        let resolved = try #require(
            InfoPreview.resolve(
                path: "/Users/demo/Projects", currentPath: "/Users/demo/Projects", entries: [], metadataByPath: [:],
                properties: nil))
        #expect(resolved.item.name == "Projects")
        #expect(resolved.item.kind == .directory)
        #expect(resolved.item.kindLabel == "Folder")
        #expect(resolved.item.sizeStatus == .deferred)
    }

    // T-c1ae5c70
    // B-INFO-005
    @Test func hasNothingToShowForAnUnknownPath() {
        #expect(
            InfoPreview.resolve(
                path: "/elsewhere/file", currentPath: "/Users/demo", entries: [], metadataByPath: [:], properties: nil)
                == nil)
        #expect(
            InfoPreview.resolve(path: nil, currentPath: "/x", entries: [], metadataByPath: [:], properties: nil) == nil)
    }

    // T-714e79e7
    // B-INFO-007
    @Test func labelsKindsBeforeTheSystemsDescriptionIsKnown() {
        #expect(InfoPreview.fallbackKindLabel(kind: .bundle, fileExtension: "app") == "Application")
        #expect(InfoPreview.fallbackKindLabel(kind: .bundle, fileExtension: "key") == "Package")
        #expect(InfoPreview.fallbackKindLabel(kind: .file, fileExtension: "md") == "MD File")
        #expect(InfoPreview.fallbackKindLabel(kind: .file, fileExtension: "") == "File")
        #expect(InfoPreview.fallbackKindLabel(kind: .symlinkDirectory, fileExtension: "") == "Alias Folder")
        #expect(InfoPreview.fallbackKindLabel(kind: .symlinkFile, fileExtension: "") == "Alias")
    }

    @Test func theRootFolderIsMacintoshHD() {
        #expect(InfoPreview.folderEntry("/").name == "Macintosh HD")
    }
}
