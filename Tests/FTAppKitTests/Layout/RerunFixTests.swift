// Wave-3 rerun (P5-18): text baselines, the rename field staying over the rows, the
// tree's fade, the search folder column and the shadows that fall down
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct RerunFixTests {
    // MARK: Baselines

    @Test func theBrowsersAscentIsRoundedToADevicePixel() {
        // At 2x every size of the system font the app uses lands half a point above AppKit's whole-point baseline.
        for size in [10.0, 11, 12, 13, 14, 15] {
            let font = NSFont.systemFont(ofSize: size)
            #expect(TextBaseline.offset(of: font, scale: 2) == -0.5)
        }
        // At 1x both round the same ascent to a pixel.
        #expect(TextBaseline.offset(of: .systemFont(ofSize: 14), scale: 1) == 0)
    }

    @Test func aBaselineIsSnappedToTheNearestDevicePixelNotUp() {
        let font = NSFont.systemFont(ofSize: 11)
        // A box at 59.52 (the browser's 59.5 with a slightly shorter line): baseline at 70.02, which goes to 70.
        let top = TextBaseline.lineTop(59.52, font: font, scale: 2, baselineFromWindowTop: 70.02)
        #expect(abs(top + font.ascender.rounded() - 70) < 0.01)
        #expect(top + font.ascender.rounded() <= 70)
    }

    @Test func aDrawnLabelsBaselineIsHalfAPointAboveAppKits() throws {
        let baseline = try #require(inkBottom(of: "HHH", in: TextBoxField(labelWithString: "HHH")))
        // No window: a box at 4 with 14 pt text, whose ascent the browser rounds to 13.5 at 2x.
        #expect(baseline == (4 + 13.5) * 2)
    }

    /// The first pixel row under the text a label draws at y 4, at two pixels to the point.
    private func inkBottom(of text: String, in field: NSTextField) -> Double? {
        field.font = .systemFont(ofSize: 14)
        field.textColor = .black
        field.frame = NSRect(x: 2, y: 4, width: 100, height: 17)
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        host.addSubview(field)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        var bottom = -1
        for y in 0..<60 {
            for x in 0..<240 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { bottom = max(bottom, y) }
        }
        return bottom < 0 ? nil : Double(bottom + 1)
    }

    private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    // MARK: The rename field

    @Test func rowsAddedAfterTheFieldStayUnderIt() {
        let list = NSView()
        let field = InlineRenameField(
            name: "untitled folder", fileExtension: "", isFolder: true, draftKey: nil, font: .systemFont(ofSize: 14),
            theme: AppearanceModel.shared.theme)
        list.addSubview(field)
        let first = NSView()
        let second = NSView()
        list.addSubview(first)
        list.addSubview(second)
        InlineRenameField.keepOnTop(in: list)
        #expect(list.subviews.last === field)
        #expect(list.subviews.count == 3)
    }

    // MARK: The tree's fade

    @Test func theTreeFadesAtItsTop() throws {
        let tree = SidebarListView(subview: .tree)
        tree.frame = NSRect(x: 0, y: 0, width: 280, height: 400)
        tree.fadesTop = true
        let mask = try #require(tree.layer?.mask as? CAGradientLayer)
        // Flipped: the transparent end at y 0 is the view's top.
        #expect(mask.startPoint.y == 0 && mask.endPoint.y == 1)
        #expect((mask.colors?.first as! CGColor).alpha == 0)
    }

    // MARK: The search folder column

    @Test func aFolderThatFitsIsWhole() {
        let font = NSFont.systemFont(ofSize: 14)
        let fit = FolderColumnText.fit("app › src", width: 300, font: font)
        #expect(fit == .init(text: "app › src", isCut: false))
    }

    @Test func aFolderTooLongLosesItsStartAndKeepsItsSpaces() {
        let font = NSFont.systemFont(ofSize: 14)
        let whole = "app › src › components"
        let width =
            (" › components" as NSString).size(withAttributes: [.font: font]).width
            + ("…" as NSString).size(withAttributes: [.font: font]).width
        let fit = FolderColumnText.fit(whole, width: width + 0.5, font: font)
        #expect(fit.isCut)
        #expect(fit.text == "… › components")
    }

    @Test func aFolderAHairTooWideIsCut() {
        let font = NSFont.systemFont(ofSize: 14)
        let whole = "app › src › pages"
        let width = (whole as NSString).size(withAttributes: [.font: font]).width
        #expect(FolderColumnText.fit(whole, width: width - 0.25, font: font).isCut)
    }

    // MARK: Shadows

    @Test func aMenuSurfacesShadowFallsDownInAFlippedView() {
        let layer = CALayer()
        MenuSurface.apply(to: layer, theme: AppearanceModel.shared.theme, borderWidth: 0.5)
        #expect(layer.shadowOffset.height > 0)
    }

    @Test func theSuggestionsShadowIsTheLargeShadowFallingDown() {
        let view = PathSuggestionsView()
        view.applyLook()
        let shadow = ThemePalette.light.shadowLg[0]
        #expect(view.layer?.shadowOffset.height == CGFloat(shadow.y))
        #expect(view.layer?.shadowRadius == CGFloat(shadow.blur / 2))
    }

    // MARK: The Info Row

    @Test func theClosedInfoRowCutsOffWhatIsInIt() {
        #expect(ContentPaneView().infoRow.clipsToBounds)
    }
}
