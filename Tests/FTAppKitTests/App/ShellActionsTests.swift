// Ports the Dock and open-file cases of apps/desktop/src/main/explorerWindowController.test.ts
import AppKit
import FTFileSystem
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ShellActionsTests {
    // T-055e457e F-645 F-606
    @Test func opensAWindowFromTheDockIconOnlyWithNoneOpen() {
        let host = FakeWindowHost()
        ShellActions.activate(hasVisibleWindows: false, shutdownInProgress: false, host: host)
        #expect(host.calls == ["default -"])

        host.list.add(FakeExplorerWindow(id: 1))
        ShellActions.activate(hasVisibleWindows: true, shutdownInProgress: false, host: host)
        #expect(host.calls == ["default -"])
    }

    // T-3803d3ce F-645
    @Test func bringsBackTheWindowInFrontFromTheDockIconWhenEveryWindowIsMinimized() {
        let host = FakeWindowHost()
        host.list.add(FakeExplorerWindow(id: 1))

        ShellActions.activate(hasVisibleWindows: false, shutdownInProgress: false, host: host)

        #expect(host.calls == ["bringToFront"])
    }

    // T-1e0a75b0 F-645
    @Test func opensNoWindowWhileQuitting() {
        let host = FakeWindowHost()
        ShellActions.activate(hasVisibleWindows: false, shutdownInProgress: true, host: host)
        #expect(host.calls.isEmpty)
    }

    // main.ts:332-337 second-instance: the running app brings its window forward, or opens one with none; not while
    // quitting. The announcement goes through the system's distributed notifications.
    @Test func aSecondLaunchBringsAWindowForward() async {
        let host = FakeWindowHost()
        SecondInstance.arrived(shutdownInProgress: true, host: host)
        #expect(host.calls.isEmpty)
        let bundleID = "com.filetrail.tests.\(UUID().uuidString)"
        let observer = SecondInstance.listen(bundleID: bundleID) {
            SecondInstance.arrived(shutdownInProgress: false, host: host)
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        SecondInstance.announce(bundleID: bundleID)
        let deadline = ContinuousClock.now + .seconds(5)
        while host.calls.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.calls == ["bringToFront"])
    }

    // T-fe1d53aa F-606 F-645
    @Test func hasADockMenuWithOneItemNewWindow() {
        let target = NSObject()
        let menu = ShellActions.makeDockMenu(target: target, action: #selector(NSObject.description))
        #expect(titles(menu) == ["New Window"])
        #expect(menu.items.first?.target === target)
    }

    // T-b8d258a3 F-135 F-136
    @Test func givesADiskImageToTheWindowInFront() async {
        let host = FakeWindowHost()
        var mounted: [String] = []

        await ShellActions.openFromOtherApp(
            OpenRequest(path: "/tmp/a.dmg", kind: .diskImage), shutdownInProgress: false, host: host,
            mount: { path in
                mounted.append(path)
                return DiskImageOpenResponse(status: .failed)
            }, showFailure: { _, _ in })

        #expect(host.calls == ["fromOtherApp /tmp/a.dmg"])
        #expect(mounted.isEmpty)
    }

    // T-2955ff8c T-e6a2360a F-136
    @Test func mountsADiskImageWithNoWindowToTakeItAndOpensAWindowOnItsDisk() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false

        await ShellActions.openFromOtherApp(
            OpenRequest(path: "/tmp/a.dmg", kind: .diskImage), shutdownInProgress: false, host: host,
            mount: { _ in DiskImageOpenResponse(status: .opened, volumePath: "/Volumes/A") }, showFailure: { _, _ in })

        #expect(host.calls == ["fromOtherApp /tmp/a.dmg", "onFolder /Volumes/A"])
    }

    // F-136: a failure is shown on its own, with no window to show it in
    @Test func showsAFailureOnItsOwn() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false
        var shown: [String] = []

        await ShellActions.openFromOtherApp(
            OpenRequest(path: "/tmp/a.dmg", kind: .diskImage), shutdownInProgress: false, host: host,
            mount: { _ in DiskImageOpenResponse(status: .failed, reason: "no luck") },
            showFailure: { title, message in shown.append("\(title) | \(message)") })

        #expect(shown.count == 1)
        #expect(host.calls == ["fromOtherApp /tmp/a.dmg"])
    }

    // T-d27361b6 F-135
    @Test func opensNothingWhileQuitting() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false
        var mounted = 0

        await ShellActions.openFromOtherApp(
            OpenRequest(path: "/tmp/a.dmg", kind: .diskImage), shutdownInProgress: true, host: host,
            mount: { _ in
                mounted += 1
                return DiskImageOpenResponse(status: .busy)
            }, showFailure: { _, _ in })

        #expect(host.calls.isEmpty)
        #expect(mounted == 0)
    }

    // T-bb5cec67 F-135 F-631: with no window to take them, a folder opens in a window of its own, and another item's folder
    // too, with the item selected
    @Test func opensAWindowOnAFolderOrAnItemsFolderWithNoWindowToTakeThem() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false
        var mounted = 0
        for request in [
            OpenRequest(path: "/Users/me/Documents", kind: .folder),
            OpenRequest(path: "/Users/me/Notes/todo.txt", kind: .reveal),
        ] {
            await ShellActions.openFromOtherApp(
                request, shutdownInProgress: false, host: host,
                mount: { _ in
                    mounted += 1
                    return DiskImageOpenResponse(status: .failed)
                }, showFailure: { _, _ in })
        }

        #expect(
            host.calls == [
                "fromOtherApp /Users/me/Documents", "onFolder /Users/me/Documents",
                "fromOtherApp /Users/me/Notes/todo.txt", "onFolder /Users/me/Notes selecting /Users/me/Notes/todo.txt",
            ])
        #expect(mounted == 0)
    }

    // F-135 F-631: items wait until the windows exist, and one that isn't there is left out
    // B-NAV-231 T-aa290e2d
    @Test func queuesItemsUntilTheWindowsExistAndLeavesOutOnesThatAreNotThere() {
        var opened: [String] = []
        let entry = OpenFileEntryPoint(
            describe: { path in
                LaunchContext.describeOpenedPath(path) { $0 == "/tmp/gone" ? nil : $0 == "/Users/me/Documents" }
            }, open: { opened.append($0.path) })

        let claimed = entry.open(["/tmp/a.dmg", "/Users/me/Documents", "/tmp/notes.txt", "/tmp/gone"])
        #expect(claimed.map(\.kind) == [.diskImage, .folder, .reveal])
        #expect(opened.isEmpty)
        entry.startupWindowsOpened()
        #expect(opened == ["/tmp/a.dmg", "/Users/me/Documents", "/tmp/notes.txt"])
        _ = entry.open(["/tmp/b.iso"])
        #expect(opened == ["/tmp/a.dmg", "/Users/me/Documents", "/tmp/notes.txt", "/tmp/b.iso"])
    }
}
