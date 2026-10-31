// Ports apps/desktop/src/main/launchContext.test.ts
import FTFileSystem
import Testing

@testable import FTAppKit

@Suite struct LaunchContextTests {
    private func resolve(
        _ argv: [String], cwd: String, home: String = "/Users/demo", appPath: String? = nil, argvOffset: Int = 1,
        isDirectory: @escaping (String) -> Bool = { _ in true }
    ) -> String? {
        LaunchContext.resolveStartupFolderPath(
            argv: argv, cwd: cwd, argvOffset: argvOffset, homePath: home, appPath: appPath, isDirectory: isDirectory)
    }

    // T-5cb5cea0 F-613 F-644
    @Test func readsAnExplicitFolderPath() {
        #expect(resolve(["filetrail", "--folder", "/Users/demo/project"], cwd: "/tmp") == "/Users/demo/project")
    }

    // T-f7a78471 F-613 F-644
    @Test func readsAnInlineFolderPath() {
        #expect(
            resolve(["filetrail", "--folder=projects/filetrail"], cwd: "/Users/demo")
                == "/Users/demo/projects/filetrail")
    }

    // T-354ff548 F-613
    @Test func usesAPositionalFolderArgumentWhenFolderIsNotProvided() {
        #expect(resolve(["filetrail", "/Users/demo/src"], cwd: "/tmp") == "/Users/demo/src")
    }

    // T-055bf880 F-613
    @Test func ignoresTheAppPathPositionalArgumentInDevLaunches() {
        #expect(
            resolve(
                ["electron", ".", "/Users/demo/src"], cwd: "/Users/demo/filetrail/apps/desktop",
                appPath: "/Users/demo/filetrail/apps/desktop") == "/Users/demo/src")
    }

    // T-327a3f5a F-613
    @Test func doesNotTreatTheAppPathItselfAsAStartupFolder() {
        #expect(
            resolve(
                ["electron", "."], cwd: "/Users/demo/filetrail/apps/desktop",
                appPath: "/Users/demo/filetrail/apps/desktop")
                == nil)
    }

    // T-9b4ad75a F-613
    @Test func expandsTildePrefixedFolderArguments() {
        #expect(resolve(["filetrail", "~/src"], cwd: "/tmp") == "/Users/demo/src")
        #expect(resolve(["filetrail", "~"], cwd: "/tmp") == "/Users/demo")
    }

    // T-0701632e F-613
    @Test func prefersFolderOverAPositionalFolderArgument() {
        #expect(
            resolve(
                ["filetrail", "/Users/demo/ignored", "--folder", "/Users/demo/project"], cwd: "/tmp",
                isDirectory: { $0 == "/Users/demo/project" }) == "/Users/demo/project")
    }

    // T-6548d60d F-613
    @Test func ignoresAppPathArgumentsWhenAnArgvOffsetIsProvided() {
        #expect(
            resolve(
                ["electron", "/Users/demo/filetrail", "/Users/demo/project"], cwd: "/tmp", argvOffset: 2)
                == "/Users/demo/project")
    }

    // T-6201497f F-613
    @Test func ignoresNonDirectoryTargets() {
        #expect(
            resolve(["filetrail", "--folder", "/Users/demo/file.txt"], cwd: "/tmp", isDirectory: { _ in false }) == nil)
    }

    // T-9d38cc4a F-613
    @Test func ignoresMissingFolderTargets() {
        #expect(
            resolve(["filetrail", "--folder", "/Users/demo/missing"], cwd: "/tmp", isDirectory: { _ in false }) == nil)
    }

    // F-644: a relative path is resolved against the working directory the app was launched in
    @Test func resolvesARelativePathAgainstTheWorkingDirectory() {
        #expect(resolve(["filetrail", "../other"], cwd: "/Users/demo/project") == "/Users/demo/other")
        #expect(LaunchContext.resolveWorkingDirectory(envPWD: "/Users/demo", cwd: "") == "/Users/demo")
        #expect(LaunchContext.resolveWorkingDirectory(envPWD: "/Users/demo", cwd: "/tmp") == "/tmp")
    }

    // A real folder passes the check and a file does not.
    @Test func checksTheDiskByDefault() {
        #expect(LaunchContext.isDirectoryOnDisk("/"))
        #expect(!LaunchContext.isDirectoryOnDisk("/etc/hosts"))
        #expect(!LaunchContext.isDirectoryOnDisk("/definitely/not/here"))
    }
}

@Suite struct DescribeOpenedPathTests {
    private func isDirectory(_ path: String) -> Bool? {
        path == "/Users/demo/gone.txt" ? nil : ["/Users/demo/src", "/Users/demo/Backup.sparsebundle"].contains(path)
    }

    // T-670dc520
    @Test func showsAFolderAndShowsAnyOtherItemInItsFolder() {
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/src", isDirectory: isDirectory)
                == OpenRequest(path: "/Users/demo/src", kind: .folder))
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/notes.txt", isDirectory: isDirectory)
                == OpenRequest(path: "/Users/demo/notes.txt", kind: .reveal))
    }

    // T-de619e88
    // B-NAV-231
    @Test func opensADiskImageASparseBundleToo() {
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/Install.dmg", isDirectory: isDirectory)?.kind == .diskImage)
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/Backup.sparsebundle", isDirectory: isDirectory)?.kind
                == .diskImage)
    }

    // T-ec76da29
    // B-NAV-231
    @Test func leavesOutAnItemThatIsNotThere() {
        #expect(LaunchContext.describeOpenedPath("/Users/demo/gone.txt", isDirectory: isDirectory) == nil)
    }
}
