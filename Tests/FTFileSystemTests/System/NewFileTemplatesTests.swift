import Foundation
import Testing

@testable import FTFileSystem

@Suite struct NewFileTemplatesTests {
    // The files of the folder, by name in the order names are sorted; not folders, packages or hidden files.
    @Test func listsTheFilesATemplateCanBeMadeFrom() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["Notes 10.md", "Notes 2.md", "budget.csv", ".DS_Store", "Letter.txt"] {
            FileManager.default.createFile(atPath: "\(folder)/\(name)", contents: Data("x".utf8))
        }
        try FileManager.default.createDirectory(atPath: "\(folder)/Project", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: "\(folder)/Deck.key", withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: "\(folder)/Link.txt", withDestinationPath: "Letter.txt")
        try FileManager.default.createSymbolicLink(atPath: "\(folder)/Folder link", withDestinationPath: "Project")
        #expect(
            NewFileTemplates.names(in: folder) == ["budget.csv", "Letter.txt", "Link.txt", "Notes 2.md", "Notes 10.md"])
    }

    @Test func listsNothingWhenThereIsNoFolder() {
        #expect(NewFileTemplates.names(in: "/nonexistent-\(UUID().uuidString)") == [])
    }
}
