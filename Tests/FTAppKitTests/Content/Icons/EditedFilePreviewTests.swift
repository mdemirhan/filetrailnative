// A file edited in place keeps its name and its place in the folder: its preview follows its content once the folder
// watch tells of the change
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct EditedFilePreviewTests {
        /// A square picture of one color, as PNG.
        private func png(red: CGFloat, blue: CGFloat) throws -> Data {
            let rep = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3,
                    hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let color = NSColor(deviceRed: red, green: 0, blue: blue, alpha: 1)
            for x in 0..<64 {
                for y in 0..<64 { rep.setColor(color, atX: x, y: y) }
            }
            return try #require(rep.representation(using: .png, properties: [:]))
        }

        /// Whether the picture is mostly blue at its middle.
        private func isBlue(_ image: NSImage?) -> Bool {
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return false
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
            else { return false }
            return color.blueComponent > 0.5 && color.redComponent < 0.5
        }

        @Test(arguments: [AppCommand.viewAsIcons, .viewAsPreviews])
        func anEditedPictureShowsItsNewContent(_ view: AppCommand) async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Pictures", files: 0)
            let file = folder.appendingPathComponent("picture.png")
            try png(red: 1, blue: 0).write(to: file)
            let tab = try await harness.open(folder.path)
            tab.perform(view)
            let probe = GridProbe(tab: tab)
            #expect(await waitUntil { tab.content.entries.count == 1 && probe.pane != nil })
            harness.layout(tab)
            probe.layout()
            let item = try #require(probe.iconItems["picture.png"])
            #expect(await waitUntil { item.thumbnail.image != nil })
            let before = item.thumbnail.image
            #expect(!isBlue(before))

            // Its name, kind and place are as they were: nothing about its entry changed.
            try png(red: 0, blue: 1).write(to: file)
            tab.services.directoryService.cache.clear()
            let path = tab.content.entries[0].path
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: [path]))
            #expect(await waitUntil { isBlue(item.thumbnail.image) })
            #expect(item.thumbnail.image !== before)
            await harness.close()
        }
    }
}
