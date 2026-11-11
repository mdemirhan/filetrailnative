// The rename field staying over the rows, the tree's fade, the search folder column and the shadows that fall down
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct FadesAndShadowsTests {
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
