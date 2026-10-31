// A disk image opened in the app (useExplorerActions.ts openPathExternally, openDiskImage), by what a double-click does
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct OpeningDiskImagesTests {
        /// The window on a folder with `image.dmg` in it, and what macOS would have been given to open.
        private func openWithImage() async throws -> (ExplorerHarness, MainWindowController, DirectoryEntry, Box) {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("image.dmg"), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            let image = try #require(tab.content.listed.first { $0.name == "image.dmg" })
            let handedToMacOS = Box()
            tab.openFile = { handedToMacOS.urls.append($0) }
            return (harness, tab, image, handedToMacOS)
        }

        private final class Box {
            var urls: [URL] = []
        }

        // T-712b64dd: it mounts, and its disk opens in a new window.
        // B-NAV-231
        @Test func opensItsDiskInANewWindow() async throws {
            let (harness, tab, image, handedToMacOS) = try await openWithImage()
            let volume = harness.folder.appending("Beta").path
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .opened, volumePath: volume)
            }
            let groups = harness.windows.allTabs.count
            tab.open([image])
            #expect(await waitUntil { harness.windows.allTabs.count == groups + 1 })
            #expect(mounted == [image.path])
            #expect(tab.group?.tabs.count == 1)
            #expect(handedToMacOS.urls.isEmpty)
            await harness.close()
        }

        // T-111e25b3: "Open disk images in" a tab.
        // T-aa290e2d
        @Test func opensItsDiskInANewTabWhenSettingsSaySo() async throws {
            let (harness, tab, image, handedToMacOS) = try await openWithImage()
            let volume = harness.folder.appending("Beta").path
            harness.windows.mountDiskImage = { _ in DiskImageOpenResponse(status: .opened, volumePath: volume) }
            harness.channel.update(["diskImageOpensIn": .string("tab")], from: tab.windowID)
            let group = try #require(tab.group)
            tab.open([image])
            #expect(await waitUntil { group.tabs.count == 2 })
            #expect(await waitUntil { group.tabs.last?.shownFolderPath == volume })
            #expect(handedToMacOS.urls.isEmpty)
            await harness.close()
        }

        // T-213e5bdd: the dialog says why.
        @Test func saysWhyItCouldNotBeOpened() async throws {
            let (harness, tab, image, handedToMacOS) = try await openWithImage()
            harness.windows.mountDiskImage = { _ in
                DiskImageOpenResponse(status: .failed, reason: "no mountable file systems")
            }
            tab.open([image])
            #expect(await waitUntil { tab.frontAlert != nil })
            let notice = DiskImageNames.describeFailure(path: image.path, reason: "no mountable file systems")
            #expect(tab.frontAlert?.titleLabel.stringValue == notice.title)
            #expect(handedToMacOS.urls.isEmpty)
            await harness.close()
        }

        // B-NAV-072: a link to an image opens it the same.
        @Test func aLinkToAnImageOpensTheImage() async throws {
            let (harness, tab, _, handedToMacOS) = try await openWithImage()
            try FileManager.default.createSymbolicLink(
                at: harness.folder.appending("Link"), withDestinationURL: harness.folder.appending("image.dmg"))
            harness.services.directoryService.cache.clear()
            tab.refresh()
            #expect(await waitUntil { tab.content.listed.contains { $0.name == "Link" } })
            let link = try #require(tab.content.listed.first { $0.name == "Link" })
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .handedOff)
            }
            tab.open([link])
            #expect(await waitUntil { mounted == [harness.folder.appending("image.dmg").path] })
            #expect(handedToMacOS.urls.isEmpty)
            await harness.close()
        }

        /// Selects `image` and presses Open in the Info panel, with the mouse.
        private func pressOpenInTheInfoPanel(
            _ tab: MainWindowController, _ harness: ExplorerHarness, on image: DirectoryEntry
        ) async throws {
            tab.perform(.viewAsDetails)
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            tab.content.select(paths: [image.path])
            let content = try #require(tab.window?.contentView)
            let group = try #require(findViews("infoPanel.openGroup", in: content).first as? SplitOpenButton)
            #expect(await waitUntil { group.isSplit })
            group.layoutSubtreeIfNeeded()
            let window = try #require(tab.window)
            let point = group.mainPart.convert(
                NSPoint(x: group.mainPart.bounds.midX, y: group.mainPart.bounds.midY), to: nil)
            let root = try #require(window.contentView?.superview)
            let pressed = try #require(root.hitTest(root.convert(point, from: nil)))
            pressed.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: point, in: window)))
            pressed.mouseUp(with: try #require(MouseEvents.event(.leftMouseUp, at: point, in: window)))
        }

        // App.tsx onOpen, `openPathExternally`: the Info panel's Open mounts it, and its disk opens in a new window.
        @Test func theInfoPanelsOpenMountsItAndOpensItsDisk() async throws {
            let (harness, tab, image, handedToMacOS) = try await openWithImage()
            let spy = OpenSpy()
            tab.infoController?.actions.opener = spy.opener
            let volume = harness.folder.appending("Beta").path
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .opened, volumePath: volume)
            }
            let groups = harness.windows.allTabs.count
            try await pressOpenInTheInfoPanel(tab, harness, on: image)
            #expect(await waitUntil { harness.windows.allTabs.count == groups + 1 })
            #expect(mounted == [image.path])
            #expect(tab.group?.tabs.count == 1)
            #expect(spy.all.isEmpty)
            #expect(handedToMacOS.urls.isEmpty)
            await harness.close()
        }

        // "Open disk images in" a tab holds for the Info panel's Open too.
        @Test func theInfoPanelsOpenFollowsTheSetting() async throws {
            let (harness, tab, image, _) = try await openWithImage()
            let volume = harness.folder.appending("Beta").path
            harness.windows.mountDiskImage = { _ in DiskImageOpenResponse(status: .opened, volumePath: volume) }
            harness.channel.update(["diskImageOpensIn": .string("tab")], from: tab.windowID)
            let group = try #require(tab.group)
            try await pressOpenInTheInfoPanel(tab, harness, on: image)
            #expect(await waitUntil { group.tabs.count == 2 })
            #expect(await waitUntil { group.tabs.last?.shownFolderPath == volume })
            await harness.close()
        }

        // The Info panel's Open says why, with the same dialog.
        @Test func theInfoPanelsOpenSaysWhyItCouldNotBeOpened() async throws {
            let (harness, tab, image, _) = try await openWithImage()
            let spy = OpenSpy()
            tab.infoController?.actions.opener = spy.opener
            harness.windows.mountDiskImage = { _ in
                DiskImageOpenResponse(status: .failed, reason: "no mountable file systems")
            }
            try await pressOpenInTheInfoPanel(tab, harness, on: image)
            #expect(await waitUntil { tab.frontAlert != nil })
            let notice = DiskImageNames.describeFailure(path: image.path, reason: "no mountable file systems")
            #expect(tab.frontAlert?.titleLabel.stringValue == notice.title)
            #expect(spy.all.isEmpty)
            await harness.close()
        }

        // `openPaths`: an image not in the list (a search result's menu) goes the same way.
        @Test func theMenusOpenOfAnImageOutsideTheListMountsIt() async throws {
            let (harness, tab, _, _) = try await openWithImage()
            let spy = OpenSpy()
            tab.contextMenus.opener = spy.opener
            let elsewhere = "/Elsewhere/other.dmg"
            var mounted: [String] = []
            harness.windows.mountDiskImage = {
                mounted.append($0)
                return DiskImageOpenResponse(status: .handedOff)
            }
            tab.contextMenus.contextMenu(
                perform: .open,
                subject: ContextMenuSubject(
                    surface: .content, paths: [elsewhere], targetPath: elsewhere,
                    entries: [CommandEntry(path: elsewhere, kind: .file)]))
            #expect(await waitUntil { mounted == [elsewhere] })
            #expect(spy.all.isEmpty)
            await harness.close()
        }

        // A plain file still goes to macOS.
        @Test func anyOtherFileGoesToMacOS() async throws {
            let (harness, tab, _, handedToMacOS) = try await openWithImage()
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.open([note])
            #expect(handedToMacOS.urls.map(\.path) == [note.path])
            await harness.close()
        }
    }
}

/// One real image, mounted once: `hdiutil` puts a disk on the Mac, so only with FILETRAIL_GUI_TESTS=1.
@MainActor
@Suite(.holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct RealDiskImageTests {
    // T-712b64dd
    @Test func aRealImageMountsAndItsDiskOpensInATab() async throws {
        let harness = try ExplorerHarness.windowless()
        let name = "FT Port Test \(UUID().uuidString.prefix(6))"
        let image = harness.folder.appending("real.dmg")
        let made = await HdiutilProcess.run(["create", "-size", "4m", "-fs", "HFS+", "-volname", name, image.path])
        #expect(made.ok)
        let tab = try await harness.open()
        let opener = DiskImageOpener(onMounted: {})
        harness.windows.mountDiskImage = { await opener.open($0) }
        harness.channel.update(["diskImageOpensIn": .string("tab")], from: tab.windowID)
        tab.refresh()
        #expect(await waitUntil { tab.content.listed.contains { $0.name == "real.dmg" } })
        let entry = try #require(tab.content.listed.first { $0.name == "real.dmg" })
        tab.open([entry])
        let group = try #require(tab.group)
        let volume = "/Volumes/\(name)"
        #expect(await waitUntil { group.tabs.last?.shownFolderPath == volume })
        _ = await HdiutilProcess.run(["detach", volume, "-force"])
        await harness.close()
    }
}
