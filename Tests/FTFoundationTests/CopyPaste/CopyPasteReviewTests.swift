// Port of apps/desktop/src/renderer/lib/copyPasteReview.test.ts
import Foundation
import Testing

@testable import FTFoundation

/// The tests' dates are local dates, in a zone with daylight saving, written as en-US writes them.
private let zone = TimeZone(identifier: "America/New_York") ?? .current
private let dates = ReviewDateText(locale: Locale(identifier: "en_US"), timeZone: zone)

private func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    // `new Date(y, m, d, h, mi)` takes the month from 0.
    let components = DateComponents(year: year, month: month + 1, day: day, hour: hour, minute: minute)
    return (calendar.date(from: components) ?? Date()).epochMilliseconds
}

private let now = local(2026, 8, 29, 14, 0)
private let jan1 = local(2026, 0, 1, 1, 1)

private func fingerprint(_ kind: ReviewNodeKind, _ size: Int64? = nil, _ mtimeMs: Double? = nil) -> ReviewFingerprint {
    ReviewFingerprint(exists: kind != .missing, kind: kind, size: size, mtimeMs: mtimeMs)
}

private func node(
    _ id: String, _ sourcePath: String, conflictClass: ConflictClass? = nil, destinationPath: String? = nil,
    sourceKind: ReviewNodeKind = .file, destinationKind: ReviewNodeKind? = nil,
    sourceFingerprint: ReviewFingerprint? = nil, destinationFingerprint: ReviewFingerprint? = nil,
    children: [ReviewNode] = [], totalNodeCount: Int = 1, conflictNodeCount: Int? = nil,
    destinationTotalNodeCount: Int? = nil, keepBothDestinationPath: String? = nil,
    destinationOnly: ReviewDestinationOnly? = nil, replaceBlockedReason: String? = nil, renameOnly: Bool = false
) -> ReviewNode {
    let name = CopyPasteReview.leafName(sourcePath)
    let conflict = conflictClass != nil
    return ReviewNode(
        id: id, sourcePath: sourcePath, destinationPath: destinationPath ?? "/dest/\(name)", sourceKind: sourceKind,
        destinationKind: destinationKind ?? (conflict ? .file : .missing), conflictClass: conflictClass,
        sourceFingerprint: sourceFingerprint ?? fingerprint(.file, 1536, now - 60_000),
        destinationFingerprint: destinationFingerprint ?? fingerprint(conflict ? .file : .missing, 10, jan1),
        children: children, totalNodeCount: totalNodeCount, conflictNodeCount: conflictNodeCount ?? (conflict ? 1 : 0),
        destinationTotalNodeCount: destinationTotalNodeCount,
        keepBothDestinationPath: keepBothDestinationPath ?? (conflict ? "/dest/\(name) copy" : nil),
        destinationOnly: destinationOnly, replaceBlockedReason: replaceBlockedReason, renameOnly: renameOnly)
}

private func report(_ nodes: [ReviewNode], _ mode: ReviewMode = .copy) -> ReviewReport {
    ReviewReport(
        analysisId: "analysis-1", mode: mode, destinationDirectoryPath: "/dest", nodes: nodes,
        summary: ReviewReport.Summary(
            totalNodeCount: nodes.count,
            directoryConflictCount: nodes.filter { $0.conflictClass == .directoryConflict }.count))
}

private let notes = node(
    "item-1", "/src/notes.txt", conflictClass: .fileConflict, keepBothDestinationPath: "/dest/notes copy.txt")
private let photoA = node(
    "item-2/a.jpg", "/src/photos/a.jpg", conflictClass: .fileConflict, destinationPath: "/dest/photos/a.jpg",
    sourceFingerprint: fingerprint(.file, 90_000, now - 5000),
    destinationFingerprint: fingerprint(.file, 90_000, now - 5500), keepBothDestinationPath: "/dest/photos/a copy.jpg")
private let photoB = node("item-2/b.jpg", "/src/photos/b.jpg")
private let photos = node(
    "item-2", "/src/photos", conflictClass: .directoryConflict, sourceKind: .directory, destinationKind: .directory,
    sourceFingerprint: fingerprint(.directory), destinationFingerprint: fingerprint(.directory),
    children: [photoA, photoB], totalNodeCount: 3, conflictNodeCount: 2,
    destinationOnly: ReviewDestinationOnly(count: 1, samplePaths: ["d.jpg"]))
private let config = node(
    "item-3", "/src/config", conflictClass: .typeMismatch, destinationKind: .directory,
    destinationFingerprint: fingerprint(.directory), destinationTotalNodeCount: 1,
    destinationOnly: ReviewDestinationOnly(count: 1, samplePaths: ["settings.ini"]))
private let brandNew = node("item-4", "/src/brand new.txt")
private let keepAll = CopyPasteReview.policy(for: .keepAll)

private func rows(
    _ report: ReviewReport, _ policy: CopyPastePolicy, _ overrides: ReviewOverrides = [:], showNewItems: Bool = false
) -> [ReviewRow] {
    CopyPasteReview.rows(
        report, policy: policy, overrides: overrides, showNewItems: showNewItems, now: now, dates: dates)
}

private struct Triple: Equatable {
    var name: String
    var choice: CopyPasteChoice?
    var detail: String
}

@Suite struct CopyPasteReviewTests {
    // T-a81a1577
    @Test func skipsEveryConflictByDefaultFoldersIncluded() {
        let all = report([notes, photos, config, brandNew])
        let listed = rows(all, CopyPasteReview.safePolicy)
        #expect(
            listed.map { Triple(name: $0.name, choice: $0.choice, detail: $0.detail) } == [
                Triple(name: "notes.txt", choice: .skip, detail: "Left as is"),
                Triple(name: "photos", choice: .skip, detail: "Left as is"),
                Triple(name: "config", choice: .skip, detail: "Left as is"),
            ])
        let summary = CopyPasteReview.summarize(all, policy: CopyPasteReview.safePolicy, overrides: [:])
        #expect(summary.added == 1 && summary.skipped == 3 && summary.merged == 0)
        #expect(CopyPasteReview.currentAllConflictsChoice(all, CopyPasteReview.safePolicy, [:]) == .skip)
    }

    // T-2ae734f7
    @Test func mergesFoldersAndSkipsFilesThatExistWithAddMissing() {
        let all = report([notes, photos, config, brandNew])
        let policy = CopyPasteReview.policy(for: .addMissing)
        let listed = rows(all, policy)
        #expect(listed.map(\.name) == ["notes.txt", "photos", "a.jpg", "config"])
        #expect(listed.map(\.choice) == [.skip, .merge, .skip, .skip])
        #expect(listed.map(\.depth) == [0, 0, 1, 0])
        let summary = CopyPasteReview.summarize(all, policy: policy, overrides: [:])
        #expect(summary.added == 2 && summary.skipped == 3 && summary.merged == 1)
        #expect(CopyPasteReview.currentAllConflictsChoice(all, policy, [:]) == .addMissing)
    }

    // T-cb9562ff
    // B-CLIP-081
    @Test func offersAddMissingOnlyForACopyWithAFolderThatAlreadyExists() {
        #expect(
            CopyPasteReview.allConflictsChoices(report([notes, photos])) == [.skip, .addMissing, .keepAll, .overwrite])
        // Moving only the missing files would split the folder between both places.
        #expect(CopyPasteReview.allConflictsChoices(report([notes, photos], .cut)) == [.skip, .keepAll, .overwrite])
        // Without a folder it would do the same as Skip.
        #expect(CopyPasteReview.allConflictsChoices(report([notes, config])) == [.skip, .keepAll, .overwrite])
    }

    // T-cfbdb7c1
    @Test func saysWhatTheForAllConflictsChoiceDoes() {
        let withFolder = report([notes, photos])
        #expect(CopyPasteReview.describe(.skip, withFolder) == "Existing items stay as they are.")
        #expect(
            CopyPasteReview.describe(.keepAll, withFolder)
                == "Folders merge. Files that exist are added with a \u{201C}copy\u{201D} name.")
        #expect(
            CopyPasteReview.describe(.keepAll, report([notes]))
                == "Files that exist are added with a \u{201C}copy\u{201D} name.")
        #expect(CopyPasteReview.describe(nil, withFolder) == "Set separately for some items below.")
    }

    // T-f986253b
    // B-CLIP-098
    @Test func keepsBothFilesAndMergesFoldersWithKeepAllListingOnlyConflicts() {
        let listed = rows(report([notes, photos, config, brandNew]), keepAll)
        #expect(listed.map(\.name) == ["notes.txt", "photos", "a.jpg", "config"])
        #expect(listed.map(\.choice) == [.keepBoth, .merge, .keepBoth, .keepBoth])
        #expect(listed.map(\.depth) == [0, 0, 1, 0])
        #expect(listed[0].keepBothName == "notes copy.txt")
        #expect(listed[0].detail == "Yours is newer and larger \u{B7} 1.5 KB, today, 1:59 PM vs 10 B, Jan 1")
        #expect(
            listed[1].detail == "Folder \u{B7} 1 conflict inside \u{B7} 1 item added \u{B7} keeps \u{201C}d.jpg\u{201D}"
        )
        // Half a second apart is the same time for people.
        #expect(listed[2].detail == "Same size and date \u{B7} 90 KB, today, 1:59 PM")
        #expect(
            listed[3].detail
                == "Yours is a file \u{B7} the existing \u{201C}config\u{201D} is a folder with 1 item")
    }

    // T-1efbe01a
    @Test func doesntCountWhatIsInAFolderMovedByRenamingItWhichWasntRead() {
        let project = node("item-project", "/src/Project", sourceKind: .directory, renameOnly: true)
        #expect(rows(report([project], .cut), keepAll, showNewItems: true).map(\.detail) == ["New folder"])
    }

    // T-8c379017
    @Test func spellsOutWhatReplaceDeletes() {
        let listed = rows(report([notes, photos, config]), CopyPasteReview.policy(for: .overwrite))
        #expect(listed.map(\.name) == ["notes.txt", "photos", "config"])
        #expect(listed.map(\.tone) == [.danger, .danger, .danger])
        #expect(
            listed.map(\.detail) == [
                "Replaces the existing 10 B file from Jan 1",
                "Deletes \u{201C}d.jpg\u{201D}, which only exists in the existing folder",
                "Deletes \u{201C}settings.ini\u{201D}, which only exists in the existing folder",
            ])
    }

    // T-1b40940b
    @Test func describesAPackageAsOneItemNeverAsAFolderToMerge() {
        let app = node(
            "item-app", "/src/Foo.app", conflictClass: .fileConflict, sourceKind: .directory,
            destinationKind: .directory, sourceFingerprint: fingerprint(.directory, nil, now - 60_000),
            destinationFingerprint: fingerprint(.directory, nil, jan1), keepBothDestinationPath: "/dest/Foo copy.app")
        let replaced = rows(report([app]), CopyPasteReview.policy(for: .overwrite))[0]
        #expect(replaced.choices == [.keepBoth, .overwrite, .skip])
        #expect(replaced.detail == "Replaces the existing \u{201C}Foo.app\u{201D} from Jan 1")
        let kept = rows(report([app]), keepAll)[0]
        #expect(kept.keepBothName == "Foo copy.app")
        #expect(kept.detail == "The existing \u{201C}Foo.app\u{201D} stays")
    }

    // T-4accb430
    // T-f9bdb3fb
    @Test func getsSingularPluralAndUnnamedItemsRightInWhatReplaceDeletes() {
        func describe(_ only: ReviewDestinationOnly) -> String? {
            var folder = photos
            folder.destinationOnly = only
            return rows(report([folder]), CopyPasteReview.policy(for: .overwrite)).first?.detail
        }
        #expect(
            describe(ReviewDestinationOnly(count: 3, samplePaths: ["d.jpg", "raw"]))
                == "Deletes \u{201C}d.jpg\u{201D} and 2 more, which only exist in the existing folder")
        #expect(
            describe(ReviewDestinationOnly(count: 1, samplePaths: []))
                == "Deletes 1 item that only exists in the existing folder")
        #expect(
            describe(ReviewDestinationOnly(count: 1_500, samplePaths: []))
                == "Deletes 1,500 items that only exist in the existing folder")
        #expect(
            describe(ReviewDestinationOnly(count: 1_201, samplePaths: ["d.jpg"]))
                == "Deletes \u{201C}d.jpg\u{201D} and 1,200 more, which only exist in the existing folder")
    }

    // T-12ec017b
    @Test func saysWhatMergingKeepsWithOrWithoutASampleName() {
        func describe(_ only: ReviewDestinationOnly) -> String? {
            var folder = photos
            folder.destinationOnly = only
            return rows(report([folder]), keepAll).first?.detail
        }
        #expect(
            describe(ReviewDestinationOnly(count: 3, samplePaths: ["d.jpg"]))
                == "Folder \u{B7} 1 conflict inside \u{B7} 1 item added \u{B7} keeps \u{201C}d.jpg\u{201D} and 2 more")
        #expect(
            describe(ReviewDestinationOnly(count: 2, samplePaths: []))
                == "Folder \u{B7} 1 conflict inside \u{B7} 1 item added \u{B7} keeps 2 items already there")
    }

    // T-82f5c6e7
    // T-6d9f49ef
    @Test func fallsBackToTheSafeChoiceWhereReplaceIsntPossibleAndSaysWhy() {
        var blockedFolder = photos
        blockedFolder.replaceBlockedReason = "It contains the item being pasted."
        var blockedFile = notes
        blockedFile.id = "item-5"
        blockedFile.replaceBlockedReason = "It is the item being pasted."
        let all = report([blockedFolder, blockedFile, config])
        let policy = CopyPasteReview.policy(for: .overwrite)
        let listed = rows(all, policy)
        #expect(listed.map(\.name) == ["photos", "a.jpg", "notes.txt", "config"])
        #expect(listed.map(\.choice) == [.merge, .overwrite, .keepBoth, .overwrite])
        #expect(listed[0].detail.contains("Can't replace: It contains the item being pasted."))
        #expect(listed[2].detail.contains("Can't replace: It is the item being pasted."))
        let summary = CopyPasteReview.summarize(all, policy: policy, overrides: [:])
        #expect(summary.replaced == 2 && summary.merged == 1 && summary.keptBoth == 1)
        // The menu still reads Replace: that is what it does wherever it can.
        #expect(CopyPasteReview.currentAllConflictsChoice(all, policy, [:]) == .overwrite)
    }

    // T-79327802
    @Test func namesNestedRowsByTheirPathBelowTheSourceFolder() {
        #expect(rows(report([photos]), keepAll).map(\.relativePath) == ["photos", "photos/a.jpg"])
    }

    // T-07ef850d
    // B-CLIP-095
    @Test func appliesPerItemChoicesAndSaysWhereSkippedMovesStay() {
        let listed = rows(report([notes, photos], .cut), keepAll, ["item-1": .skip, "item-2": .keepBoth])
        #expect(
            listed.map { Triple(name: $0.name, choice: $0.choice, detail: $0.detail) } == [
                Triple(name: "notes.txt", choice: .skip, detail: "Stays in \u{201C}src\u{201D}"),
                Triple(
                    name: "photos", choice: .keepBoth, detail: "Folder \u{B7} 2 items \u{B7} the existing folder stays"),
            ])
    }

    // T-3660ef0a
    @Test func saysEachSkippedMoveStaysInItsOwnFolder() {
        let listed = rows(report([notes, photos], .cut), keepAll, ["item-2/a.jpg": .skip])
        #expect(listed.first { $0.name == "a.jpg" }?.detail == "Stays in \u{201C}photos\u{201D}")
    }

    // T-428fe0f8
    @Test func showsNewItemsOnRequest() {
        let listed = rows(report([notes, brandNew]), keepAll, showNewItems: true)
        #expect(listed.map(\.name) == ["notes.txt", "brand new.txt"])
        #expect(listed.map(\.choice) == [.keepBoth, nil])
    }

    // T-cd834e69
    // T-f9bdb3fb
    @Test func summarizesWhatTheOperationWillDo() {
        let summary = CopyPasteReview.summarize(
            report([notes, photos, config, brandNew]), policy: keepAll, overrides: ["item-3": .overwrite])
        #expect(
            summary
                == ReviewSummary(
                    topLevelCount: 4, conflictTopLevelCount: 3, newTopLevelCount: 1, added: 2, keptBoth: 2, merged: 1,
                    replaced: 1, skipped: 0))
        #expect(
            CopyPasteReview.formatSummary(summary)
                == "2 items will be added, 2 kept as copies, 1 folder merged, 1 replaced")
        #expect(
            CopyPasteReview.formatSummary(summary, verb: "Move")
                == "2 items will be moved, 2 kept as copies, 1 folder merged, 1 replaced")
        var many = summary
        many.added = 12_000
        many.keptBoth = 0
        many.merged = 0
        many.replaced = 0
        #expect(CopyPasteReview.formatSummary(many) == "12,000 items will be added")
        var skipped = summary
        skipped.added = 0
        skipped.keptBoth = 0
        skipped.merged = 0
        skipped.replaced = 0
        skipped.skipped = 1
        #expect(CopyPasteReview.formatSummary(skipped) == "1 item will be skipped")
    }

    // T-ef63d1b6
    @Test func reportsTheForAllConflictsChoiceOrMixed() {
        let nodes = report([notes, photos, config])
        #expect(CopyPasteReview.currentAllConflictsChoice(nodes, keepAll, [:]) == .keepAll)
        #expect(CopyPasteReview.currentAllConflictsChoice(nodes, CopyPasteReview.safePolicy, [:]) == .skip)
        // Merging a folder and skipping what is inside is Add Missing.
        #expect(
            CopyPasteReview.currentAllConflictsChoice(nodes, CopyPasteReview.safePolicy, ["item-2": .merge])
                == .addMissing)
        #expect(CopyPasteReview.currentAllConflictsChoice(nodes, keepAll, ["item-1": .skip]) == nil)
        // A nested conflict set differently makes it mixed too.
        #expect(CopyPasteReview.currentAllConflictsChoice(nodes, keepAll, ["item-2/a.jpg": .skip]) == nil)
    }

    // T-81abaa8c
    // B-CLIP-092
    @Test func goesBackToASingleForAllConflictsValueWhenAnItemIsSetBack() {
        let nodes = report([notes, photos])
        // Choices equal to what "For all conflicts" does are not a difference.
        #expect(
            CopyPasteReview.currentAllConflictsChoice(nodes, keepAll, ["item-1": .keepBoth, "item-2": .merge])
                == .keepAll)
        #expect(
            CopyPasteReview.currentAllConflictsChoice(
                nodes, CopyPasteReview.policy(for: .overwrite), ["item-1": .overwrite]) == .overwrite)
    }

    // T-f8734900
    // B-CLIP-099
    @Test func formatsDatesRelativeToToday() {
        #expect(dates.format(now - 60_000, now: now) == "today, 1:59 PM")
        #expect(dates.format(now - 86_400_000, now: now) == "yesterday, 2:00 PM")
        #expect(dates.format(jan1, now: now) == "Jan 1")
        #expect(dates.format(local(2025, 5, 3), now: now) == "Jun 3, 2025")
    }

    // Built from local dates, so they hold in any time zone; in one with daylight saving the days around the change
    // are 23 and 25 hours long.
    // T-70180a1d
    // B-CLIP-099
    @Test func countsYesterdayInCalendarDaysAcrossDaylightSavingChanges() {
        let afterFallBack = local(2026, 10, 2, 10, 0)
        #expect(dates.format(local(2026, 10, 1, 0, 30), now: afterFallBack) == "yesterday, 12:30 AM")
        #expect(dates.format(local(2026, 9, 31, 23, 30), now: afterFallBack) == "Oct 31")
        let afterSpringForward = local(2026, 2, 9, 10, 0)
        #expect(dates.format(local(2026, 2, 8, 0, 30), now: afterSpringForward) == "yesterday, 12:30 AM")
        #expect(dates.format(local(2026, 2, 7, 23, 30), now: afterSpringForward) == "Mar 7")
        let newYear = local(2026, 0, 1, 9, 0)
        #expect(dates.format(local(2025, 11, 31, 22, 0), now: newYear) == "yesterday, 10:00 PM")
    }

    // T-d678a304
    // B-CLIP-099
    @Test func showsADateInTheFutureInFullInsteadOfAsToday() {
        #expect(dates.format(now + 30_000, now: now) == "today, 2:00 PM")
        #expect(dates.format(now + 2 * 3_600_000, now: now) == "Sep 29, 2026, 4:00 PM")
        #expect(dates.format(local(2027, 2, 1, 9, 5), now: now) == "Mar 1, 2027, 9:05 AM")
    }
}
