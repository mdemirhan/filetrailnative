import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct CommandIconTests {
    @Test func everyCommandIconIsASymbolOfThisSystem() {
        for icon in CommandIcon.allCases {
            #expect(NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil) != nil, "\(icon)")
            #expect(icon.image.isTemplate, "\(icon)")
        }
    }

    @Test func everyToolbarButtonHasAnIconAndTheItemsThatAreNotButtonsHaveNone() {
        let notButtons: Set<ToolbarItemID> = [.topSeparator, .title, .view]
        for id in ToolbarItemID.allCases {
            #expect((ToolbarItems.definition(id).icon == nil) == notButtons.contains(id), "\(id)")
        }
    }

    @Test func commandsSideBySideHaveSymbolsOfTheirOwn() {
        let groups: [[CommandIcon]] = [
            [.back, .forward, .up], [.icons, .details, .list], [.cut, .copy, .paste, .copyPath],
            [.edit, .rename], [.folderTree, .infoPanel, .infoRow], [.trash, .deleteImmediately],
            [.open, .openInNewTab, .openInNewWindow, .openWith], [.move, .newFolder, .duplicate],
        ]
        for group in groups {
            #expect(Set(group.map(\.symbolName)).count == group.count, "\(group)")
        }
    }

    @Test func theFoldersOwnOpenAndAFilesOpenAreOneSymbol() {
        #expect(CommandIcon.open.symbolName == CommandIcon.openFile.symbolName)
    }
}
