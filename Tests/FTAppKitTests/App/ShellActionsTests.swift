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

    // T-fe1d53aa F-606 F-645
    @Test func hasADockMenuWithOneItemNewWindow() {
        let target = NSObject()
        let menu = ShellActions.makeDockMenu(target: target, action: #selector(NSObject.description))
        #expect(titles(menu) == ["New Window"])
        #expect(menu.items.first?.target === target)
    }

    // T-12d3f71a F-135 F-136
    @Test func givesADiskImageToTheWindowInFront() async {
        let host = FakeWindowHost()
        var mounted: [String] = []

        await ShellActions.openDiskImage(
            "/tmp/a.dmg", shutdownInProgress: false, host: host,
            mount: { path in
                mounted.append(path)
                return DiskImageOpenResponse(status: .failed)
            }, showFailure: { _, _ in })

        #expect(host.calls == ["fromOtherApp /tmp/a.dmg"])
        #expect(mounted.isEmpty)
    }

    // T-a6795006 T-55a74b0a F-136
    @Test func mountsADiskImageWithNoWindowToTakeItAndOpensAWindowOnItsDisk() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false

        await ShellActions.openDiskImage(
            "/tmp/a.dmg", shutdownInProgress: false, host: host,
            mount: { _ in DiskImageOpenResponse(status: .opened, volumePath: "/Volumes/A") }, showFailure: { _, _ in })

        #expect(host.calls == ["fromOtherApp /tmp/a.dmg", "onFolder /Volumes/A"])
    }

    // F-136: a failure is shown on its own, with no window to show it in
    @Test func showsAFailureOnItsOwn() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false
        var shown: [String] = []

        await ShellActions.openDiskImage(
            "/tmp/a.dmg", shutdownInProgress: false, host: host,
            mount: { _ in DiskImageOpenResponse(status: .failed, reason: "no luck") },
            showFailure: { title, message in shown.append("\(title) | \(message)") })

        #expect(shown.count == 1)
        #expect(host.calls == ["fromOtherApp /tmp/a.dmg"])
    }

    // T-f65a90ad F-135
    @Test func opensNothingWhileQuitting() async {
        let host = FakeWindowHost()
        host.takesFilesFromOtherApps = false
        var mounted = 0

        await ShellActions.openDiskImage(
            "/tmp/a.dmg", shutdownInProgress: true, host: host,
            mount: { _ in
                mounted += 1
                return DiskImageOpenResponse(status: .busy)
            }, showFailure: { _, _ in })

        #expect(host.calls.isEmpty)
        #expect(mounted == 0)
    }

    // F-135 F-631: only disk images are the app's to open; a folder dropped on the Dock icon does nothing
    @Test func queuesDiskImagesUntilTheWindowsExistAndLeavesOtherFilesAlone() {
        var opened: [String] = []
        let entry = OpenFileEntryPoint { opened.append($0) }

        let claimed = entry.open(["/tmp/a.dmg", "/Users/me/Documents", "/tmp/notes.txt"])
        #expect(claimed == ["/tmp/a.dmg"])
        #expect(opened.isEmpty)
        entry.startupWindowsOpened()
        #expect(opened == ["/tmp/a.dmg"])
        _ = entry.open(["/tmp/b.iso"])
        #expect(opened == ["/tmp/a.dmg", "/tmp/b.iso"])
    }
}
