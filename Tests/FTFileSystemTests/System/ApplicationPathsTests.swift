// Port of apps/desktop/src/main/bootstrap.test.ts (resolveTerminalApplicationName, isValidApplicationBundlePath, openInTerminal, resolveApplicationDisplayName)
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct ApplicationPathsTests {
    // T-3ebc19b8
    @Test func namesTerminalWhenNoTerminalIsChosen() {
        #expect(SystemActions.terminalApplicationName(nil) == "Terminal")
    }

    // T-7475884c
    @Test func namesTheChosenTerminalByItsName() {
        let chosen = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")
        #expect(SystemActions.terminalApplicationName(chosen) == "iTerm")
    }

    // T-91c74364
    @Test func namesTheChosenTerminalByItsBundleWhenTheNameIsBlank() {
        let chosen = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "  ")
        #expect(SystemActions.terminalApplicationName(chosen) == "iTerm")
    }

    // T-647a4e22
    @Test func namesTerminalWhenTheChosenOneHasNoUsableValues() {
        let chosen = ApplicationSelection(appPath: "  ", appName: "")
        #expect(SystemActions.terminalApplicationName(chosen) == "Terminal")
    }

    // T-2155acfe
    @Test func acceptsAbsolutePathsToAppBundles() {
        #expect(ApplicationPaths.isValidBundlePath("/Applications/Zed.app"))
        #expect(ApplicationPaths.isValidBundlePath("/Applications/Visual Studio Code.app"))
    }

    // T-4b86c108
    @Test func rejectsRelativePathsAndBareApplicationNames() {
        #expect(!ApplicationPaths.isValidBundlePath("Finder"))
        #expect(!ApplicationPaths.isValidBundlePath("Applications/Zed.app"))
        #expect(!ApplicationPaths.isValidBundlePath(""))
    }

    // T-3c8a7e03
    @Test func rejectsPathsWithParentDirectoryParts() {
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/../tmp/Evil.app"))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/Safari.app/../../usr/bin/say"))
    }

    // T-cdb1d0ce
    @Test func rejectsAbsolutePathsThatAreNotAppBundles() {
        #expect(!ApplicationPaths.isValidBundlePath("/usr/bin/say"))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/Zed.app/Contents/MacOS/zed"))
    }

    // T-155af596
    @Test func refusesATerminalOverrideThatIsNotAnAbsoluteAppBundlePath() async {
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo", terminalApp: ApplicationSelection(appPath: "Applications/iTerm.app", appName: "iTerm"))
        #expect(!result.ok)
        #expect(result.error?.contains("Invalid application path") == true)
        #expect(result.terminalName == "iTerm")
    }

    // T-f65b86d1
    @Test func derivesTheDisplayNameFromTheAppBundlePath() {
        #expect(ApplicationPaths.displayName("/Applications/Visual Studio Code.app") == "Visual Studio Code")
        #expect(ApplicationPaths.displayName("Finder") == "Finder")
    }
}
