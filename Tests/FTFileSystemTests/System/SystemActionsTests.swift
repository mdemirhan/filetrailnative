import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private struct Refusal: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Stands in for the system: records what it was asked and opens nothing.
private final class FakeSystem: @unchecked Sendable {
    enum Call: Equatable {
        case openPath(String)
        case openWith(String, [String])
        case reveal([String])
        case openURL(String)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var openPathError = ""
    var failure: String?
    var urlFails = false

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    var opener: SystemOpener {
        SystemOpener(
            openPath: { [self] path in
                record(.openPath(path))
                return openPathError
            },
            openWithApplication: { [self] app, paths in
                record(.openWith(app, paths))
                if let failure { throw Refusal(message: failure) }
            },
            reveal: { [self] paths in
                record(.reveal(paths))
                if let failure { throw Refusal(message: failure) }
            },
            openURL: { [self] url in
                record(.openURL(url.absoluteString))
                if urlFails { throw Refusal(message: "no handler") }
            })
    }
}

@Suite struct SystemActionsTests {
    @Test func opensTheItemWithItsDefaultApp() async {
        let system = FakeSystem()
        let result = await SystemActions.openPath("/Users/demo/notes.txt", opener: system.opener)
        #expect(result == .success)
        #expect(system.calls == [.openPath("/Users/demo/notes.txt")])
    }

    @Test func reportsWhyMacOSCouldNotOpenIt() async {
        let system = FakeSystem()
        system.openPathError = "No application knows how to open it."
        let result = await SystemActions.openPath("/Users/demo/data.xyz", opener: system.opener)
        #expect(result == .failure("No application knows how to open it."))
    }

    @Test func opensFullDiskAccessInSystemSettings() async {
        let system = FakeSystem()
        #expect(await SystemActions.openFullDiskAccessSettings(opener: system.opener))
        guard case .openURL(let url) = system.calls.first else {
            Issue.record("nothing was opened")
            return
        }
        #expect(url.contains("Privacy_AllFiles"))
    }

    @Test func saysSoWhenSystemSettingsCantBeOpened() async {
        let system = FakeSystem()
        system.urlFails = true
        #expect(!(await SystemActions.openFullDiskAccessSettings(opener: system.opener)))
    }

    @Test func givesTheSizeAndFreeSpaceOfTheDiskHoldingAFolder() {
        let info = VolumeInfo.sizes(atPath: NSTemporaryDirectory())
        #expect((info.totalBytes ?? 0) > 0)
        #expect((info.availableBytes ?? -1) >= 0)
        #expect((info.availableBytes ?? 0) <= (info.totalBytes ?? 0))
    }

    @Test func givesNothingForAPathThatIsntThere() {
        let info = VolumeInfo.sizes(atPath: NSTemporaryDirectory() + "/missing/folder")
        #expect(info == VolumeInfo.Sizes(availableBytes: nil, totalBytes: nil))
    }

    @MainActor @Test func asksForAnAppInApplicationsAsASheetAndNamesTheOneChosen() async {
        var shownPanel: NSOpenPanel?
        let choice = await SystemPickers.pickApplication(window: nil) { panel, _ in
            shownPanel = panel
            return [URL(fileURLWithPath: "/Applications/Visual Studio Code.app")]
        }
        #expect(
            choice
                == SystemPickers.ApplicationChoice(
                    canceled: false, appPath: "/Applications/Visual Studio Code.app", appName: "Visual Studio Code"))
        #expect(shownPanel?.directoryURL?.path == "/Applications")
        #expect(shownPanel?.canChooseFiles == true)
        #expect(shownPanel?.canChooseDirectories == false)
        #expect(shownPanel?.allowedContentTypes == [.application])
    }

    @MainActor @Test func givesNothingWhenTheDialogIsCancelledOrChoosesNothing() async {
        let canceled = await SystemPickers.pickApplication(window: nil) { _, _ in nil }
        #expect(canceled == SystemPickers.ApplicationChoice(canceled: true, appPath: nil, appName: nil))
        let empty = await SystemPickers.pickApplication(window: nil) { _, _ in [] }
        #expect(empty == SystemPickers.ApplicationChoice(canceled: false, appPath: nil, appName: nil))
    }

    @MainActor @Test func startsAtTheFolderGivenAndReturnsTheOneChosen() async {
        var shownPanel: NSOpenPanel?
        let choice = await SystemPickers.pickDirectory(defaultPath: "/Users/demo", window: nil) { panel, _ in
            shownPanel = panel
            return [URL(fileURLWithPath: "/Users/demo/Work")]
        }
        #expect(choice == SystemPickers.DirectoryChoice(canceled: false, path: "/Users/demo/Work"))
        #expect(shownPanel?.directoryURL?.path == "/Users/demo")
        #expect(shownPanel?.canChooseDirectories == true)
        #expect(shownPanel?.canCreateDirectories == true)
        #expect(shownPanel?.canChooseFiles == false)
    }

    @MainActor @Test func startsWhereverMacOSLikesWithoutAFolderAndGivesNothingWhenCancelled() async {
        var shownPanel: NSOpenPanel?
        let choice = await SystemPickers.pickDirectory(defaultPath: nil, window: nil) { panel, _ in
            shownPanel = panel
            return nil
        }
        #expect(shownPanel != nil)
        #expect(choice == SystemPickers.DirectoryChoice(canceled: true, path: nil))
    }

    @Test func opensTheItemsWithTheApp() async {
        let system = FakeSystem()
        let result = await SystemActions.openPaths(
            ["/Users/demo/a.txt", "/Users/demo/b.txt"], withApplication: "/Applications/Zed.app",
            opener: system.opener)
        #expect(result == .success)
        #expect(system.calls == [.openWith("/Applications/Zed.app", ["/Users/demo/a.txt", "/Users/demo/b.txt"])])
    }

    @Test func revealsTheItemsInFinderWhenFinderIsTheApp() async {
        let system = FakeSystem()
        _ = await SystemActions.openPaths(
            ["/Users/demo/a.txt"], withApplication: "/System/Library/CoreServices/Finder.app", opener: system.opener)
        #expect(system.calls == [.reveal(["/Users/demo/a.txt"])])
    }

    // Revealing an item that is gone fails without showing anything, and names the item, with no command line: no
    // command runs. It stops before Finder is reached.
    @Test func revealingAnItemThatIsGoneFailsNamingIt() async {
        let name = "filetrail-gone-\(UUID().uuidString)"
        let result = await SystemActions.openPaths(
            ["/tmp", "/nonexistent/" + name], withApplication: ApplicationPaths.finderAppPath, opener: .workspace)
        #expect(!result.ok)
        #expect(result.error == "\u{201C}\(name)\u{201D} is no longer there.")
    }

    // A broken link is there to be shown: only the link itself is looked for.
    @Test func aBrokenLinkCanBeRevealed() throws {
        try withTemporaryDirectory(prefix: "filetrail-reveal-link") { root in
            let link = root.path + "/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.path + "/gone")
            #expect(SystemOpener.revealFailure([link]) == nil)
            #expect(SystemOpener.revealFailure([root.path + "/gone"]) == "\u{201C}gone\u{201D} is no longer there.")
        }
    }

    @Test func reportsWhyOpenFailed() async {
        let system = FakeSystem()
        system.failure = "Unable to find application named 'Gone'"
        let result = await SystemActions.openPaths(
            ["/a"], withApplication: "/Applications/Gone.app", opener: system.opener)
        #expect(result == .failure("Unable to find application named 'Gone'"))
    }

    @Test func refusesAnApplicationPathThatIsNotABundleWithoutOpeningAnything() async {
        let system = FakeSystem()
        for path in ["/bin/sh", "Zed.app", "/Applications/../bin/x.app", "  "] {
            let result = await SystemActions.openPaths(["/a"], withApplication: path, opener: system.opener)
            #expect(result == .failure(ApplicationPaths.invalidPathMessage(path)))
        }
        #expect(system.calls.isEmpty)
    }

    // Terminal

    private let terminal = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")

    @Test func opensAFolderItselfInTerminalWhenNoOtherTerminalIsChosen() async throws {
        try await withTemporaryDirectory { folder in
            let system = FakeSystem()
            let result = await SystemActions.openInTerminal(path: folder.path, terminalApp: nil, opener: system.opener)
            #expect(
                result
                    == SystemActions.TerminalResult(
                        ok: true, error: nil, targetPath: folder.path, terminalName: "Terminal"))
            #expect(
                system.calls == [.openWith("/System/Applications/Utilities/Terminal.app", [folder.path])])
        }
    }

    @Test func opensAFilesFolderWithTheChosenTerminal() async throws {
        try await withTemporaryDirectory { folder in
            try Data().write(to: folder.appending("notes.txt"))
            let system = FakeSystem()
            let result = await SystemActions.openInTerminal(
                path: folder.appending("notes.txt").path, terminalApp: terminal, opener: system.opener)
            #expect(result.ok)
            #expect(result.targetPath == folder.path)
            #expect(result.terminalName == "iTerm")
            #expect(system.calls == [.openWith("/Applications/iTerm.app", [folder.path])])
        }
    }

    @Test func opensTheFolderAnItemThatIsGoneWasIn() async {
        let system = FakeSystem()
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo/gone/notes.txt", terminalApp: terminal, opener: system.opener)
        #expect(result.targetPath == "/Users/demo/gone")
    }

    @Test func usesTerminalWhenTheChosenTerminalHasNoPath() async {
        let system = FakeSystem()
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo/gone/notes.txt", terminalApp: ApplicationSelection(appPath: "  ", appName: ""),
            opener: system.opener)
        #expect(result.terminalName == "Terminal")
        #expect(
            system.calls == [.openWith("/System/Applications/Utilities/Terminal.app", ["/Users/demo/gone"])])
    }

    @Test func reportsWhyTheTerminalDidntOpen() async {
        let system = FakeSystem()
        system.failure = "LSOpenURLsWithRole() failed"
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo/gone/a", terminalApp: terminal, opener: system.opener)
        #expect(
            result
                == SystemActions.TerminalResult(
                    ok: false, error: "LSOpenURLsWithRole() failed", targetPath: "/Users/demo/gone",
                    terminalName: "iTerm"))
    }

    // Open With lookups and Always Open With

    private let zed = ApplicationInfo(
        path: "/Applications/Zed.app", name: "Zed", bundleId: "dev.zed.Zed", version: "1")

    @Test func passesOnWhatLaunchServicesSaysThePinnedAppsByThePathsAsked() async {
        let kinds = [OpenWithKind(contentType: "net.daringfireball.markdown", name: "Markdown", isFolder: false)]
        let answer = LaunchServicesAnswer(defaultApp: zed, apps: [zed], kinds: kinds, appInfo: [nil])
        let result = await SystemActions.openWithApplications(
            paths: ["/Users/demo/a.md"], pinnedAppPaths: ["/Applications/Gone.app"],
            lookUp: { paths, appPaths in
                #expect(paths == ["/Users/demo/a.md"])
                #expect(appPaths == ["/Applications/Gone.app"])
                return answer
            })
        #expect(result == OpenWithLookup(defaultApp: zed, apps: [zed], kinds: kinds, pinnedApps: [nil]))
    }

    // The menu still lists the pinned apps that are on disk, and Other….
    @Test func fallsBackToThePinnedAppsFoundOnDiskWhenLaunchServicesCantBeAsked() async {
        let result = await SystemActions.openWithApplications(
            paths: ["/Users/demo/a.md"],
            pinnedAppPaths: ["/Applications/Zed.app", "/Applications/Gone.app", "/etc/passwd"],
            lookUp: { _, _ in throw Refusal(message: "no answer") },
            exists: { $0 != "/Applications/Gone.app" })
        #expect(
            result
                == OpenWithLookup(
                    pinnedApps: [ApplicationInfo(path: "/Applications/Zed.app", name: "Zed"), nil, nil]))
    }

    @Test func setsTheAppForTheKind() async {
        let log = ScriptLog()
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/Applications/Zed.app", contentType: "public.plain-text"
        ) { app, type in log.add("\(app) \(type)") }
        #expect(result == .success)
        #expect(log.sources == ["/Applications/Zed.app public.plain-text"])
    }

    @Test func refusesAPathThatIsntAnAppWithoutAskingMacOS() async {
        let log = ScriptLog()
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/bin/sh", contentType: "public.plain-text"
        ) { app, type in log.add("\(app) \(type)") }
        #expect(!result.ok)
        #expect(log.sources.isEmpty)
    }

    @Test func saysWhyMacOSRefused() async {
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/Applications/Zed.app", contentType: "public.folder"
        ) { _, _ in throw Refusal(message: "Folders, apps and packages keep the app they open in.") }
        #expect(result == .failure("Folders, apps and packages keep the app they open in."))
    }

    @Test func formatsPathsForAShellOnlyWhenTheyHaveWhitespace() {
        #expect(formatPathForShell("/Users/demo/a.txt") == "/Users/demo/a.txt")
        #expect(formatPathForShell("/Users/demo/my file.txt") == "'/Users/demo/my file.txt'")
        #expect(formatPathForShell("/Users/demo/it's here.txt") == "'/Users/demo/it'\\''s here.txt'")
        #expect(formatPathForShell("/tmp/a\tb") == "'/tmp/a\tb'")
    }

    @Test func namesApplicationsByTheirFileName() {
        #expect(ApplicationPaths.displayName("/Applications/Zed.app") == "Zed")
        #expect(ApplicationPaths.displayName("/Applications/Zed.APP/") == "Zed")
        #expect(ApplicationPaths.displayName("/bin/sh") == "sh")
        #expect(ApplicationPaths.isValidBundlePath(" /Applications/Zed.app "))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/../Zed.app"))
        #expect(ApplicationPaths.dirname("/Users/demo/gone/notes.txt") == "/Users/demo/gone")
        #expect(ApplicationPaths.dirname("/notes.txt") == "/")
    }
}
