import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct OpenWithCatalogTests {
    // T-aa694d34 F-159
    @Test func listsTheAppsThatCanOpenATextFileWithItsDefaultAmongThem() throws {
        try withTemporaryDirectory { root in
            let file = root.appending("notes.txt")
            try Data("hello".utf8).write(to: file)
            let result = OpenWithCatalog().lookup(paths: [file.path], appPaths: [])

            #expect(result.kinds.count == 1)
            #expect(result.kinds.first?.contentType == "public.plain-text")
            #expect(result.kinds.first?.name != nil)
            #expect(result.kinds.first?.isFolder == false)
            // TextEdit ships with every Mac and opens plain text.
            #expect(result.apps.map(\.bundleId).contains("com.apple.TextEdit"))
            let defaultApp = try #require(result.defaultApp)
            #expect(result.apps.map(\.path).contains(defaultApp.path))
            #expect(!defaultApp.path.hasSuffix("/"))
            #expect(!defaultApp.name.hasSuffix(".app"))
        }
    }

    // T-b871585b F-160
    @Test func namesAFoldersKindAsAFolder() throws {
        try withTemporaryDirectory { root in
            let result = OpenWithCatalog().lookup(paths: [root.path], appPaths: [])
            #expect(result.kinds.count == 1)
            #expect(result.kinds.first?.contentType == "public.folder")
            #expect(result.kinds.first?.isFolder == true)
        }
    }

    // T-3c7c48b6 F-159 F-160
    @Test func givesTheKindsOfAMixedSelectionOnceEach() throws {
        try withTemporaryDirectory { root in
            try Data("a".utf8).write(to: root.appending("a.txt"))
            try Data("b".utf8).write(to: root.appending("b.txt"))
            try FileManager.default.createDirectory(at: root.appending("folder"), withIntermediateDirectories: false)
            let result = OpenWithCatalog().lookup(
                paths: [root.appending("a.txt").path, root.appending("b.txt").path, root.appending("folder").path],
                appPaths: [])
            #expect(result.kinds.map(\.contentType) == ["public.plain-text", "public.folder"])
        }
    }

    // T-ab55d846 F-160
    @Test func describesTheAppsAtThePathsGivenAndNilWhereThereIsNone() throws {
        try withTemporaryDirectory { root in
            let result = OpenWithCatalog().lookup(
                paths: [], appPaths: ["/System/Applications/TextEdit.app", root.appending("Missing.app").path])
            #expect(result.defaultApp == nil)
            #expect(result.apps.isEmpty)
            #expect(result.kinds.isEmpty)
            #expect(result.appInfo.count == 2)
            let textEdit = try #require(result.appInfo[0])
            #expect(textEdit.path == "/System/Applications/TextEdit.app")
            #expect(textEdit.name == "TextEdit")
            #expect(textEdit.bundleId == "com.apple.TextEdit")
            #expect(textEdit.version != nil)
            #expect(result.appInfo[1] == nil)
        }
    }

    // What is known about an app is kept until forgotten: an app that appears where there was none shows only after
    // the cache is cleared, as when the window comes forward.
    // T-58c256e9 F-161
    @Test func remembersAnAppPathUntilTheCacheIsForgotten() throws {
        try withTemporaryDirectory { root in
            let catalog = OpenWithCatalog()
            let appPath = root.appending("Later.app").path
            #expect(catalog.lookup(paths: [], appPaths: [appPath]).appInfo == [nil])

            try FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: false)
            #expect(catalog.lookup(paths: [], appPaths: [appPath]).appInfo == [nil])

            catalog.forget()
            let info = try #require(catalog.lookup(paths: [], appPaths: [appPath]).appInfo.first ?? nil)
            #expect(info.path == appPath)
            #expect(info.name == "Later")
        }
    }

    // bootstrap.ts:173-175: what the app reads is forgotten when a window comes forward, so an app installed while File
    // Trail was in the background shows.
    // Its own center: AppKit's views listen on the default one, and a test isn't on the main thread (a bundle crash).
    @Test func theAppsCatalogForgetsWhenAWindowComesForward() throws {
        try withTemporaryDirectory { root in
            let center = NotificationCenter()
            let catalog = OpenWithCatalog()
            catalog.forgetsWhenAWindowComesForward(center: center)
            let appPath = root.appending("Later.app").path
            #expect(catalog.lookup(paths: [], appPaths: [appPath]).appInfo == [nil])
            try FileManager.default.createDirectory(atPath: appPath, withIntermediateDirectories: false)
            #expect(catalog.lookup(paths: [], appPaths: [appPath]).appInfo == [nil])

            center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
            let info = try #require(catalog.lookup(paths: [], appPaths: [appPath]).appInfo.first ?? nil)
            #expect(info.name == "Later")
        }
    }

    // T-03b1f32f F-161
    @Test func answersTheSameForATypeAskedAboutAgainRememberedOrNot() throws {
        try withTemporaryDirectory { root in
            try Data("a".utf8).write(to: root.appending("a.txt"))
            try Data("b".utf8).write(to: root.appending("b.txt"))
            let catalog = OpenWithCatalog()
            let first = catalog.lookup(paths: [root.appending("a.txt").path], appPaths: [])
            let remembered = catalog.lookup(paths: [root.appending("b.txt").path], appPaths: [])
            catalog.forget()
            let askedAgain = catalog.lookup(paths: [root.appending("b.txt").path], appPaths: [])
            #expect(remembered == first)
            #expect(askedAgain == first)
        }
    }

    // Only refusals are tried, each with an app that isn't there: a change would reach every app on the Mac
    // running the tests.
    private let missingApp = "/Applications/File Trail Test Missing.app"

    // T-ace2aac0 F-162
    @Test func refusesToChangeWhatOpensFolders() async {
        let error = await #expect(throws: OpenWithCatalog.SetDefaultFailure.self) {
            try await OpenWithCatalog().setDefaultApplication(appPath: missingApp, contentType: "public.folder")
        }
        #expect(error?.message == "Folders, apps and packages keep the app they open in.")
    }

    // T-b682efab F-162
    @Test func refusesAKindMacOSDoesntKnow() async {
        let error = await #expect(throws: OpenWithCatalog.SetDefaultFailure.self) {
            try await OpenWithCatalog().setDefaultApplication(appPath: missingApp, contentType: "")
        }
        #expect(error?.message == "That kind of file isn't known to macOS.")
    }
}
