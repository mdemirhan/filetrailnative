import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
struct InfoSectionFoldsTests {
    // What is folded is written to the preferences at each fold and read from them as the app starts: More folded at
    // first, then as it was left. All of it runs on the main actor without waiting, so no other panel's test sees it.
    @Test func whatIsFoldedIsKeptFromOneLaunchToTheNext() throws {
        let store = try makeStore()
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil }, onPreferencesChanged: { _, _ in })
        let kept = InfoSectionFolds.channel
        InfoSectionFolds.channel = { channel }
        InfoSectionFolds.reset()
        defer {
            InfoSectionFolds.channel = kept
            InfoSectionFolds.reset()
        }
        #expect(InfoSectionFolds.isFolded(.more) && !InfoSectionFolds.isFolded(.dates))
        InfoSectionFolds.toggle(.more)
        InfoSectionFolds.toggle(.permissions)
        InfoSectionFolds.toggle(.dates)
        // In the sections' order.
        #expect(store.preferences().infoFoldedSections == [.dates, .permissions])
        // The next launch.
        InfoSectionFolds.reset()
        #expect(InfoSectionFolds.isFolded(.dates) && InfoSectionFolds.isFolded(.permissions))
        #expect(!InfoSectionFolds.isFolded(.more))
    }
}
