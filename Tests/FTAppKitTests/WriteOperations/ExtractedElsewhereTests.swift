// What an Extract made where no pane shows it: one tab for each folder it went into, everything made there selected
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ExtractedOpeningsTests {
    private func described(_ openings: [(path: String, item: OpenedItem)]) -> [String] {
        openings.map { opening in
            switch opening.item {
            case .folder: "\(opening.path) on itself"
            case .selecting(let paths), .made(let paths): "\(opening.path) selecting \(paths.joined(separator: ", "))"
            }
        }
    }

    @Test func whatWentIntoOneFolderOpensItOnceWithAllOfItSelected() {
        let made = (0..<10).map { "/Out/file\($0).txt" }
        let openings = MainWindowController.extractedOpenings(
            made, isFolder: Array(repeating: false, count: 10), shown: ["/Elsewhere"])
        #expect(described(openings) == ["/Out selecting \(made.joined(separator: ", "))"])
    }

    @Test func aFolderAloneInItsFolderOpensOnItselfAndSeveralOpenTheirFolder() {
        let openings = MainWindowController.extractedOpenings(
            ["/A/Photos", "/B/Photos", "/B/notes.txt", "/C/one.txt"], isFolder: [true, true, false, false], shown: [])
        #expect(
            described(openings) == [
                "/A/Photos on itself", "/B selecting /B/Photos, /B/notes.txt", "/C selecting /C/one.txt",
            ])
    }

    @Test func aFolderAPaneShowsOpensNothing() {
        let openings = MainWindowController.extractedOpenings(
            ["/A/one.txt", "/B/two.txt", "/A/three.txt"], isFolder: [false, false, false], shown: ["/A"])
        #expect(described(openings) == ["/B selecting /B/two.txt"])
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ExtractedElsewhereTests {
        /// The zips `names` in `folder`, each holding one file named after it ("a.zip" holds "a.txt").
        private func zips(_ names: [String], in folder: URL) throws -> [String] {
            let source = try TemporaryDirectory(prefix: "filetrail-zips")
            defer { source.remove() }
            return try names.map { name in
                let file = "\(source.path)/\(name).txt"
                try Data(name.utf8).write(to: URL(fileURLWithPath: file))
                let zip = folder.appendingPathComponent("\(name).zip").path
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.arguments = ["-q", "-j", zip, file]
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
                return zip
            }
        }

        @Test func tenArchivesExtractedToAFolderNoPaneShowsOpenItOnceWithAllOfThemSelected() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let group = try #require(tab.group)
            tab.updatePreferences { $0.diskImageOpensIn = .tab }
            let out = window.folder.appendingPathComponent("Out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            let names = (0..<10).map { "archive\($0)" }
            let archives = try zips(names, in: window.folder)

            _ = await tab.writeActions?.extract(archives, into: out.path)

            #expect(await waitUntil { group.tabs.count == 2 })
            let opened = try #require(group.tabs.first { $0 !== tab })
            #expect(await waitUntil { opened.content.selection.paths.count == 10 })
            #expect(opened.shownFolderPath == out.path)
            #expect(Set(opened.content.selection.paths.map(NodePath.basename)) == Set(names.map { "\($0).txt" }))
            // Nothing else opens later.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(group.tabs.count == 2)
            await window.close()
        }

        @Test func archivesFromSearchResultsOpenATabForEachOfTheirFolders() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let group = try #require(tab.group)
            tab.updatePreferences { $0.diskImageOpensIn = .tab }
            let alpha = window.folder.appendingPathComponent("Alpha")
            let beta = window.folder.appendingPathComponent("Beta")
            let archives = try zips(["a", "c"], in: alpha) + zips(["b"], in: beta)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["Alpha/a.zip", "Alpha/c.zip", "Beta/b.zip"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "zip"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.searchRootPath != nil && tab.content.entries.count == 3 })

            _ = await tab.writeActions?.extract(archives)

            #expect(await waitUntil { group.tabs.count == 3 })
            let opened = group.tabs.filter { $0 !== tab }
            #expect(await waitUntil { opened.allSatisfy { !$0.content.selection.paths.isEmpty } })
            let shown = opened.map { tab in
                let selected = tab.content.selection.paths.map(NodePath.basename).sorted()
                return "\(NodePath.basename(tab.shownFolderPath)): \(selected.joined(separator: ", "))"
            }
            #expect(Set(shown) == ["Alpha: a.txt, c.txt", "Beta: b.txt"])
            await window.close()
        }
    }
}
