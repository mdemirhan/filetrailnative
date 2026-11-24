// The build's version and commit come from the app's Info.plist
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct AboutInfoTests {
    @Test func readsTheCommitTheBuildRecordedAndDoesWithoutOne() {
        #expect(BuildInfo.commit(from: nil) == nil)
        #expect(BuildInfo.commit(from: [:]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": NSNull()]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": ""]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": "df11088"]) == "df11088")
    }

    @Test func readsTheVersionTheBuildRecordedAndDoesWithoutOne() {
        #expect(BuildInfo.version(from: nil) == nil)
        #expect(BuildInfo.version(from: ["FTCommit": "df11088"]) == nil)
        #expect(
            BuildInfo.version(from: [
                "CFBundleShortVersionString": "0.1.0", "FTVersion": "0.1.0+dev.4", "FTCommit": "df11088",
            ]) == "0.1.0+dev.4")
    }

    @Test func namesAMacOSVersionTheWayMacOSDoes() {
        #expect(
            AboutInfoReader.versionString(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
                == "27.0.0")
        let info = AboutInfoReader.read(
            info: ["FTVersion": "0.2.0", "FTCommit": "abc1234"],
            systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            architecture: "Apple silicon")
        #expect(
            info
                == AboutInfo(version: "0.2.0", commit: "abc1234", macosVersion: "27.0", architecture: "Apple silicon"))
        // A run with no Info.plist has the placeholder version and no commit.
        let bare = AboutInfoReader.read(info: nil)
        #expect(bare.version == BuildInfo.fallbackVersion)
        #expect(bare.commit == nil)
    }
}
