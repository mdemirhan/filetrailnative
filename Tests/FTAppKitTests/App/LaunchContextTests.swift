import FTFileSystem
import Testing

@testable import FTAppKit

@Suite struct LaunchContextTests {
    private func resolve(
        _ argv: [String], cwd: String, home: String = "/Users/demo", appPath: String? = nil,
        isDirectory: @escaping (String) -> Bool = { _ in true }
    ) -> String? {
        LaunchContext.resolveStartupFolderPath(
            argv: argv, cwd: cwd, homePath: home, appPath: appPath, isDirectory: isDirectory)
    }

    @Test func readsAnExplicitFolderPath() {
        #expect(resolve(["--folder", "/Users/demo/project"], cwd: "/tmp") == "/Users/demo/project")
    }

    @Test func readsAnInlineFolderPath() {
        #expect(resolve(["--folder=projects/filetrail"], cwd: "/Users/demo") == "/Users/demo/projects/filetrail")
    }

    @Test func usesAPositionalFolderArgumentWhenFolderIsNotProvided() {
        #expect(resolve(["/Users/demo/src"], cwd: "/tmp") == "/Users/demo/src")
    }

    @Test func doesNotTreatTheAppPathItselfAsAStartupFolder() {
        #expect(
            resolve(["/Applications/File Trail.app"], cwd: "/tmp", appPath: "/Applications/File Trail.app") == nil)
    }

    @Test func expandsTildePrefixedFolderArguments() {
        #expect(resolve(["~/src"], cwd: "/tmp") == "/Users/demo/src")
        #expect(resolve(["~"], cwd: "/tmp") == "/Users/demo")
    }

    @Test func prefersFolderOverAPositionalFolderArgument() {
        #expect(
            resolve(
                ["/Users/demo/ignored", "--folder", "/Users/demo/project"], cwd: "/tmp",
                isDirectory: { $0 == "/Users/demo/project" }) == "/Users/demo/project")
    }

    // A file, or nothing there: both answer no.
    @Test func ignoresNonDirectoryTargets() {
        #expect(resolve(["--folder", "/Users/demo/file.txt"], cwd: "/tmp", isDirectory: { _ in false }) == nil)
    }

    // A relative path is resolved against the working directory the app was launched in
    @Test func resolvesARelativePathAgainstTheWorkingDirectory() {
        #expect(resolve(["../other"], cwd: "/Users/demo/project") == "/Users/demo/other")
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

    @Test func showsAFolderAndShowsAnyOtherItemInItsFolder() {
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/src", isDirectory: isDirectory)
                == OpenRequest(path: "/Users/demo/src", kind: .folder))
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/notes.txt", isDirectory: isDirectory)
                == OpenRequest(path: "/Users/demo/notes.txt", kind: .reveal))
    }

    @Test func opensADiskImageASparseBundleToo() {
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/Install.dmg", isDirectory: isDirectory)?.kind == .diskImage)
        #expect(
            LaunchContext.describeOpenedPath("/Users/demo/Backup.sparsebundle", isDirectory: isDirectory)?.kind
                == .diskImage)
    }

    @Test func leavesOutAnItemThatIsNotThere() {
        #expect(LaunchContext.describeOpenedPath("/Users/demo/gone.txt", isDirectory: isDirectory) == nil)
    }
}
