import FTFoundation
import FTTestSupport
import Foundation
import Testing

@Suite struct InfoPanelOpensWithTests {
    private static let dates = DateText(locale: Locale(identifier: "en_US"), timeZone: .gmt)

    private func item(_ kind: EntryKind) -> InfoItem {
        InfoItem(
            path: "/Users/demo/a", name: "a", fileExtension: "", kind: kind, kindLabel: "Thing", isHidden: false,
            isSymlink: false, createdAt: ISODateForTests.date("2026-03-01T09:00:00.000Z"),
            modifiedAt: ISODateForTests.date("2026-03-02T10:30:00.000Z"),
            sizeBytes: 2000, sizeStatus: .ready, permissionMode: 0o644)
    }

    private func rows(_ kind: EntryKind, _ opens: InfoPanelModel.OpensWithState) -> [InfoRow] {
        InfoPanelModel.itemContent(
            item: item(kind), pending: false, volume: nil, isVolumeRoot: false, hasFolderSize: false, folderSize: nil,
            opensWith: opens, dates: Self.dates
        ).rows
    }

    // A file keeps the row, muted with a dash, with the rows below where the answer will leave them.
    @Test func aFileKeepsTheRowUntilMacOSAnswers() throws {
        let pending = rows(.file, .pending)
        let available = rows(.file, .available)
        #expect(pending.map(\.label) == available.map(\.label))
        let row = try #require(pending.first { $0.label == "Opens with" })
        #expect(row.value == .text("—"))
        #expect(row.muted)
        #expect(!rows(.file, .hidden).contains { $0.label == "Opens with" })
    }

    // A folder has no such row, waiting or not.
    @Test func aFolderNeverHasTheRow() {
        for opens in [InfoPanelModel.OpensWithState.pending, .available, .hidden] {
            #expect(!rows(.directory, opens).contains { $0.label == "Opens with" })
        }
    }
}
