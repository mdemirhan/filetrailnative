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

        /// A window on a folder of pictures `width` by `height`, in the Previews view, each showing its preview.
        private func openPictures(
            _ harness: ExplorerHarness, _ names: [String], width: Int, height: Int
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
                    names.allSatisfy { probe.iconItems[$0]?.thumbnail.image != nil }
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
