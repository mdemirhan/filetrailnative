// Port of apps/desktop/src/shared/aboutInfo.test.ts and the formatMacosVersion case of src/main/aboutInfo.test.ts
import Testing

@testable import FTFoundation

struct AboutInfoTests {
    private let info = AboutInfo(
        version: "0.1.0", commit: "df11088", macosVersion: "27.0", architecture: "Apple silicon", fdVersion: "10.5.0")

    // T-c85ea104 F-670
    @Test func addsTheCommitTheAppWasBuiltFromWhenTheBuildKnowsIt() {
        #expect(AboutText.formatAppVersion(info) == "0.1.0 (df11088)")
        var unknown = info
        unknown.commit = nil
        #expect(AboutText.formatAppVersion(unknown) == "0.1.0")
    }

    // T-b5c84c49 F-670 (no Electron line: the app has no runtime to name)
    @Test func listsWhatABugReportNeedsOneLineEach() {
        #expect(
            AboutText.formatAboutDetails(info)
                == ["File Trail 0.1.0 (df11088)", "macOS 27.0, Apple silicon", "fd 10.5.0"].joined(separator: "\n"))
    }

    // T-50f842b6 F-670 the rows of the window
    @Test func showsTheVersionMacOSAndSearchRows() {
        let rows = AboutText.rows(info)
        #expect(rows.map(\.label) == ["Version", "macOS", "Search"])
        #expect(rows.map(\.value) == ["0.1.0 (df11088)", "27.0, Apple silicon", "fd 10.5.0"])
    }

    // T-deff515e F-640
    @Test func namesAMacOSVersionTheWayMacOSDoes() {
        #expect(AboutText.formatMacosVersion("27.0.0") == "27.0")
        #expect(AboutText.formatMacosVersion("27.0.1") == "27.0.1")
        #expect(AboutText.formatMacosVersion("27.1.0") == "27.1")
        #expect(AboutText.formatMacosVersion("27.0") == "27.0")
        #expect(AboutText.formatMacosVersion("x.0.0") == "x.0.0")
    }

    // F-669 F-670 the window's fixed texts
    @Test func hasTheTextsOfTheWindow() {
        #expect(AboutText.appName == "File Trail")
        #expect(AboutText.tagline == "A file browser that stays out of your way.")
        #expect(AboutText.copyright == "© 2026 Mustafa Demirhan")
        #expect(AboutText.repositoryURL == "https://github.com/mdemirhan/filetrailnative")
        #expect(AboutText.issuesURL == "https://github.com/mdemirhan/filetrailnative/issues")
    }
}
