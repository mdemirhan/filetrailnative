// The accent parity scenario on other kinds of disk, where the system's calls may not agree on how a name is spelled
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// A folder of a kind on a disk of a kind.
struct AccentDiskCase: Sendable, Hashable, CustomTestStringConvertible {
    var disk: DiskImage.Kind
    var kind: AccentKind

    var testDescription: String { disk.rawValue + ": " + kind.testDescription }

    /// "café" stored composed and decomposed and "한글" stored composed, each with files of both spellings: where the
    /// folder is stored composed its sub-folder is too.
    static func all(on disk: DiskImage.Kind) -> [AccentDiskCase] {
        [
            AccentKind(label: "cafe composed", folder: "caf\u{E9}", nested: false, files: .decomposedFirst),
            AccentKind(label: "cafe decomposed", folder: "cafe\u{301}", nested: false, files: .composedFirst),
            AccentKind(label: "hangul composed", folder: "\u{D55C}\u{AE00}", nested: false, files: .decomposedFirst),
        ].map { AccentDiskCase(disk: disk, kind: $0) }
    }

    var folderStoredComposed: Bool { AccentSpelling(of: kind.folder) == .composed }
}

extension AccentParity {
    /// The scenario in a folder of a kind on a disk, each fact held against the plain folder's on the same disk.
    static func check(_ placed: AccentDiskCase) async throws {
        let plain = try await plainFacts(on: placed.disk)
        let facts = try await facts(of: placed.kind, on: placed.disk)
        let own = Dictionary(facts.map { ($0.key, $0.value) }) { first, _ in first }
        for fact in plain {
            #expect(own[fact.key] == fact.value, "\(placed.testDescription): \(fact.key)")
        }
        // What only this run said: something left standing over the tab by a step that went wrong.
        let plainKeys = Set(plain.map(\.key))
        for fact in facts where !plainKeys.contains(fact.key) {
            Issue.record("\(placed.testDescription): \(fact.key) = \(fact.value)")
        }
    }

    /// The plain folder's run on a disk did what each step is there to show.
    static func checkPlain(on disk: DiskImage.Kind) async throws {
        let facts = try await plainFacts(on: disk)
        #expect(facts.count > 100)
        for fact in facts where fact.value == "false" || fact.value == "nil" {
            Issue.record("\(disk.rawValue): \(fact.key) is \(fact.value) in the plain folder")
        }
    }
}

extension ExplorerWindowlessTests {
    /// HFS+ stores every name decomposed and gives it so by every call: a folder with an accent behaves there as a
    /// plain one, whatever was typed. A suite a disk, so a full run spreads them over its processes.
    @MainActor
    @Suite(.restoresWindowSeams) struct AccentParityHFSTests {
        @Test(.tags(.diskImage), .diskImages)
        func thePlainFolderDoesWhatEachStepShows() async throws {
            try await AccentParity.checkPlain(on: .hfs)
        }

        @Test(.tags(.diskImage), .diskImages, arguments: AccentDiskCase.all(on: .hfs))
        func anAccentedFolderBehavesAsAPlainOne(_ placed: AccentDiskCase) async throws {
            try await AccentParity.check(placed)
        }
    }

    /// On FAT32 a name made composed is given decomposed where a folder is read and composed where the one item is
    /// asked about (`AccentSpellingSourcesTests`), and a rename finds its source only by the name the disk holds for
    /// it. The app names every item there as the disk holds it (`ft_held_name`), so a folder with an accent behaves
    /// as a plain one.
    @MainActor
    @Suite(.restoresWindowSeams) struct AccentParityFAT32Tests {
        @Test(.tags(.diskImage), .diskImages)
        func thePlainFolderDoesWhatEachStepShows() async throws {
            try await AccentParity.checkPlain(on: .fat32)
        }

        @Test(.tags(.diskImage), .diskImages, arguments: AccentDiskCase.all(on: .fat32))
        func anAccentedFolderBehavesAsAPlainOne(_ placed: AccentDiskCase) async throws {
            try await AccentParity.check(placed)
        }
    }

    /// exFAT spells names as FAT32 does; it takes a rename by either spelling, and an unlink only by the one it holds.
    @MainActor
    @Suite(.restoresWindowSeams) struct AccentParityExFATTests {
        @Test(.tags(.diskImage), .diskImages)
        func thePlainFolderDoesWhatEachStepShows() async throws {
            try await AccentParity.checkPlain(on: .exfat)
        }

        @Test(.tags(.diskImage), .diskImages, arguments: AccentDiskCase.all(on: .exfat))
        func anAccentedFolderBehavesAsAPlainOne(_ placed: AccentDiskCase) async throws {
            try await AccentParity.check(placed)
        }
    }
}
