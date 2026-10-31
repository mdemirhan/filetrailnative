// The volume list's diff of apps/desktop/src/renderer/App.tsx:1218-1236: a listed disk no longer listed took its folders
// with it, whether it was unmounted or renamed, on tabs in windows that are never shown
import AppKit
import FTFileSystem
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct DiskRenamedTests {
        private func disk(_ path: String) -> Volume {
            Volume(
                path: path, name: (path as NSString).lastPathComponent, isLocal: true, isReadOnly: false,
                fileSystem: "apfs", canEject: true, disk: "disk5")
        }

        // A disk renamed from Old to New is gone from where it was: the tab on it closes, the window stays with the
        // other, and Reopen Closed Tab doesn't offer it.
        // B-TREE-177
        @Test func renamingADiskClosesTheTabsOnIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            let alpha = harness.folder.appending("Alpha").path
            group.openTab(path: alpha, from: first)
            #expect(await waitUntil { group.tabs.count == 2 })
            harness.windows.volumeRoot = { $0.hasSuffix("/Alpha") ? "/Volumes/Old" : "/" }
            defer { SidebarVolumes.shared.override = nil }
            SidebarVolumes.shared.override = [disk("/Volumes/Old")]
            #expect(group.tabs.count == 2)
            SidebarVolumes.shared.override = [disk("/Volumes/New")]
            #expect(await waitUntil { group.tabs.count == 1 })
            #expect(group.tabs.first === first)
            #expect(group.session.closedTabs.isEmpty)
            await harness.close()
        }

        // A disk mounted, or the list told again unchanged, takes nothing.
        @Test func aDiskMountedClosesNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            harness.windows.volumeRoot = { _ in "/Volumes/Old" }
            defer { SidebarVolumes.shared.override = nil }
            SidebarVolumes.shared.override = [disk("/Volumes/Old")]
            SidebarVolumes.shared.override = [disk("/Volumes/Old"), disk("/Volumes/New")]
            SidebarVolumes.shared.override = [disk("/Volumes/Old"), disk("/Volumes/New")]
            try await Task.sleep(for: .milliseconds(100))
            #expect(group.tabs.count == 1)
            await harness.close()
        }
    }
}
