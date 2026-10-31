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
    // T-be8cc88a F-222
    @Test func opensTheItemWithItsDefaultApp() async {
        let system = FakeSystem()
        let result = await SystemActions.openPath("/Users/demo/notes.txt", opener: system.opener)
        #expect(result == .success)
        #expect(system.calls == [.openPath("/Users/demo/notes.txt")])
    }

    // T-01fe1dde F-222
    @Test func reportsWhyMacOSCouldNotOpenIt() async {
        let system = FakeSystem()
        system.openPathError = "No application knows how to open it."
        let result = await SystemActions.openPath("/Users/demo/data.xyz", opener: system.opener)
        #expect(result == .failure("No application knows how to open it."))
    }

    // T-5f2b0f35 F-146 F-233
    @Test func opensFullDiskAccessInSystemSettings() async {
        let system = FakeSystem()
        #expect(await SystemActions.openFullDiskAccessSettings(opener: system.opener))
        guard case .openURL(let url) = system.calls.first else {
            Issue.record("nothing was opened")
            return
        }
        #expect(url.contains("Privacy_AllFiles"))
    }

    // T-dbd335e1
    @Test func saysSoWhenSystemSettingsCantBeOpened() async {
        let system = FakeSystem()
        system.urlFails = true
        #expect(!(await SystemActions.openFullDiskAccessSettings(opener: system.opener)))
    }

    // T-fcd013e1 F-144 F-209
    @Test func givesTheSizeAndFreeSpaceOfTheDiskHoldingAFolder() {
        let info = VolumeInfo.sizes(atPath: NSTemporaryDirectory())
        #expect((info.totalBytes ?? 0) > 0)
        #expect((info.availableBytes ?? -1) >= 0)
        #expect((info.availableBytes ?? 0) <= (info.totalBytes ?? 0))
    }

    // T-75004506
    @Test func givesNothingForAPathThatIsntThere() {
        let info = VolumeInfo.sizes(atPath: NSTemporaryDirectory() + "/missing/folder")
        #expect(info == VolumeInfo.Sizes(availableBytes: nil, totalBytes: nil))
    }

    // N/A T-0715c3bb T-df2126ce Quick Look is the Quick Look panel's work (QLPreviewPanel), not this package's.

    // T-f66c763b
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

    // T-2becde4d
    @MainActor @Test func givesNothingWhenTheDialogIsCancelledOrChoosesNothing() async {
        let canceled = await SystemPickers.pickApplication(window: nil) { _, _ in nil }
        #expect(canceled == SystemPickers.ApplicationChoice(canceled: true, appPath: nil, appName: nil))
        let empty = await SystemPickers.pickApplication(window: nil) { _, _ in [] }
        #expect(empty == SystemPickers.ApplicationChoice(canceled: false, appPath: nil, appName: nil))
    }

    // T-59ea1dc4
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

    // T-1c3615ca
    @MainActor @Test func startsWhereverMacOSLikesWithoutAFolderAndGivesNothingWhenCancelled() async {
        var shownPanel: NSOpenPanel?
        let choice = await SystemPickers.pickDirectory(defaultPath: nil, window: nil) { panel, _ in
            shownPanel = panel
            return nil
        }
        #expect(choice == SystemPickers.DirectoryChoice(canceled: true, path: nil))
    }

    // T-fbe12d69 T-d88d425e F-221
    @Test func opensTheItemsWithTheApp() async {
        let system = FakeSystem()
        let result = await SystemActions.openPaths(
            ["/Users/demo/a.txt", "/Users/demo/b.txt"], withApplication: "/Applications/Zed.app",
            opener: system.opener)
        #expect(result == .success)
        #expect(system.calls == [.openWith("/Applications/Zed.app", ["/Users/demo/a.txt", "/Users/demo/b.txt"])])
    }

    // T-46f29828 T-1b7582f5 F-221 F-230
    @Test func revealsTheItemsInFinderWhenFinderIsTheApp() async {
        let system = FakeSystem()
        _ = await SystemActions.openPaths(
            ["/Users/demo/a.txt"], withApplication: "/System/Library/CoreServices/Finder.app", opener: system.opener)
        #expect(system.calls == [.reveal(["/Users/demo/a.txt"])])
    }

    // `open -R` of an item that is gone fails without showing anything, and says so as Node does: Show in Finder tells
    // of it. It stops before Finder is reached.
    @Test func revealingAnItemThatIsGoneFailsAsOpenDoes() async {
        let gone = "/nonexistent/filetrail-gone-\(UUID().uuidString)"
        let result = await SystemActions.openPaths(
            ["/tmp", gone], withApplication: ApplicationPaths.finderAppPath, opener: .workspace)
        #expect(!result.ok)
        #expect(result.error == "Command failed: open -R /tmp \(gone)\nThe file \(gone) does not exist.\n")
    }

    // T-17013eb6 T-ac8a9c09
    @Test func reportsWhyOpenFailed() async {
        let system = FakeSystem()
        system.failure = "Unable to find application named 'Gone'"
        let result = await SystemActions.openPaths(
            ["/a"], withApplication: "/Applications/Gone.app", opener: system.opener)
        #expect(result == .failure("Unable to find application named 'Gone'"))
    }

    // T-cd79ef68 T-58a29428 F-221
    @Test func refusesAnApplicationPathThatIsNotABundleWithoutOpeningAnything() async {
        let system = FakeSystem()
        for path in ["/bin/sh", "Zed.app", "/Applications/../bin/x.app", "  "] {
            let result = await SystemActions.openPaths(["/a"], withApplication: path, opener: system.opener)
            #expect(result == .failure(ApplicationPaths.invalidPathMessage(path)))
        }
        #expect(system.calls.isEmpty)
    }

    // F-229
    @Test func editsInTheTextEditor() async {
        let system = FakeSystem()
        _ = await SystemActions.editInTextEditor(
            path: "/Users/demo/a.txt", editor: AppPreferenceLimits.defaultTextEditor, opener: system.opener)
        #expect(system.calls == [.openWith("/System/Applications/TextEdit.app", ["/Users/demo/a.txt"])])
    }

    // Terminal

    private let terminal = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")

    // T-64c3e418 F-228
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

    // T-ec032101 F-228
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

    // T-6070e895 F-228
    @Test func opensTheFolderAnItemThatIsGoneWasIn() async {
        let system = FakeSystem()
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo/gone/notes.txt", terminalApp: terminal, opener: system.opener)
        #expect(result.targetPath == "/Users/demo/gone")
    }

    // T-7cc2e265
    @Test func usesTerminalWhenTheChosenTerminalHasNoPath() async {
        let system = FakeSystem()
        let result = await SystemActions.openInTerminal(
            path: "/Users/demo/gone/notes.txt", terminalApp: ApplicationSelection(appPath: "  ", appName: ""),
            opener: system.opener)
        #expect(result.terminalName == "Terminal")
        #expect(
            system.calls == [.openWith("/System/Applications/Utilities/Terminal.app", ["/Users/demo/gone"])])
    }

    // T-a5abde8c
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

    // T-06f6f204 F-219
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
    // T-f3ae0d7b F-219
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

    // T-84ba4eba F-162
    @Test func setsTheAppForTheKind() async {
        let log = ScriptLog()
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/Applications/Zed.app", contentType: "public.plain-text"
        ) { app, type in log.add("\(app) \(type)") }
        #expect(result == .success)
        #expect(log.sources == ["/Applications/Zed.app public.plain-text"])
    }

    // T-afd480ac
    @Test func refusesAPathThatIsntAnAppWithoutAskingMacOS() async {
        let log = ScriptLog()
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/bin/sh", contentType: "public.plain-text"
        ) { app, type in log.add("\(app) \(type)") }
        #expect(!result.ok)
        #expect(log.sources.isEmpty)
    }

    // T-d40dd022 F-162
    @Test func saysWhyMacOSRefused() async {
        let result = await SystemActions.setDefaultApplication(
            applicationPath: "/Applications/Zed.app", contentType: "public.folder"
        ) { _, _ in throw Refusal(message: "Folders, apps and packages keep the app they open in.") }
        #expect(result == .failure("Folders, apps and packages keep the app they open in."))
    }

    // B-INFO-057
    @Test func formatsPathsForAShellOnlyWhenTheyHaveWhitespace() {
        #expect(formatPathForShell("/Users/demo/a.txt") == "/Users/demo/a.txt")
        #expect(formatPathForShell("/Users/demo/my file.txt") == "'/Users/demo/my file.txt'")
        #expect(formatPathForShell("/Users/demo/it's here.txt") == "'/Users/demo/it'\\''s here.txt'")
        #expect(formatPathForShell("/tmp/a\tb") == "'/tmp/a\tb'")
    }

    @Test func namesApplicationsLikeTheOriginal() {
        #expect(ApplicationPaths.displayName("/Applications/Zed.app") == "Zed")
        #expect(ApplicationPaths.displayName("/Applications/Zed.APP/") == "Zed")
        #expect(ApplicationPaths.displayName("/bin/sh") == "sh")
        #expect(ApplicationPaths.isValidBundlePath(" /Applications/Zed.app "))
        #expect(!ApplicationPaths.isValidBundlePath("/Applications/../Zed.app"))
        #expect(ApplicationPaths.dirname("/Users/demo/gone/notes.txt") == "/Users/demo/gone")
        #expect(ApplicationPaths.dirname("/notes.txt") == "/")
    }
}

private final class ScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func add(_ source: String) {
        lock.lock()
        recorded.append(source)
        lock.unlock()
    }
}
