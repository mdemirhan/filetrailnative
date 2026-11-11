// The startup disk called by the name the app read, on a tab in a window that is never shown, and a rename reaching
// what the tab shows
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct StartupDiskNameTests {
        // The tab, its window and toolbar titles, the path bar and the sidebar's Locations call `/` by the name read,
        // and by the new one once the disk is renamed.
        @Test func aTabCallsTheStartupDiskByItsName() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let disk = StartupDisk()
            var services = harness.services
            services.startupDisk = disk
            tab.servicesOverride = services
            disk.set("Data")
            let bar = tab.content.contentShell.pathBarRow
            #expect(bar.pathBar.segments.first?.label == "Data")
            func locationLabel() -> String? {
                tab.sidebarController.model.locations.first { $0.path == "/" }?.label
            }
            #expect(locationLabel() == "Data")

            tab.go(to: URL(fileURLWithPath: "/"))
            #expect(await waitUntil { tab.shownFolderPath == "/" && tab.loaded })
            #expect(tab.window?.title == "Data")
            #expect(tab.window?.tab.title == "Data")
            #expect(ExplorerToolbar.title(of: tab) == "Data")
            #expect(bar.pathBar.segments.map(\.label) == ["Data"])

            disk.set("Other")
            #expect(tab.window?.title == "Other")
            #expect(tab.window?.tab.title == "Other")
            #expect(bar.pathBar.segments.map(\.label) == ["Other"])
            #expect(locationLabel() == "Other")
            await harness.close()
        }
    }
}

/// The name of `/` is read from the disk, and a change of it is told.
@MainActor
struct StartupDiskTests {
    @Test func theNameIsWhatFinderShows() async {
        let name = await StartupDisk.readName()
        #expect(name == FileManager.default.displayName(atPath: "/"))
    }

    @Test func aNewNameIsKeptAndTold() {
        let disk = StartupDisk()
        #expect(disk.name == "Macintosh HD")
        let told = Told()
        let observer = NotificationCenter.default.addObserver(
            forName: StartupDisk.nameChanged, object: disk, queue: nil
        ) { _ in MainActor.assumeIsolated { told.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        disk.set("Data")
        #expect(disk.name == "Data")
        #expect(told.count == 1)
        // The same name, or none, changes nothing.
        disk.set("Data")
        disk.set(nil)
        disk.set("")
        #expect(disk.name == "Data")
        #expect(told.count == 1)
    }

    @MainActor
    private final class Told {
        var count = 0
    }
}
