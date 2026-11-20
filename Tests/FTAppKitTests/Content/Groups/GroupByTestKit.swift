// A folder of files of known dates, sizes and kinds for the Group By suites
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerHarness {
    /// `Grouped`: a folder modified today and files of today, of yesterday and of 2020, of three kinds and sizes.
    /// Today is the clock's: a file of today is dated now, one of yesterday at noon the day before.
    func makeGroupedFolder() throws -> URL {
        let url = folder.appending("Grouped")
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .hour, value: -12, to: today) ?? today
        let old = calendar.date(from: DateComponents(year: 2020, month: 6, day: 1, hour: 12)) ?? today
        let files: [(String, Int, Date)] = [
            ("b-today.txt", 10, Date()), ("a-today.pdf", 200_000, Date()), ("c-yesterday.png", 2_000_000, yesterday),
            ("d-old.txt", 0, old), ("e-old.swift", 50, old),
        ]
        for (name, size, date) in files {
            let path = url.appendingPathComponent(name).path
            manager.createFile(atPath: path, contents: Data(count: size))
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        try manager.createDirectory(at: url.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        return url
    }
}

@MainActor
extension MainWindowController {
    /// The titles of the groups shown, in order.
    var groupTitles: [String] { content.groups.map(\.group.title) }

    /// The names under each group, in order.
    var groupedNames: [[String]] {
        content.groups.map { group in content.entries[group.range].map(\.name) }
    }

    /// Groups by `command`, and waits for the folder read again with what the groups need.
    func group(by command: AppCommand, expecting titles: [String]) async {
        perform(command)
        #expect(await waitUntil { self.groupTitles == titles }, "groups \(groupTitles), not \(titles)")
    }
}
