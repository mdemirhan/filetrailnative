import FTFoundation
import Testing

@testable import FTFileSystem

private func app(_ name: String, _ version: String? = "1.0", path: String? = nil) -> ApplicationInfo {
    ApplicationInfo(path: path ?? "/Applications/\(name).app", name: name, bundleId: nil, version: version)
}

private func pin(_ name: String, path: String? = nil) -> OpenWithApplication {
    OpenWithApplication(id: name.lowercased(), appPath: path ?? "/Applications/\(name).app", appName: name)
}

private let markdown = OpenWithKind(contentType: "net.daringfireball.markdown", name: "Markdown", isFolder: false)

private func lookup(
    defaultApp: ApplicationInfo? = nil, apps: [ApplicationInfo] = [], kinds: [OpenWithKind]? = nil,
    pinnedApps: [ApplicationInfo?] = []
) -> OpenWithLookup {
    OpenWithLookup(defaultApp: defaultApp, apps: apps, kinds: kinds ?? [markdown], pinnedApps: pinnedApps)
}

/// The menu as its rows read: labels, and "---" for a separator.
private func rows(_ items: [OpenWithMenuItem]) -> [String] {
    items.map {
        switch $0 {
        case .separator: "---"
        case .action(let action): action.label
        }
    }
}

@Suite struct OpenWithMenuTests {
    // T-5f17a80b
    @Test func listsTheDefaultAppThePinnedAppsThenTheOthersAToZThenOther() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(
                defaultApp: app("Typora"),
                apps: [
                    app("Xcode"), app("Typora"), app("Zed"), app("obsidian"), app("Visual Studio Code"),
                    app("TextEdit"),
                ],
                pinnedApps: [app("Zed"), app("Visual Studio Code")]),
            pinned: [pin("Zed"), pin("Visual Studio Code")])
        #expect(
            rows(items) == [
                "Typora (default)", "---", "Zed", "Visual Studio Code", "---", "obsidian", "TextEdit", "Xcode", "---",
                "Other…",
            ])
    }

    // T-0245a437
    @Test func listsAnAppOnceInItsFirstPlace() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(
                defaultApp: app("Zed"),
                apps: [app("Zed"), app("Visual Studio Code", "1.0", path: "/Applications/Visual Studio Code.app/")],
                pinnedApps: [app("Zed"), app("Visual Studio Code")]),
            pinned: [pin("Zed"), pin("Visual Studio Code")])
        #expect(rows(items) == ["Zed (default)", "---", "Visual Studio Code", "---", "Other…"])
    }

    // T-e67751b5
    @Test func leavesOutPinnedAppsThatArentThereAnyMore() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(apps: [app("Zed")], pinnedApps: [nil, app("Zed")]), pinned: [pin("Gone"), pin("Zed")])
        #expect(rows(items) == ["Zed", "---", "Other…"])
    }

    // T-7946a6da
    @Test func listsThePinnedAppsAsSavedUntilMacOSAnswers() {
        #expect(rows(OpenWithMenu.menuItems(lookup: nil, pinned: [pin("Zed")])) == ["Zed", "---", "Other…"])
    }

    // T-2f76c93c
    @Test func ignoresPinnedAnswersAskedWithADifferentList() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(apps: [app("Zed"), app("Nova")], pinnedApps: [nil]), pinned: [pin("Zed"), pin("Nova")])
        #expect(rows(items) == ["Zed", "Nova", "---", "Other…"])
    }

    // T-f63e4a78
    @Test func leavesOutPinnedAppsThatCantOpenTheItems() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(
                defaultApp: app("DiskImageMounter"), apps: [app("DiskImageMounter"), app("Zed")],
                pinnedApps: [app("Visual Studio Code"), app("Zed")]),
            pinned: [pin("Visual Studio Code"), pin("Zed")])
        #expect(rows(items) == ["DiskImageMounter (default)", "---", "Zed", "---", "Other…"])
    }

    // T-251d631b
    @Test func listsAPinnedAppWhereItIsWhenMacOSOffersAnotherCopyOfIt() {
        var zed = app("Zed")
        zed.bundleId = "dev.zed.Zed"
        var pinnedZed = zed
        pinnedZed.path = "/Users/demo/Applications/Zed.app"
        let items = OpenWithMenu.menuItems(
            lookup: lookup(apps: [zed], pinnedApps: [pinnedZed]), pinned: [pin("Zed", path: pinnedZed.path)])
        #expect(rows(items) == ["Zed", "---", "Other…"])
        guard case .action(.application(_, _, let appPath, _, _)) = items[0] else {
            Issue.record("the first row is not an app")
            return
        }
        #expect(appPath == "/Users/demo/Applications/Zed.app")
    }

    // T-c93f786f
    @Test func listsEveryPinnedAppWhenMacOSCouldntSayWhatOpensTheItems() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(kinds: [], pinnedApps: [app("Zed")]), pinned: [pin("Zed")])
        #expect(rows(items) == ["Zed", "---", "Other…"])
    }

    // T-b7368b6a
    @Test func listsTwoCopiesOfOneVersionOfAnAppOnceTheOneMacOSPutsFirst() {
        func fileTrail(_ path: String, _ version: String) -> ApplicationInfo {
            ApplicationInfo(path: path, name: "File Trail", bundleId: "com.filetrail.app", version: version)
        }
        let items = OpenWithMenu.menuItems(
            lookup: lookup(apps: [
                fileTrail("/Applications/File Trail.app", "0.6.1"),
                fileTrail("/Users/demo/src/filetrail/out/File Trail.app", "0.6.1"),
                fileTrail("/Users/demo/Downloads/File Trail.app", "0.5.0"),
            ]), pinned: [])
        #expect(rows(items) == ["File Trail (0.6.1)", "File Trail (0.5.0)", "---", "Other…"])
        guard case .action(.application(_, _, let appPath, _, _)) = items[0] else {
            Issue.record("the first row is not an app")
            return
        }
        #expect(appPath == "/Applications/File Trail.app")
    }

    // T-7ce97c4c
    @Test func offersOnlyOtherWhenThereIsNothingElse() {
        #expect(rows(OpenWithMenu.menuItems(lookup: lookup(), pinned: [])) == ["Other…"])
    }

    // T-4e421ac1
    @Test func addsTheVersionToAppsThatShareAName() {
        let items = OpenWithMenu.menuItems(
            lookup: lookup(
                defaultApp: app("Xcode", "26.0"),
                apps: [
                    app("Xcode", "26.0"), app("Xcode", "27.0 beta", path: "/Applications/Xcode-beta.app"),
                    app("Preview"),
                ]),
            pinned: [])
        #expect(
            rows(items) == ["Xcode (26.0) (default)", "---", "Preview", "Xcode (27.0 beta)", "---", "Other…"])
    }

    // T-28f23718
    @Test func opensEachAppByItsPathAndNameAndMarksEveryChoiceWhenItIsForAlways() {
        let items = OpenWithMenu.menuItems(lookup: lookup(defaultApp: app("Zed")), pinned: [], always: true)
        let actions = items.compactMap { item -> OpenWithAction? in
            if case .action(let action) = item { return action }
            return nil
        }
        #expect(
            actions == [
                .application(
                    id: "app:/Applications/Zed.app", label: "Zed (default)", appPath: "/Applications/Zed.app",
                    appName: "Zed", always: true),
                .other(id: "other", label: "Other…", appName: "Other…", always: true),
            ])
    }

    // T-97bb29ee
    @Test func alwaysOpenWithIsForItemsOfOneKindOfFile() {
        #expect(OpenWithMenu.canAlwaysOpenWith(lookup()))
    }

    // T-11281420
    @Test func alwaysOpenWithIsNotForFoldersPackagesOrApps() {
        let folder = OpenWithKind(contentType: "public.folder", name: "Folder", isFolder: true)
        #expect(!OpenWithMenu.canAlwaysOpenWith(lookup(kinds: [folder])))
    }

    // T-2015fc33
    @Test func alwaysOpenWithIsNotForSeveralKindsOrBeforeMacOSAnswers() {
        let text = OpenWithKind(contentType: "public.plain-text", name: "Plain Text", isFolder: false)
        #expect(!OpenWithMenu.canAlwaysOpenWith(lookup(kinds: [markdown, text])))
        #expect(!OpenWithMenu.canAlwaysOpenWith(nil))
    }
}
