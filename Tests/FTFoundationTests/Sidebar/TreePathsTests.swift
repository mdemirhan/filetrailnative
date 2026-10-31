// Port of the tree-root cases of apps/desktop/src/renderer/lib/explorerAppUtils.test.ts and the tree helpers of lib/explorerNavigation.ts
import Testing

@testable import FTFoundation

struct TreePathsTests {
    // T-c6941446 F-733
    @Test func rootsTheTreeAtHomeForPathsInsideHome() {
        #expect(
            TreePaths.resolveRootPath(for: "/Users/demo/projects/filetrail", homePath: "/Users/demo") == "/Users/demo")
        #expect(TreePaths.resolveRootPath(for: "/Users/demo", homePath: "/Users/demo") == "/Users/demo")
    }

    // T-7d4e382e
    @Test func rootsTheTreeAtSlashForPathsAboveHome() {
        #expect(TreePaths.resolveRootPath(for: "/Users", homePath: "/Users/demo") == "/")
        #expect(TreePaths.resolveRootPath(for: "/Applications", homePath: "/Users/demo") == "/")
        // Without a known home, everything is on the startup disk.
        #expect(TreePaths.resolveRootPath(for: "/Users/demo", homePath: "") == "/")
    }

    // T-52453124
    @Test func rootsTheTreeAtTheDiskForAFolderOnAnotherDisk() {
        #expect(
            TreePaths.resolveRootPath(for: "/Volumes/Backup/Photos", homePath: "/Users/demo") == "/Volumes/Backup")
        #expect(TreePaths.resolveRootPath(for: "/Volumes/Backup", homePath: "/Users/demo") == "/Volumes/Backup")
        // /Volumes itself is a folder of Macintosh HD.
        #expect(TreePaths.resolveRootPath(for: "/Volumes", homePath: "/Users/demo") == "/")
    }

    // T-3cb0cb67
    // B-NAV-097 B-TREE-074
    @Test func keepsOtherDisksOutOfATreeRootedAtMacintoshHD() {
        #expect(TreePaths.isWithinTreeRoot("/Applications/Utilities", "/"))
        #expect(TreePaths.isWithinTreeRoot("/Volumes", "/"))
        #expect(!TreePaths.isWithinTreeRoot("/Volumes/Backup/Photos", "/"))
        // A tree rooted on a disk, or at /Volumes by hand, holds what is inside it.
        #expect(TreePaths.isWithinTreeRoot("/Volumes/Backup/Photos", "/Volumes/Backup"))
        #expect(TreePaths.isWithinTreeRoot("/Volumes/Backup/Photos", "/Volumes"))
        #expect(!TreePaths.isWithinTreeRoot("/Volumes/Backup 2", "/Volumes/Backup"))
    }

    @Test func buildsTheChainFromTheRootDownToAPath() {
        #expect(
            TreePaths.ancestorChain(from: "/Users/demo", to: "/Users/demo/a/b") == [
                "/Users/demo", "/Users/demo/a", "/Users/demo/a/b",
            ])
        #expect(TreePaths.ancestorChain(from: "/Users/demo", to: "/Users/demo") == ["/Users/demo"])
        // Outside the root: just the root.
        #expect(TreePaths.ancestorChain(from: "/Users/demo", to: "/etc") == ["/Users/demo"])
        #expect(TreePaths.ancestorChain(from: "/", to: "/a") == ["/", "/a"])
        let seed = TreePaths.seedChain(from: "/", to: "/a/b")
        #expect(seed.map(\.path) == ["/", "/a", "/a/b"])
        #expect(seed.map(\.childPath) == ["/a", "/a/b", nil])
    }

    // T-431cfb70 T-56d4103f B-TREE-084
    @Test func keepsTheOneHiddenChildOnTheWayToTheFolderOnScreen() {
        #expect(
            TreePaths.forcedVisibleHiddenChild(of: "/Users/demo", activePath: "/Users/demo/.config/app")
                == "/Users/demo/.config")
        #expect(
            TreePaths.forcedVisibleHiddenChild(of: "/Users/demo/.config", activePath: "/Users/demo/.config/app")
                == nil)
        #expect(TreePaths.forcedVisibleHiddenChild(of: "/Users/demo", activePath: "/Users/demo/src") == nil)
        #expect(TreePaths.forcedVisibleHiddenChild(of: "/", activePath: "/.hidden/a") == "/.hidden")
        #expect(TreePaths.hasHiddenSegment("/Users/demo/.Trash", withinRoot: "/Users/demo"))
        #expect(!TreePaths.hasHiddenSegment("/Users/demo/src", withinRoot: "/Users/demo"))
        #expect(TreePaths.hasHiddenSegment("/Users/demo/.x", withinRoot: "/Users/demo/.x"))
        #expect(!TreePaths.hasHiddenSegment("/etc/.x", withinRoot: "/Users/demo"))
    }

    // T-223415d5 T-4becddde T-38c52395 B-TREE-085
    @Test func addsAnOpenPackageToItsParentsChildrenInNameOrder() {
        #expect(
            TreePaths.forcedVisiblePackageChild(of: "/Applications", activePath: "/Applications/Safari.app/Contents")
                == "/Applications/Safari.app")
        #expect(
            TreePaths.forcedVisiblePackageChild(
                of: "/Applications/Safari.app", activePath: "/Applications/Safari.app/Contents") == nil)
        #expect(
            TreePaths.forcedVisiblePackageChild(of: "/Applications", activePath: "/Applications/Utilities") == nil)
        let children = [
            TreePaths.Child(path: "/Applications/Alpha", name: "Alpha", isHidden: false, isSymlink: false),
            TreePaths.Child(path: "/Applications/Zed", name: "Zed", isHidden: false, isSymlink: false),
        ]
        let withApp = TreePaths.withPackageChild(children, packagePath: "/Applications/Mail.app")
        #expect(withApp.map(\.name) == ["Alpha", "Mail.app", "Zed"])
        #expect(TreePaths.withPackageChild(withApp, packagePath: "/Applications/Mail.app") == withApp)
        #expect(
            TreePaths.withPackageChild(children, packagePath: "/Applications/Zz.app").map(\.name) == [
                "Alpha", "Zed", "Zz.app",
            ])
    }

    @Test func namesTheVolumeAPathIsOn() {
        #expect(TreePaths.volumeRootPath("/Volumes/Backup/Photos") == "/Volumes/Backup")
        #expect(TreePaths.volumeRootPath("/Volumes/") == "/")
        #expect(TreePaths.volumeRootPath("/VolumesX/y") == "/")
        #expect(TreePaths.volumeRootPath("/Users/x/Volumes/y") == "/")
    }
}
