// The Previews view's pictures: a drag-to-select that goes by where each picture is, whole rows after any scroll, the
// previews let go once no pane shows the view, and sharper ones on a sharper screen
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct PreviewsPicturesTests {
        /// A picture of one color, `width` by `height` pixels, as PNG.
        private func writePicture(_ url: URL, width: Int, height: Int) throws {
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        /// A window on a folder of pictures `width` by `height`, in the Previews view, each showing its preview: the
        /// first `shown` of them, when the others are out of view.
        private func openPictures(
            _ harness: ExplorerHarness, _ names: [String], width: Int, height: Int, shown: Int? = nil
        ) async throws -> (MainWindowController, GridProbe, PreviewsViewController) {
            let folder = try harness.makeFolder(named: "Pictures", files: 0)
            for name in names { try writePicture(folder.appendingPathComponent(name), width: width, height: height) }
            let tab = try await harness.open(folder.path)
            tab.perform(.viewAsPreviews)
            let probe = GridProbe(tab: tab)
            #expect(await waitUntil { tab.content.entries.count == names.count && probe.pane != nil })
            harness.layout(tab)
            probe.layout()
            let previews = try #require(probe.pane as? PreviewsViewController)
            #expect(
                await waitUntil {
                    names.prefix(shown ?? names.count).allSatisfy { probe.iconItems[$0]?.thumbnail.image != nil }
                })
            probe.layout()
            return (tab, probe, previews)
        }

        private func path(_ tab: MainWindowController, _ name: String) throws -> String {
            try #require(tab.content.entries.first { $0.name == name }).path
        }

        // MARK: Drag-to-select

        // A wide photo is far wider than the square an icon takes: a box over its left edge selects it, one in the
        // empty space beside or above it selects nothing.
        @Test func aDragToSelectGoesByWhereEachPictureIs() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe, previews) = try await openPictures(harness, ["a.png", "b.png"], width: 900, height: 300)
            let item = try #require(probe.iconItems["a.png"])
            let grid = previews.collection
            let tile = item.tile.convert(item.tile.bounds, to: grid)
            let place = item.view.frame
            // The picture has its own shape: wider than the square an icon's tile would be, and lower than its place.
            #expect(tile.width > CGFloat(previews.layout.iconBoxSize) + 40)
            #expect(tile.minY - place.minY > 20)

            func drag(from start: NSPoint, to end: NSPoint) -> [String] {
                previews.selectFromOutside([])
                probe.press(at: probe.point(in: grid, at: start), moves: [probe.point(in: grid, at: end)])
                return probe.selectedNames
            }
            // Over the picture's left edge, from the empty space beside it.
            #expect(
                drag(from: NSPoint(x: tile.minX - 6, y: tile.midY), to: NSPoint(x: tile.minX + 6, y: tile.midY + 8))
                    == ["a.png"])
            // Beside it only.
            #expect(
                drag(from: NSPoint(x: tile.minX - 8, y: tile.midY), to: NSPoint(x: tile.minX - 1, y: tile.midY + 8))
                    == [])
            // Through the empty space above it, across the place's whole width.
            #expect(
                drag(from: NSPoint(x: place.minX + 2, y: place.minY + 2), to: NSPoint(x: place.maxX, y: tile.minY - 2))
                    == [])
            // On its name, under the picture.
            let name = item.label.convert(item.label.bounds, to: grid)
            #expect(
                drag(from: NSPoint(x: name.minX - 6, y: name.midY), to: NSPoint(x: name.minX + 4, y: name.midY + 2))
                    == ["a.png"])
            await harness.close()
        }

        // MARK: Whole rows

        // A mouse wheel turned a notch says nothing of its end: the pane settles on the next row the way it went
        // once the wheel rests. A place to scroll to from outside, saved when the rows had another height, goes to
        // the nearest row at once.
        @Test func aScrollThatSaysNothingOfItsEndSettlesOnARow() async throws {
            let harness = try ExplorerHarness.windowless()
            let (_, probe) = try await harness.openGrid(.viewAsPreviews, files: 24)
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            // The grid fitted to the pane puts its top row back once the main loop turns.
            try? await Task.sleep(for: .milliseconds(50))
            let clip = previews.scroll.contentView
            let rowHeight = CGFloat(previews.layout.rowHeight)
            func scroll(to top: CGFloat) {
                clip.scroll(to: NSPoint(x: 0, y: top))
                previews.scroll.reflectScrolledClipView(clip)
            }
            #expect(!previews.isSettling)
            scroll(to: 12)
            #expect(previews.isSettling)
            #expect(await waitUntil { !previews.isSettling && clip.bounds.origin.y == rowHeight })
            // Two notches up, a moment apart, are one scroll: back to the first row.
            scroll(to: rowHeight - 10)
            scroll(to: rowHeight - 22)
            #expect(await waitUntil { !previews.isSettling && clip.bounds.origin.y == 0 })
            // Already on a row: nothing moves.
            scroll(to: 2 * rowHeight)
            #expect(await waitUntil { !previews.isSettling })
            #expect(clip.bounds.origin.y == 2 * rowHeight)

            // The place a folder was left at, with rows of another height then.
            previews.scrollPosition = (top: Double(rowHeight) * 1.4, left: 0)
            #expect(clip.bounds.origin.y == rowHeight)
            previews.scrollPosition = (top: Double(rowHeight) * 2.6, left: 0)
            #expect(clip.bounds.origin.y == 3 * rowHeight)
            #expect(previews.scrollPosition.top == Double(3 * rowHeight))
            // Past the end: the last page, which starts on a row too.
            previews.scrollPosition = (top: 1e6, left: 0)
            let last = clip.bounds.origin.y
            #expect(last == previews.collection.frame.height - clip.bounds.height)
            #expect((last / rowHeight).rounded() * rowHeight == last)
            #expect(await waitUntil { !previews.isSettling })
            #expect(clip.bounds.origin.y == last)
            await harness.close()
        }

        // Make Bigger, Make Smaller and a taller pane keep the row that was at the top there, with rows of another
        // height: the pane's own move to that row is not a scroll to settle, in rows of either height.
        @Test func anotherSizeKeepsTheTopRowOnceThePaneSettles() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 24)
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            try? await Task.sleep(for: .milliseconds(50))
            let clip = previews.scroll.contentView
            /// The first item of the row at the top, once the pane had time to settle.
            func topItem() async -> Int {
                try? await Task.sleep(for: .milliseconds(100))
                _ = await waitUntil { !previews.isSettling }
                let row = Double(clip.bounds.origin.y) / previews.layout.rowHeight
                #expect(abs(row - row.rounded()) < 0.001)
                return Int(row.rounded()) * previews.columns
            }
            // Three rows of two down.
            clip.scroll(to: NSPoint(x: 0, y: 3 * previews.layout.rowHeight - 20))
            previews.scroll.reflectScrolledClipView(clip)
            #expect(await topItem() == 6)
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.count == 2)
            #expect(await topItem() == 6)
            tab.perform(.decreaseSize)
            tab.perform(.decreaseSize)
            probe.layout()
            #expect(previews.count == 9)
            #expect(await topItem() == 6)
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.count == 4)
            #expect(await topItem() == 6)
            // A taller window: taller rows.
            let window = try #require(tab.window)
            let rowHeight = previews.layout.rowHeight
            window.setContentSize(NSSize(width: window.frame.width, height: window.frame.height + 200))
            harness.layout(tab)
            probe.layout()
            #expect(previews.layout.rowHeight > rowHeight)
            #expect(await topItem() == 6)
            await harness.close()
        }

        // The row is back at the top within the layout that gave the rows another height, not a turn of the main
        // loop later: a place the pane is scrolled to right after that layout (a tab brought back, search results
        // shown again) stays.
        @Test func aPlaceScrolledToRightAfterAnotherSizeStays() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(.viewAsPreviews, files: 24)
            let previews = try #require(probe.pane as? PreviewsViewController)
            previews.settleDelay = 0.02
            try? await Task.sleep(for: .milliseconds(50))
            let clip = previews.scroll.contentView
            previews.scrollPosition = (top: 3 * previews.layout.rowHeight, left: 0)
            #expect(Double(clip.bounds.origin.y) == 3 * previews.layout.rowHeight)

            let window = try #require(tab.window)
            let before = previews.layout.rowHeight
            window.setContentSize(NSSize(width: window.frame.width, height: window.frame.height + 200))
            harness.layout(tab)
            probe.layout()
            #expect(previews.layout.rowHeight > before)
            // Already there, with nothing waited for.
            #expect(abs(Double(clip.bounds.origin.y) - 3 * previews.layout.rowHeight) < 0.5)
            previews.scrollPosition = (top: 5 * previews.layout.rowHeight, left: 0)
            try? await Task.sleep(for: .milliseconds(100))
            _ = await waitUntil { !previews.isSettling }
            #expect(abs(Double(clip.bounds.origin.y) - 5 * previews.layout.rowHeight) < 0.5)
            await harness.close()
        }

        // MARK: The previews kept

        // The panes are counted, and what they share is let go a little after the last one went, unless one came
        // back meanwhile.
        @Test func whatThePanesShareGoesALittleAfterTheLastPane() async {
            var drops = 0
            let panes = PreviewPanes { drops += 1 }
            panes.delay = 0.05
            panes.appeared()
            panes.appeared()
            panes.disappeared()
            #expect(panes.shown == 1 && !panes.isWaiting)
            panes.disappeared()
            #expect(panes.shown == 0 && panes.isWaiting && drops == 0)
            // Back before the wait is over: nothing is let go.
            panes.appeared()
            #expect(!panes.isWaiting)
            try? await Task.sleep(for: .milliseconds(150))
            #expect(drops == 0)
            panes.disappeared()
            #expect(await waitUntil { drops == 1 })
            #expect(!panes.isWaiting)
            try? await Task.sleep(for: .milliseconds(150))
            #expect(drops == 1)
        }

        // The last pane that shows the Previews view going to another view lets the previews go.
        @Test func thePreviewsGoOnceNoPaneShowsThePreviewsView() async throws {
            let panes = PreviewThumbnails.panes
            let delay = panes.delay
            defer { panes.delay = delay }
            let harness = try ExplorerHarness.windowless()
            let before = panes.shown
            let (tab, _, _) = try await openPictures(harness, ["a.png"], width: 300, height: 200)
            let picture = try path(tab, "a.png")
            #expect(panes.shown == before + 1)
            #expect(PreviewThumbnails.store.loadedPicture(forPath: picture) != nil)
            #expect(PreviewThumbnails.store.memoryUsed > 0)

            // To the Icons view and back before the wait is over: the previews stay.
            panes.delay = 30
            tab.perform(.viewAsIcons)
            #expect(await waitUntil { panes.shown == before })
            #expect(panes.isWaiting == (before == 0))
            tab.perform(.viewAsPreviews)
            #expect(await waitUntil { panes.shown == before + 1 })
            #expect(!panes.isWaiting)
            #expect(PreviewThumbnails.store.loadedPicture(forPath: picture) != nil)

            // Away for good.
            panes.delay = 0.05
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { panes.shown == before })
            if before == 0 {
                #expect(await waitUntil { PreviewThumbnails.store.count == 0 })
                #expect(PreviewThumbnails.store.memoryUsed == 0)
                #expect(!panes.isWaiting)
            }
            await harness.close()
            #expect(before == 0, "a pane of an earlier test still counts as showing the Previews view")
        }

        // MARK: Waiting for the previews

        // The previews of the page below the one on screen are asked for ahead of need: scrolled to, they show in
        // their first frame. Then the page below that one is asked for, and the one above, already kept.
        @Test func theNextPageIsAskedForAheadOfNeed() async throws {
            let harness = try ExplorerHarness.windowless()
            let names = "abcdefghijkl".map { "\($0).png" }
            // Four at a time, two by two.
            let (tab, probe, previews) = try await openPictures(harness, names, width: 300, height: 200, shown: 4)
            #expect(previews.count == 4 && previews.columns == 2)
            let paths = try names.map { try path(tab, $0) }
            let store = PreviewThumbnails.store
            #expect(await waitUntil { previews.prefetchedPaths == Set(paths[4..<8]) })
            #expect(await waitUntil { paths[4..<8].allSatisfy { store.loadedPicture(forPath: $0) != nil } })
            #expect(paths[8...].allSatisfy { store.loadedPicture(forPath: $0) == nil })

            previews.scrollPosition = (top: previews.layout.rowHeight * 2, left: 0)
            probe.layout()
            for name in names[4..<8] {
                let item = try #require(probe.iconItems[name])
                #expect(item.thumbnail.image != nil && !item.isWaitingForPicture && item.iconView.isHidden)
            }
            #expect(await waitUntil { previews.prefetchedPaths == Set(paths[8...] + paths[..<4]) })
            #expect(await waitUntil { paths[8...].allSatisfy { store.loadedPicture(forPath: $0) != nil } })
            await harness.close()
        }

        // Make Bigger shows fewer, larger previews: the page after the one on screen is another, and its previews are
        // asked for at the new size, where those asked for at the old one were kept and came up blurred.
        @Test func anotherCountAsksForItsNextPageAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let names = "abcdefghijkl".map { "\($0).png" }
            let (tab, probe, previews) = try await openPictures(harness, names, width: 300, height: 200, shown: 4)
            let paths = try names.map { try path(tab, $0) }
            #expect(await waitUntil { previews.prefetchedPaths == Set(paths[4..<8]) })
            tab.perform(.increaseSize)
            probe.layout()
            #expect(previews.count == 2)
            #expect(await waitUntil { previews.prefetchedPaths == Set(paths[2..<4]) })
            await harness.close()
        }

        // The name sits right under the picture, whatever its shape: a name being edited follows when the picture
        // comes or changes.
        @Test func aNameBeingEditedStaysUnderItsPictureWhenThePictureChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe, previews) = try await openPictures(harness, ["a.png"], width: 600, height: 150)
            let entry = try #require(tab.content.entries.first)
            let item = try #require(probe.iconItems["a.png"])
            tab.content.select(paths: [entry.path])
            #expect(tab.content.beginRename(path: entry.path))
            let field = try #require(previews.renameField)
            let wide = field.frame
            #expect(wide == previews.renameFrame(at: 0))

            // The file is another picture now, tall where it was wide.
            try writePicture(URL(fileURLWithPath: entry.path), width: 150, height: 600)
            PreviewThumbnails.store.markChanged([entry.path])
            let shape = item.pictureShape
            item.loadThumbnail(entry, pane: previews)
            #expect(await waitUntil { item.pictureShape != shape })
            #expect(field.frame == previews.renameFrame(at: 0))
            #expect(field.frame != wide)
            await harness.close()
        }

        // A preview not known yet is waited for with nothing drawn in its place, and drawn there when it comes: the
        // icon never shows before it.
        @Test func aPreviewNotKnownYetIsWaitedForWithoutTheIcon() async throws {
            let wait = PreviewsViewController.iconWait
            defer { PreviewsViewController.iconWait = wait }
            PreviewsViewController.iconWait = 30
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Pictures", files: 0)
            try writePicture(folder.appendingPathComponent("a.png"), width: 300, height: 200)
            let tab = try await harness.open(folder.path)
            tab.perform(.viewAsPreviews)
            let probe = GridProbe(tab: tab)
            #expect(await waitUntil { tab.content.entries.count == 1 && probe.pane != nil })
            harness.layout(tab)
            probe.layout()
            let item = try #require(probe.iconItems["a.png"])
            if item.thumbnail.image == nil {
                #expect(item.isWaitingForPicture && item.iconView.isHidden && item.thumbnail.isHidden)
            }
            #expect(await waitUntil { item.thumbnail.image != nil })
            #expect(!item.isWaitingForPicture && item.iconView.isHidden && !item.thumbnail.isHidden)
            await harness.close()
        }

        // MARK: The screen

        // A window that moves to a sharper screen asks for its previews again at that screen's pixels.
        @Test func aSharperScreenAsksForSharperPreviews() async throws {
            defer { PreviewsViewController.screenForTests = nil }
            PreviewsViewController.screenForTests = (scale: 1, longestSide: 10_000)
            let harness = try ExplorerHarness.windowless()
            let (tab, probe, previews) = try await openPictures(harness, ["a.png"], width: 3000, height: 2000)
            let item = try #require(probe.iconItems["a.png"])
            let soft = previews.thumbnailPixelSize
            let width = try #require(item.thumbnail.image?.size.width)
            #expect(width <= CGFloat(soft))

            PreviewsViewController.screenForTests = (scale: 3, longestSide: 10_000)
            let sharp = previews.thumbnailPixelSize
            #expect(sharp > soft + 256)
            NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: tab.window)
            #expect(await waitUntil { (item.thumbnail.image?.size.width ?? 0) > CGFloat(soft) })
            #expect((item.thumbnail.image?.size.width ?? 0) <= CGFloat(sharp))
            // Another window's screen changes nothing here.
            let loaded = item.thumbnail.image
            NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: NSWindow())
            #expect(item.thumbnail.image === loaded)
            await harness.close()
        }
    }
}
