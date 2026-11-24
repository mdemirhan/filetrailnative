import Testing

@testable import FTFoundation

/// What the magnifier's and the results bar's tooltips say of a search's options.
struct SearchOptionsTextTests {
    @Test func namesNothingWhileEveryOptionIsAtItsDefault() {
        let changed = SearchBarText.changedOptions(
            matchScope: .name, patternMode: .text, recursive: true, skipGitFolders: true)
        #expect(changed.isEmpty)
        #expect(SearchBarText.optionsTitle(changed: changed) == "Search Options")
    }

    // Each option off its default, by the menu's names, in the menu's order.
    @Test func namesEachOptionOffItsDefaultInTheMenusOrder() {
        let changed = SearchBarText.changedOptions(
            matchScope: .path, patternMode: .regex, recursive: false, skipGitFolders: false)
        #expect(
            changed == ["Full Path", "Regex", "Search Subfolders Off", "Skip .git Folders Off"])
        #expect(
            SearchBarText.optionsTitle(changed: ["Glob"]) == "Search Options: Glob")
    }
}
