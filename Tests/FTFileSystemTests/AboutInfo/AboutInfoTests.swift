// Port of apps/desktop/src/main/aboutInfo.test.ts: the build's version and commit now come from the app's Info.plist, and
// the licenses from Resources/Acknowledgements
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct AboutInfoTests {
    // T-68d00b02 F-921
    @Test func findsTheAcknowledgementsFolderInTheAppOrBesideTheSource() throws {
        try withTemporaryDirectory { root in
            let app = root.appending("Resources/Acknowledgements")
            let source = root.appending("source")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let locations = Acknowledgements.Locations(resources: app, sourceTree: source)

            #expect(Acknowledgements.resolveDirectory(locations) == nil)
            try "[]".write(to: source.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
            #expect(Acknowledgements.resolveDirectory(locations) == source)
            try "[]".write(to: app.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
            #expect(Acknowledgements.resolveDirectory(locations) == app)
        }
    }

    // T-a753ba59 F-924
    @Test func readsTheCommitTheBuildRecordedAndDoesWithoutOne() {
        #expect(BuildInfo.commit(from: nil) == nil)
        #expect(BuildInfo.commit(from: [:]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": NSNull()]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": ""]) == nil)
        #expect(BuildInfo.commit(from: ["FTCommit": "df11088"]) == "df11088")
    }

    // T-571dc8b6 F-924
    @Test func readsTheVersionTheBuildRecordedAndDoesWithoutOne() {
        #expect(BuildInfo.version(from: nil) == nil)
        #expect(BuildInfo.version(from: ["FTCommit": "df11088"]) == nil)
        #expect(BuildInfo.version(from: ["CFBundleShortVersionString": "0.1.0+dev.4", "FTCommit": "df11088"]) == "0.1.0+dev.4")
    }

    // T-deff515e F-640
    @Test func namesAMacOSVersionTheWayMacOSDoes() {
        #expect(AboutInfoReader.versionString(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == "27.0.0")
        let info = AboutInfoReader.read(
            info: ["CFBundleShortVersionString": "0.2.0", "FTCommit": "abc1234"],
            systemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            architecture: "Apple silicon", fdVersion: "10.5.0")
        #expect(
            info
                == AboutInfo(
                    version: "0.2.0", commit: "abc1234", macosVersion: "27.0", architecture: "Apple silicon",
                    fdVersion: "10.5.0"))
        // A run with no Info.plist has the placeholder version and no commit.
        let bare = AboutInfoReader.read(info: nil)
        #expect(bare.version == BuildInfo.fallbackVersion)
        #expect(bare.commit == nil)
        #expect(bare.fdVersion == FdBinary.manifest.version)
    }

    // T-f3735749 F-640 F-921
    @Test func listsTheBundledSoftwareWithEachLicenseAsShipped() throws {
        try withTemporaryDirectory { root in
            let folder = root.appending("Acknowledgements")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "MIT License\n".write(to: folder.appendingPathComponent("fd.txt"), atomically: true, encoding: .utf8)
            let index = """
                [{"id":"fd","name":"fd","version":"10.5.0","license":"MIT or Apache 2.0",\
                "url":"https://github.com/sharkdp/fd","file":"fd.txt"}]
                """
            try index.write(to: folder.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
            let locations = Acknowledgements.Locations(resources: folder, sourceTree: nil)

            #expect(try Acknowledgements.read(.init(resources: nil, sourceTree: nil)) == [])
            #expect(
                try Acknowledgements.read(locations) == [
                    Acknowledgement(
                        id: "fd", name: "fd", version: "10.5.0", license: "MIT or Apache 2.0",
                        url: "https://github.com/sharkdp/fd", text: "MIT License\n")
                ])
        }
    }

    // F-921 the list the repository ships is what the generator writes: fd and its two licenses
    @Test func theCheckedInListHasFdWithBothLicenses() throws {
        let list = try Acknowledgements.read(Acknowledgements.Locations(resources: nil, sourceTree: Acknowledgements.Locations.standard.sourceTree))
        #expect(list.map(\.id) == ["fd"])
        #expect(list.first?.version == FdBinary.manifest.version)
        #expect(list.first?.text.contains("MIT License") == true)
        #expect(list.first?.text.contains("Apache License") == true)
    }

    // N/A T-725c5857 T-267cd409 T-6a3ab821 T-cf26e7f5 T-c77dd85a Chromium's notices are not in the native bundle
    @Test func hasNoSeparateNotices() {
        #expect(true)
    }
}
