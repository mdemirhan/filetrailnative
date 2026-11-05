import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct ApplicationPathsTests {
    @Test func namesTerminalWhenNoTerminalIsChosen() {
        #expect(SystemActions.terminalApplicationName(nil) == "Terminal")
    }

    @Test func namesTheChosenTerminalByItsName() {
        let chosen = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")
        #expect(SystemActions.terminalApplicationName(chosen) == "iTerm")
    }

    @Test func namesTheChosenTerminalByItsBundleWhenTheNameIsBlank() {
        let chosen = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "  ")
        #expect(SystemActions.terminalApplicationName(chosen) == "iTerm")
    }

    @Test func namesTerminalWhenTheChosenOneHasNoUsableValues() {
        let chosen = ApplicationSelection(appPath: "  ", appName: "")
        #expect(SystemActions.terminalApplicationName(chosen) == "Terminal")
    }

    @Test func acceptsAbsolutePathsToAppBundles() {
        #expect(ApplicationPaths.isValidBundlePath("/Applications/Zed.app"))
        #expect(ApplicationPaths.isValidBundlePath("/Applications/Visual Studio Code.app"))
    }

    @Test func rejectsRelativePathsAndBareApplicationNames() {
        #expect(!ApplicationPaths.isValidBundlePath("Finder"))
        #expect(!ApplicationPaths.isValidBundlePath("Applications/Zed.app"))
        #expect(!ApplicationPaths.isValidBundlePath(""))
    }

    @Test func rejectsPathsWithParentDirectoryParts() {
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/../tmp/Evil.app"))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/Safari.app/../../usr/bin/say"))
    }

    @Test func rejectsAbsolutePathsThatAreNotAppBundles() {
        #expect(!ApplicationPaths.isValidBundlePath("/usr/bin/say"))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/Zed.app/Contents/MacOS/zed"))
    }

    @Test func refusesATerminalOverrideThatIsNotAnAbsoluteAppBundlePath() async {
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo", terminalApp: ApplicationSelection(appPath: "Applications/iTerm.app", appName: "iTerm"))
        #expect(!result.ok)
        #expect(result.error?.contains("Invalid application path") == true)
        #expect(result.terminalName == "iTerm")
    }

    @Test func derivesTheDisplayNameFromTheAppBundlePath() {
        #expect(ApplicationPaths.displayName("/Applications/Visual Studio Code.app") == "Visual Studio Code")
        #expect(ApplicationPaths.displayName("Finder") == "Finder")
    }
}
