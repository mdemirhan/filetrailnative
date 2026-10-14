// Port of apps/desktop/src/shared/batchRename.test.ts, and the planning half of apps/desktop/src/main/bootstrap/batchRenamePlanAndRun.test.ts
import Foundation
import Testing

@testable import FTFoundation

private let now = "2026-10-04T11:32:10"

private func item(
    _ name: String, isFolder: Bool = false, path: String? = nil, createdAt: String? = "2026-09-30T10:12:40",
    modifiedAt: String? = "2026-10-01T08:30:15", takenAt: String? = nil
) -> BatchRenameItem {
    BatchRenameItem(
        path: path ?? "/trip/\(name)", name: name, isFolder: isFolder, createdAt: createdAt, modifiedAt: modifiedAt,
        takenAt: takenAt)
}

/// The new names, or nil for an item left as it is.
private func names(_ settings: BatchRenameSettings, _ itemNames: [String]) -> [String?] {
    BatchRename.proposeNames(settings: settings, items: itemNames.map { item($0) }, now: now).names.map { proposed in
        if case .renamed(let name, _, _, _) = proposed { name } else { nil }
    }
}

private func proposed(_ settings: BatchRenameSettings, _ items: [BatchRenameItem]) -> ProposedNames {
    BatchRename.proposeNames(settings: settings, items: items, now: now)
}

private func renamedName(_ name: ProposedName) -> String? {
    if case .renamed(let name, _, _, _) = name { name } else { nil }
}

private func plan(
    _ settings: BatchRenameSettings, _ itemNames: [String], folderNames: [String]? = nil,
    caseSensitive: Bool = false, cannotRename: [String: String] = [:]
) -> BatchRenamePlan {
    BatchRename.planBatchRename(
        BatchRenamePlanInput(
            settings: settings, items: itemNames.map { item($0) },
            folders: ["/trip": BatchRenameFolder(names: folderNames ?? itemNames, caseSensitive: caseSensitive)],
            cannotRename: cannotRename, now: now))
}

private func outcome(_ planItem: BatchRenamePlanItem) -> String {
    switch planItem {
    case .unchanged: "unchanged"
    case .rename(let name, _, _, _, _, _): name
    case .problem(let proposedName, _, let problem):
        switch problem {
        case .invalid: "invalid:\(proposedName)"
        case .taken: "taken:\(proposedName)"
        case .skippedTaken: "skippedTaken:\(proposedName)"
        case .cannotRename: "cannotRename:\(proposedName)"
        }
    }
}

private func segmentsOf(_ planItem: BatchRenamePlanItem) -> [NameSegment] {
    switch planItem {
    case .unchanged: []
    case .rename(_, let segments, _, _, _, _): segments
    case .problem(_, let segments, _): segments
    }
}

private func seg(_ text: String, _ changed: Bool) -> NameSegment { NameSegment(text: text, changed: changed) }

struct BatchRenameSplitTests {
    // T-74733b5f
    @Test func takesWhatFollowsTheLastDotAsTheExtension() {
        #expect(NumberedNames.splitItemName("photo.jpg", isFolder: false) == .init(stem: "photo", extension: "jpg"))
        #expect(
            NumberedNames.splitItemName("archive.tar.gz", isFolder: false)
                == .init(stem: "archive.tar", extension: "gz"))
        #expect(NumberedNames.splitItemName("Tool.app", isFolder: false) == .init(stem: "Tool", extension: "app"))
    }

    // T-5ee14ea6
    @Test func findsNoExtensionInAFolderADotfileANameEndingInADotOrWithoutOne() {
        #expect(
            NumberedNames.splitItemName("photos.2026", isFolder: true) == .init(stem: "photos.2026", extension: nil))
        #expect(NumberedNames.splitItemName(".env", isFolder: false) == .init(stem: ".env", extension: nil))
        #expect(NumberedNames.splitItemName("draft.", isFolder: false) == .init(stem: "draft.", extension: nil))
        #expect(NumberedNames.splitItemName("README", isFolder: false) == .init(stem: "README", extension: nil))
        #expect(
            NumberedNames.splitItemName(".config.json", isFolder: false) == .init(stem: ".config", extension: "json"))
    }
}

struct ReplaceTextTests {
    // T-5934ce13
    @Test func findsAccentedLettersHoweverTheyAreWritten() {
        let decomposed = "Cafe\u{301} menu.pdf"
        let cafe = BatchRenameSettings(find: "Caf\u{E9}", replaceWith: "Bistro")
        #expect(names(cafe, [decomposed]) == ["Bistro menu.pdf"])
        // Typed as "e" and an accent, it finds the name written with "é".
        let typedDecomposed = BatchRenameSettings(find: "Cafe\u{301}", replaceWith: "Bistro")
        #expect(names(typedDecomposed, ["Caf\u{E9}.pdf"]) == ["Bistro.pdf"])
        // No match: the name keeps the way its accents are written.
        #expect(names(BatchRenameSettings(find: "tea", replaceWith: "x"), [decomposed]) == [nil])
        // A change that only writes the accent another way is no change.
        #expect(names(BatchRenameSettings(find: "\u{E9}", replaceWith: "e\u{301}"), [decomposed]) == [nil])
    }

    // T-76b8b755
    @Test func replacesEveryMatchIgnoringCaseUnlessAskedNotTo() {
        #expect(
            names(BatchRenameSettings(find: "img_", replaceWith: "Lisbon "), ["IMG_2041.jpg"]) == ["Lisbon 2041.jpg"])
        #expect(
            names(BatchRenameSettings(find: "img_", replaceWith: "x", matchCase: true), ["IMG_2041.jpg"]) == [nil])
        #expect(names(BatchRenameSettings(find: "a", replaceWith: "o"), ["banana.txt"]) == ["bonono.txt"])
    }

    // T-75a95bf0
    @Test func leavesAnItemWithoutAMatchAndEveryItemWithNothingToFind() {
        #expect(
            names(BatchRenameSettings(find: "copy", replaceWith: ""), ["a copy.txt", "b.txt"]) == ["a.txt", nil])
        #expect(names(BatchRenameSettings(find: "", replaceWith: "x"), ["a.txt"]) == [nil])
    }

    // T-d533cb5e
    @Test func takesPlainTextAsTypedDotsDollarsAndBracketsAreJustCharacters() {
        #expect(names(BatchRenameSettings(find: ".", replaceWith: "$1"), ["a.b.c.txt"]) == ["a$1b$1c.txt"])
        #expect(
            names(BatchRenameSettings(find: "(1)", replaceWith: "[one]"), ["report (1).pdf"]) == ["report [one].pdf"])
    }

    // T-e7a0d107
    @Test func worksInANameAnExtensionOrBothAsApplyToSays() {
        #expect(
            names(BatchRenameSettings(find: "jpg", replaceWith: "png"), ["jpg photo.jpg"]) == ["png photo.jpg"])
        #expect(
            names(
                BatchRenameSettings(find: "jpeg", replaceWith: "jpg", applyTo: .extensionPart),
                ["jpeg.jpeg", "a.png"]) == ["jpeg.jpg", nil])
        #expect(
            names(BatchRenameSettings(find: ".", replaceWith: "_", applyTo: .both), ["a.b.txt"]) == ["a_b_txt"])
        // An extension replaced with nothing takes its dot with it.
        #expect(
            names(
                BatchRenameSettings(find: "bak", replaceWith: "", applyTo: .extensionPart),
                ["notes.bak", "x.bak"]) == ["notes", "x"])
    }

    // T-9f8c3140
    @Test func usesARegularExpressionsGroupsInTheReplacement() {
        func regex(_ find: String, _ replaceWith: String) -> BatchRenameSettings {
            BatchRenameSettings(find: find, replaceWith: replaceWith, useRegex: true)
        }
        #expect(names(regex("^IMG_(\\d+)$", "Lisbon $1"), ["IMG_2041.HEIC"]) == ["Lisbon 2041.HEIC"])
        #expect(
            names(regex("(\\d{4})-(\\d{2})-(\\d{2})", "$3.$2.$1"), ["2026-10-04 notes.txt"])
                == ["04.10.2026 notes.txt"])
        #expect(
            names(regex("(?<word>\\w+)_(?<n>\\d+)", "$<n> $<word>"), ["lisbon_12.jpg"]) == ["12 lisbon.jpg"])
        #expect(names(regex("\\d+", "[$&]"), ["a1b22.txt"]) == ["a[1]b[22].txt"])
        #expect(names(regex("^", "2026 "), ["notes.txt"]) == ["2026 notes.txt"])
    }

    // T-07bf6eb8
    @Test func matchesCaseOnlyWhenAskedWithARegularExpressionToo() {
        #expect(
            names(BatchRenameSettings(find: "^a", replaceWith: "x", useRegex: true), ["Apple.txt"]) == ["xpple.txt"])
        #expect(
            names(
                BatchRenameSettings(find: "^a", replaceWith: "x", matchCase: true, useRegex: true), ["Apple.txt"])
                == [nil])
    }

    // T-1fa13a17
    @Test func saysWhenAPatternIsBrokenAndChangesNothing() {
        let result = proposed(
            BatchRenameSettings(find: "(unclosed", replaceWith: "x", useRegex: true), [item("a.txt")])
        #expect(result.settingsError?.hasPrefix("The pattern isn\u{2019}t valid: ") == true)
        #expect(result.names == [.unchanged])
    }

    // T-37a0c5e2
    @Test func marksTheReplacedPartsForThePreview() {
        let result = proposed(BatchRenameSettings(find: "IMG_", replaceWith: "Lisbon "), [item("IMG_2041.jpg")])
        #expect(
            result.names[0]
                == .renamed(
                    name: "Lisbon 2041.jpg", segments: [seg("Lisbon ", true), seg("2041.jpg", false)],
                    usedCreatedForTaken: false, emptyName: false))
    }
}

struct ExpandReplacementTests {
    private func match(_ pattern: String, _ subject: String) throws -> JSMatch {
        try #require(try JSRegExp(source: pattern, ignoreCase: false).matches(in: subject).first)
    }

    private func expand(_ template: String, _ found: JSMatch, _ subject: String) -> String {
        BatchRename.expandReplacement(template, match: found, subject: subject)
    }

    // T-a3131847
    @Test func expandsGroupsTheMatchAndWhatIsAroundIt() throws {
        let found = try match("(b)(c)", "abcd")
        #expect(expand("$2$1", found, "abcd") == "cb")
        #expect(expand("[$&]", found, "abcd") == "[bc]")
        #expect(expand("$`|$'", found, "abcd") == "a|d")
        #expect(expand("$$1", found, "abcd") == "$1")
    }

    // T-d61b8aae
    @Test func keepsWhatNamesNoGroupAsTyped() throws {
        let found = try match("(b)", "abc")
        #expect(expand("$3", found, "abc") == "$3")
        #expect(expand("$<x>", found, "abc") == "$<x>")
        #expect(expand("cost $", found, "abc") == "cost $")
        #expect(expand("$x", found, "abc") == "$x")
    }

    // T-ec26c831
    @Test func putsNothingForAGroupThatMatchedNothingOrANameThatIsntAGroup() throws {
        let either = try match("(a)|(b)", "b")
        #expect(expand("[$1][$2]", either, "b") == "[][b]")
        let named = try match("(?<word>\\w+)", "hi")
        #expect(expand("$<other>|$<word>", named, "hi") == "|hi")
        #expect(expand("$<word", named, "hi") == "$<word")
    }

    // T-28dfaa5a
    @Test func readsTwoDigitsOnlyWhenThereAreThatManyGroups() throws {
        let eleven = try match("(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)", "abcdefghijk")
        #expect(expand("$11", eleven, "abcdefghijk") == "k")
        let one = try match("(a)", "a")
        #expect(expand("$10", one, "a") == "a0")
    }
}

struct AddTextTests {
    // T-c0dadf59
    @Test func addsBeforeOrAfterTheNameOrTheExtension() {
        #expect(names(BatchRenameSettings(mode: .add, addText: " (edited)"), ["a.txt"]) == ["a (edited).txt"])
        #expect(
            names(BatchRenameSettings(mode: .add, addText: "old-", addWhere: .before), ["a.txt"]) == ["old-a.txt"])
        #expect(
            names(BatchRenameSettings(mode: .add, addText: ".bak", applyTo: .both), ["a.txt"]) == ["a.txt.bak"])
        #expect(
            names(
                BatchRenameSettings(mode: .add, addText: "x", applyTo: .extensionPart), ["a.txt", "README"])
                == ["a.txtx", nil])
    }

    // T-dcbfaa1f
    @Test func dropsSpacesItWouldLeaveAtEitherEndAndChangesNothingWithNoText() {
        #expect(
            names(BatchRenameSettings(mode: .add, addText: " draft", addWhere: .before), ["a.txt"]) == ["drafta.txt"])
        #expect(names(BatchRenameSettings(mode: .add, addText: "   "), ["a.txt"]) == [nil])
        #expect(names(BatchRenameSettings(mode: .add, addText: ""), ["a.txt"]) == [nil])
    }

    // T-c19b419a
    @Test func treatsAFoldersWholeNameAsItsName() {
        let result = proposed(BatchRenameSettings(mode: .add, addText: " old"), [item("photos.2026", isFolder: true)])
        #expect(renamedName(result.names[0]) == "photos.2026 old")
    }
}

struct ChangeCaseTests {
    private func caseSettings(_ style: BatchRenameCase, _ applyTo: BatchRenameApplyTo = .name) -> BatchRenameSettings {
        BatchRenameSettings(mode: .changeCase, caseStyle: style, applyTo: applyTo)
    }

    // T-abaeae71
    @Test func changesTheCaseOfTheNameTheExtensionOrBoth() {
        #expect(names(caseSettings(.lower), ["My Photo.JPG"]) == ["my photo.JPG"])
        #expect(names(caseSettings(.upper, .both), ["a.txt"]) == ["A.TXT"])
        #expect(names(caseSettings(.lower, .extensionPart), ["A.JPG"]) == ["A.jpg"])
    }

    // T-08679956
    @Test func leavesNamesAlreadyInThatCase() {
        #expect(names(caseSettings(.lower), ["done.txt"]) == [nil])
    }

    // T-602119f6
    @Test func raisesTheFirstLetterOfEachWordForTitleCaseAndLeavesTheRest() {
        #expect(BatchRename.changeCase("readMe file", .title) == "ReadMe File")
        #expect(BatchRename.changeCase("my-project_notes (draft)", .title) == "My-Project_Notes (Draft)")
        #expect(BatchRename.changeCase("\u{E9}lan vital", .title) == "\u{C9}lan Vital")
        #expect(BatchRename.changeCase("2026 trip", .title) == "2026 Trip")
        // A word after a dot is a word: the extension, too, when Apply To takes it in.
        #expect(names(caseSettings(.title, .both), ["my photo.jpg"]) == ["My Photo.Jpg"])
        #expect(names(caseSettings(.title), ["archive.tar.gz"]) == ["Archive.Tar.gz"])
    }
}

struct FormatTests {
    private func format(
        nameFormat: BatchRenameNameFormat = .index, formatWhere: BatchRenameWhere = .after,
        customName: String = "File", keepNames: Bool = false, startAt: Int = 1, step: Int = 1,
        digits: BatchRenameDigits = .fixed(5), separator: BatchRenameSeparator = .space,
        dateSource: BatchRenameDateSource = .created, dateFormat: BatchRenameDateFormat = .ymd,
        dateSeparator: BatchRenameDateSeparator = .hyphen, customDatePattern: String = "YYYY-MM-DD at HH.mm",
        applyTo: BatchRenameApplyTo = .name
    ) -> BatchRenameSettings {
        BatchRenameSettings(
            mode: .format, nameFormat: nameFormat, formatWhere: formatWhere, customName: customName,
            keepNames: keepNames, startAt: startAt, step: step, digits: digits, separator: separator,
            dateSource: dateSource, dateFormat: dateFormat, dateSeparator: dateSeparator,
            customDatePattern: customDatePattern, applyTo: applyTo)
    }

    // T-43fc6af1
    @Test func numbersItemsAsFinderDoes() {
        #expect(names(format(), ["a.jpg", "b.png", "c"]) == ["File 1.jpg", "File 2.png", "File 3"])
    }

    // T-fccc7149
    @Test func startsStepsAndPutsTheNumberBeforeTheNameWhenAsked() {
        #expect(
            names(format(formatWhere: .before, customName: "Trip", startAt: 10, step: 5), ["a.jpg", "b.jpg"])
                == ["10 Trip.jpg", "15 Trip.jpg"])
    }

    // T-73b2b448
    @Test func padsACounterToItsDigitsOrToTheLastNumbers() {
        #expect(names(format(nameFormat: .counter), ["a", "b"]) == ["File 00001", "File 00002"])
        #expect(names(format(nameFormat: .counter, digits: .fixed(2)), ["a"]) == ["File 01"])
        let twelve = (0..<12).map { "f\($0)" }
        #expect(names(format(nameFormat: .counter, digits: .auto), twelve)[0] == "File 01")
        #expect(names(format(nameFormat: .counter, digits: .auto), ["a", "b"])[1] == "File 2")
    }

    // T-b69c0b48
    @Test func joinsWithTheSeparatorChosenOrNone() {
        #expect(names(format(separator: .underscore), ["a.jpg"]) == ["File_1.jpg"])
        #expect(names(format(separator: .none), ["a.jpg"]) == ["File1.jpg"])
        #expect(names(format(formatWhere: .before, separator: .hyphen), ["a.jpg"]) == ["1-File.jpg"])
    }

    // T-c741268c
    @Test func keepsEachItemsOwnNameAndAddsTheNumberToIt() {
        #expect(
            names(format(keepNames: true), ["IMG_2041.jpg", "notes.txt"]) == ["IMG_2041 1.jpg", "notes 2.txt"])
    }

    // T-4ad60edf
    @Test func putsInTheDateChosenInTheFormatChosen() {
        let photo = item("IMG_2041.HEIC", takenAt: "2026-05-14T18:02:11")
        func date(_ settings: BatchRenameSettings) -> String? {
            renamedName(proposed(settings, [photo]).names[0])
        }
        func dated(
            _ source: BatchRenameDateSource = .created, _ dateFormat: BatchRenameDateFormat = .ymd,
            _ dateSeparator: BatchRenameDateSeparator = .hyphen
        ) -> BatchRenameSettings {
            format(
                nameFormat: .date, customName: "Lisbon", dateSource: source, dateFormat: dateFormat,
                dateSeparator: dateSeparator)
        }
        #expect(date(dated()) == "Lisbon 2026-09-30.HEIC")
        #expect(date(dated(.modified)) == "Lisbon 2026-10-01.HEIC")
        #expect(date(dated(.taken)) == "Lisbon 2026-05-14.HEIC")
        #expect(date(dated(.today)) == "Lisbon 2026-10-04.HEIC")
        #expect(date(dated(.taken, .ymdHMS, .none)) == "Lisbon 20260514180211.HEIC")
        #expect(date(dated(.taken, .dmyy, .underscore)) == "Lisbon 14_05_26.HEIC")
    }

    // T-427c1a29
    @Test func usesTheDateCreatedForAnItemWithNoDateTakenAndSaysSo() {
        let result = proposed(format(nameFormat: .date, dateSource: .taken), [item("notes.txt")])
        guard case .renamed(let name, _, let usedCreated, _) = result.names[0] else {
            Issue.record("not renamed")
            return
        }
        #expect(name == "File 2026-09-30.txt")
        #expect(usedCreated)
    }

    // T-76a59b72
    @Test func followsACustomDatePatternKeepingWhatIsntAToken() {
        let settings = format(
            nameFormat: .date, dateSource: .modified, dateFormat: .custom, customDatePattern: "YYYY-DD-MM at HH.mm.ss")
        #expect(names(settings, ["a.jpg"]) == ["File 2026-01-10 at 08.30.15.jpg"])
    }

    // T-06f36ee3
    @Test func keepsTextInSquareBracketsAsTypedEvenLettersThatAreTokens() {
        func pattern(_ customDatePattern: String) -> [String?] {
            names(
                format(
                    nameFormat: .date, dateSource: .modified, dateFormat: .custom,
                    customDatePattern: customDatePattern), ["a.jpg"])
        }
        #expect(pattern("[Mission] YYYY") == ["File Mission 2026.jpg"])
        #expect(pattern("Mission YYYY") == ["File Mi15ion 2026.jpg"])
        // An unclosed bracket is only a bracket.
        #expect(pattern("[YYYY") == ["File [2026.jpg"])
        // Bracketed tokens don't count as the token the pattern needs.
        let bracketed = proposed(
            format(nameFormat: .date, dateFormat: .custom, customDatePattern: "[YYYY]"), [item("a.jpg")])
        #expect(bracketed.settingsError?.contains("at least one of YYYY") == true)
    }

    // T-69341c53
    @Test func asksForATokenInACustomDatePatternThatHasNone() {
        func error(_ pattern: String) -> String? {
            proposed(format(nameFormat: .date, dateFormat: .custom, customDatePattern: pattern), [item("a.jpg")])
                .settingsError
        }
        #expect(error("today")?.contains("at least one of YYYY") == true)
        // The same check twice: nothing carries over between checks.
        #expect(error("YYYY") == nil)
        #expect(error("YYYY") == nil)
    }

    // T-0ecdc468
    @Test func leavesAnItemWithoutTheDateAskedForAsItIs() {
        let result = proposed(
            format(nameFormat: .date, dateSource: .modified), [item("a.jpg", modifiedAt: nil)])
        #expect(result.names == [.unchanged])
    }

    // T-fb9e458e
    @Test func ignoresApplyToTheExtensionIsAlwaysKept() {
        #expect(names(format(applyTo: .both), ["a.jpg"]) == ["File 1.jpg"])
    }
}

struct DatesAndNumbersTests {
    // T-7f47336e
    @Test func writesEveryOfferedFormatWithEverySeparator() {
        let date = "2026-05-04T08:09:07"
        func formatted(_ format: BatchRenameDateFormat, _ separator: BatchRenameDateSeparator = .hyphen) -> String {
            BatchRename.formatDate(date, BatchRenameSettings(dateFormat: format, dateSeparator: separator))
        }
        #expect(formatted(.ymd) == "2026-05-04")
        #expect(formatted(.ymdHM, .dot) == "2026.05.04.08.09")
        #expect(formatted(.ymdHMS, .space) == "2026 05 04 08 09 07")
        #expect(formatted(.dmy, .underscore) == "04_05_2026")
        #expect(formatted(.dmyy, .none) == "040526")
        #expect(formatted(.mdy) == "05-04-2026")
        #expect(formatted(.yymd) == "26-05-04")
        #expect(formatted(.ym) == "2026-05")
        #expect(BatchRename.formatDate("2009-01-02T00:00:00", BatchRenameSettings(dateFormat: .dmyy)) == "02-01-09")
    }

    // T-0869c080
    @Test func describesAFormatWithItsSeparator() {
        #expect(BatchRename.describeDateFormat(.ymd, separator: .hyphen) == "YYYY-MM-DD")
        #expect(BatchRename.describeDateFormat(.dmyy, separator: .none) == "DDMMYY")
        #expect(BatchRename.describeDateFormat(.ymdHM, separator: .space) == "YYYY MM DD HH mm")
    }

    // T-1fe6d27f
    @Test func numbersByStartAndStep() {
        #expect(BatchRename.formatNumber(BatchRenameSettings(startAt: 0, step: 10), index: 3, count: 4) == "30")
        #expect(
            BatchRename.formatNumber(
                BatchRenameSettings(nameFormat: .counter, digits: .fixed(3)), index: 0, count: 1) == "001")
        #expect(
            BatchRename.formatNumber(
                BatchRenameSettings(nameFormat: .counter, digits: .fixed(2)), index: 199, count: 200) == "200")
    }

    // T-a63efd63
    @Test func readsADateItCantMakeSenseOfAsAllZerosRatherThanFailing() {
        #expect(BatchRename.formatDate("not a date", BatchRenameSettings(dateFormat: .ymd)) == "0000-00-00")
    }

    // T-44b184db
    @Test func readsAMomentOnThisMacsClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 18, minute: 2, second: 11)))
        #expect(BatchRename.toLocalDateTime(date) == "2026-05-14T18:02:11")
    }
}

struct SavedSettingsTests {
    // T-a67cdf09
    @Test func keepsWhatIsValidAndPutsTheDefaultInPlaceOfAnythingElse() {
        #expect(BatchRename.sanitizeSettings(nil) == BatchRenameSettings.defaults)
        let read = BatchRename.sanitizeSettings(
            .object([
                "mode": .string("format"), "nameFormat": .string("date"), "dateSource": .string("taken"),
                "dateFormat": .string("dmyy"), "dateSeparator": .string(""), "separator": .string("_"),
                "digits": .number(3), "startAt": .number(7.6), "step": .number(-2), "find": .number(42),
                "useRegex": .string("yes"), "onConflict": .string("skip"), "applyTo": .string("sideways"),
            ]))
        #expect(read.mode == .format)
        #expect(read.nameFormat == .date)
        #expect(read.dateSource == .taken)
        #expect(read.dateFormat == .dmyy)
        #expect(read.dateSeparator == .none)
        #expect(read.separator == .underscore)
        #expect(read.digits == .fixed(3))
        #expect(read.startAt == 8)
        #expect(read.step == 1)
        #expect(read.find == "")
        #expect(!read.useRegex)
        #expect(read.onConflict == .skip)
        #expect(read.applyTo == .name)
    }

    // T-15bdf632
    @Test func takesTheDefaultForNumbersThatArentNumbersAndKeepsLongTextShort() {
        let read = BatchRename.sanitizeSettings(
            .object([
                "startAt": .number(.infinity), "step": .string("3"),
                "customName": .string(String(repeating: "x", count: 400)), "matchCase": .string("true"),
                "keepNames": .number(1), "mode": .null,
            ]))
        #expect(read.startAt == BatchRenameSettings.defaults.startAt)
        #expect(read.step == BatchRenameSettings.defaults.step)
        #expect(!read.matchCase)
        #expect(!read.keepNames)
        #expect(read.mode == .replace)
        #expect(read.customName.count == 255)
        #expect(BatchRename.sanitizeSettings(.object(["startAt": .number(2e12)])).startAt == 999_999_999)
    }

    // T-003a9362
    @Test func dropsPresetsWithoutANameOrWithOneAlreadyUsedAndKeepsAtMostTheLimit() {
        let presets = BatchRename.sanitizePresets(
            .array([
                .object(["name": .string(" Photos "), "settings": .object(["mode": .string("format")])]),
                .object(["name": .string("photos"), "settings": .object([:])]),
                .object(["name": .string(""), "settings": .object([:])]),
                .null,
                .object(["settings": .object([:])]),
            ]))
        #expect(presets == [BatchRenamePreset(name: "Photos", settings: BatchRenameSettings(mode: .format))])
        #expect(BatchRename.sanitizePresets(.string("x")) == [])
        let many = (0..<(BatchRename.maxPresets + 5)).map { index in
            JSONNode.object(["name": .string("p\(index)"), "settings": .object([:])])
        }
        #expect(BatchRename.sanitizePresets(.array(many)).count == BatchRename.maxPresets)
    }

    @Test func theStandardSanitizersWriteWhatTheStateHolds() throws {
        #expect(BatchRenameSanitizers.standard.settings(nil) == BatchRenameSanitizers.defaultSettings)
        #expect(BatchRenameSanitizers.standard.settings(.string("x")) == BatchRenameSanitizers.defaultSettings)
        #expect(BatchRenameSanitizers.standard.presets(.object([:])) == .array([]))
        let kept = BatchRenameSanitizers.standard.presets(
            .array([.object(["name": .string("A"), "settings": .object(["digits": .string("auto")])])]))
        let preset = try #require(kept.array?.first?.object)
        #expect(preset["name"] == .string("A"))
        #expect(preset["settings"]?["digits"] == .string("auto"))
        #expect(preset["settings"]?["startAt"] == .number(1))
    }
}

struct PlanTests {
    // T-ba89cb89
    @Test func renamesWhatChangesAndCountsWhatDoesnt() {
        let result = plan(BatchRenameSettings(find: "IMG_", replaceWith: "Lisbon "), ["IMG_1.jpg", "notes.txt"])
        #expect(result.items.map(outcome) == ["Lisbon 1.jpg", "unchanged"])
        #expect(
            (result.renameCount, result.unchangedCount, result.skippedCount, result.blockingCount) == (1, 1, 0, 0))
    }

    // T-e3b3448b
    @Test func numbersANameTakenBySomethingElseInTheFolderAndTheNextFreeNumber() {
        let result = plan(
            BatchRenameSettings(find: "IMG_", replaceWith: "Lisbon "), ["IMG_1.jpg"],
            folderNames: ["IMG_1.jpg", "Lisbon 1.jpg", "Lisbon 1 2.jpg", ".hidden"])
        #expect(result.items.map(outcome) == ["Lisbon 1 3.jpg"])
        guard case .rename(_, let segments, let added, _, _, _) = result.items[0] else {
            Issue.record("not renamed")
            return
        }
        #expect(added == 3)
        #expect(segments == [seg("Lisbon ", true), seg("1", false), seg(" 3", true), seg(".jpg", false)])
    }

    // T-cd7d8070
    @Test func numbersRepeatsInsideTheBatchInOrderWithFormatsSeparator() {
        let result = plan(
            BatchRenameSettings(mode: .format, nameFormat: .date, customName: "Trip", separator: .underscore),
            ["a.jpg", "b.jpg", "c.png"])
        #expect(result.items.map(outcome) == ["Trip_2026-09-30.jpg", "Trip_2026-09-30_2.jpg", "Trip_2026-09-30.png"])
    }

    // T-ec74d627
    @Test func numbersThousandsOfItemsWantingOneNameWithoutLookingFromTwoForEach() {
        let itemNames = (0..<20_000).map { "IMG_\($0).jpg" }
        // A taken number in the middle is still passed over.
        let started = ContinuousClock.now
        let result = plan(
            BatchRenameSettings(find: "IMG_\\d+", replaceWith: "Lisbon", useRegex: true), itemNames,
            folderNames: itemNames + ["Lisbon 500.jpg"])
        #expect(ContinuousClock.now - started < .seconds(10))
        let given = result.items.map(outcome)
        #expect(Array(given.prefix(3)) == ["Lisbon.jpg", "Lisbon 2.jpg", "Lisbon 3.jpg"])
        #expect(given[498] == "Lisbon 499.jpg")
        #expect(given[499] == "Lisbon 501.jpg")
        #expect(Set(given).count == 20_000)
    }

    // T-2d7333cf
    @Test func countsNamesAsTheDiskDoesCaseAndAccentsUnlessTheDiskTellsCaseApart() {
        let removeX = BatchRenameSettings(find: "x", replaceWith: "")
        #expect(plan(removeX, ["Ax.txt"], folderNames: ["Ax.txt", "a.TXT"]).items.map(outcome) == ["A 2.txt"])
        #expect(
            plan(removeX, ["Ax.txt"], folderNames: ["Ax.txt", "a.TXT"], caseSensitive: true).items.map(outcome)
                == ["A.txt"])
        // "é" typed as one character, and as "e" with an accent after it.
        #expect(
            plan(removeX, ["cafx\u{E9}.txt"], folderNames: ["cafx\u{E9}.txt", "cafe\u{301}.txt"]).items.map(outcome)
                == ["caf\u{E9} 2.txt"])
        #expect(
            BatchRename.nameKey("Cafe\u{301}", caseSensitive: false)
                == BatchRename.nameKey("caf\u{E9}", caseSensitive: false))
    }

    // T-5a9b05b3
    @Test func letsItemsSwapNamesAndChangeOnlyTheCaseOfTheirOwn() {
        // On a disk that minds case, "A" is free for "a" while "A.TXT" stays as it is.
        let minded = plan(
            BatchRenameSettings(mode: .changeCase, caseStyle: .upper, applyTo: .both), ["a", "A.TXT"],
            caseSensitive: true)
        #expect(minded.items.map(outcome) == ["A", "unchanged"])
        let ownCase = plan(BatchRenameSettings(mode: .changeCase, caseStyle: .upper), ["photo.jpg"])
        #expect(ownCase.items.map(outcome) == ["PHOTO.jpg"])
        // File 1 and File 2 numbered the other way round: each takes the other's name.
        let reorder = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: BatchRenameSettings(mode: .format), items: [item("File 2"), item("File 1")],
                folders: ["/trip": BatchRenameFolder(names: ["File 1", "File 2"], caseSensitive: false)], now: now))
        #expect(reorder.items.map(outcome) == ["File 1", "File 2"])
    }

    // T-8e703ba3
    @Test func leavesAClashingItemAsItIsWithSkipAndSettlesTheRestAroundItsName() {
        // "b" can't take "c" (taken outside the batch), so it stays "b"; "a" wanted "b" and now finds it taken too.
        let both = plan(
            BatchRenameSettings(find: "^(a|b)$", replaceWith: "$1x", useRegex: true, onConflict: .skip), ["a", "b"],
            folderNames: ["a", "b", "ax", "bx"])
        #expect(both.items.map(outcome) == ["skippedTaken:ax", "skippedTaken:bx"])
        let chainSettings = BatchRenameSettings(find: "^(.)$", replaceWith: "$1$1", useRegex: true, onConflict: .skip)
        let chain = plan(chainSettings, ["a", "b"], folderNames: ["a", "b", "bb"])
        #expect(chain.items.map(outcome) == ["aa", "skippedTaken:bb"])
        #expect((chain.renameCount, chain.skippedCount, chain.blockingCount) == (1, 1, 0))
        // "File 1" can't become "File 2" (another item outside the batch has it), so it stays "File 1", and the first
        // item, which was to become "File 1", is skipped too.
        let cascade = plan(
            BatchRenameSettings(mode: .format, onConflict: .skip), ["x.txt", "File 1.txt"],
            folderNames: ["x.txt", "File 1.txt", "File 2.txt"])
        #expect(cascade.items.map(outcome) == ["skippedTaken:File 1.txt", "skippedTaken:File 2.txt"])
        // "File 1.txt" keeps its name, so it is in the folder: no other item is getting it.
        #expect(
            cascade.items[0]
                == .problem(
                    proposedName: "File 1.txt", segments: segmentsOf(cascade.items[0]),
                    problem: .skippedTaken(byItemInBatch: false)))
        #expect((cascade.renameCount, cascade.skippedCount) == (0, 2))
    }

    // T-c909ed2e
    @Test func skipsAWholeBatchWhoseNamesEachWaitOnTheNextOnesAtOnce() {
        // "File 1" … "File 10000" numbered from 2: the last can't take the unselected "File 10001", so it keeps its
        // name, which the one before it wanted, and so on back.
        let folderNames = (0..<10_001).map { "File \($0 + 1).txt" }
        let started = ContinuousClock.now
        let result = plan(
            BatchRenameSettings(mode: .format, startAt: 2, onConflict: .skip), Array(folderNames.prefix(10_000)),
            folderNames: folderNames)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(result.renameCount == 0)
        #expect(result.skippedCount == 10_000)
        guard case .problem(let proposedName, _, let problem) = result.items[0] else {
            Issue.record("not a problem")
            return
        }
        #expect(proposedName == "File 2.txt")
        #expect(problem == .skippedTaken(byItemInBatch: false))
    }

    // T-ec7ff9f5
    @Test func settlesClashesAsSettlingTheFolderAgainUntilNothingMoreIsSkippedWould() {
        var rng = SeededRandom(seed: 8_053)
        for _ in 0..<3_000 {
            let input = ClashCase.random(&rng)
            let label = "\(input.settings) \(input.items.map(\.name)) \(input.folders) \(input.cannotRename.keys)"
            #expect(
                BatchRename.planBatchRename(input).items.map(ClashCase.outcomeWithClash) == ClashCase.settle(input),
                Comment(rawValue: label))
        }
    }

    // T-463e5c4b
    @Test func holdsTheRenameWithDontRenameUntilTheClashIsFixed() {
        let result = plan(
            BatchRenameSettings(find: "IMG_", replaceWith: "Lisbon ", onConflict: .block), ["IMG_1.jpg", "IMG_2.jpg"],
            folderNames: ["IMG_1.jpg", "IMG_2.jpg", "Lisbon 1.jpg"])
        #expect(result.items.map(outcome) == ["taken:Lisbon 1.jpg", "Lisbon 2.jpg"])
        guard case .problem(_, _, let problem) = result.items[0] else {
            Issue.record("not a problem")
            return
        }
        #expect(problem == .taken(byItemInBatch: false))
        #expect(result.blockingCount == 1)
        let inBatch = plan(
            BatchRenameSettings(mode: .format, nameFormat: .date, onConflict: .block), ["a.jpg", "b.jpg"])
        #expect(inBatch.items.map(outcome) == ["File 2026-09-30.jpg", "taken:File 2026-09-30.jpg"])
        guard case .problem(_, _, let second) = inBatch.items[1] else {
            Issue.record("not a problem")
            return
        }
        #expect(second == .taken(byItemInBatch: true))
    }

    // T-e8c4e7ae
    @Test func neverRenamesToAnInvalidNameWhateverTheSetting() {
        let slash = plan(BatchRenameSettings(find: "-", replaceWith: "/"), ["a-b.txt"])
        #expect(slash.items.map(outcome) == ["invalid:a/b.txt"])
        #expect(slash.blockingCount == 1)
        let long = plan(BatchRenameSettings(mode: .add, addText: String(repeating: "x", count: 260)), ["a.txt"])
        guard case .problem(_, _, let tooLong) = long.items[0] else {
            Issue.record("not a problem")
            return
        }
        #expect(tooLong == .invalid(message: "The name is too long."))
        let dots = plan(BatchRenameSettings(find: "a", replaceWith: ".", applyTo: .both), ["a"])
        #expect(dots.items.map(outcome) == ["invalid:."])
        // Nothing left before the extension: not a hidden ".txt".
        let onlyExtension = plan(BatchRenameSettings(find: "notes", replaceWith: ""), ["notes.txt"])
        guard case .problem(_, _, let empty) = onlyExtension.items[0] else {
            Issue.record("not a problem")
            return
        }
        #expect(empty == .invalid(message: "The name can\u{2019}t be only an extension."))
    }

    // T-ef371b87
    @Test func skipsAnItemThatCantBeRenamedAndKeepsItsNameTaken() {
        let locked = ["/trip/locked.txt": "The item is locked."]
        let result = plan(
            BatchRenameSettings(mode: .format, customName: "x"), ["locked.txt", "b.txt"], cannotRename: locked)
        #expect(result.items.map(outcome) == ["cannotRename:x 1.txt", "x 2.txt"])
        #expect((result.skippedCount, result.blockingCount, result.renameCount) == (1, 0, 1))
        // Another item asking for the locked item's name finds it taken.
        let wanted = plan(
            BatchRenameSettings(find: "draft", replaceWith: "locked"), ["locked.txt", "draft.txt"],
            cannotRename: locked)
        #expect(wanted.items.map(outcome) == ["unchanged", "locked 2.txt"])
    }

    // T-f1d7401f
    @Test func shortensANameThatANumberMakesTooLongAndHoldsOneThatCant() {
        let long = String(repeating: "a", count: 251) + ".txt"
        let shortened = plan(
            BatchRenameSettings(find: "x", replaceWith: String(repeating: "a", count: 251)), ["x.txt"],
            folderNames: ["x.txt", long])
        let stem = String(repeating: "a", count: 249)
        #expect(shortened.items.map(outcome) == ["\(stem) 2.txt"])
        #expect(segmentsOf(shortened.items[0]) == [seg("\(stem) 2", true), seg(".txt", false)])
        // Only the extension is long: nothing before it can give way.
        let ext = String(repeating: "e", count: 252)
        let held = plan(
            BatchRenameSettings(find: "x", replaceWith: "y"), ["x.\(ext)"], folderNames: ["x.\(ext)", "y.\(ext)"])
        #expect(held.items.map(outcome) == ["invalid:y 2.\(ext)"])
        #expect(held.blockingCount == 1)
    }

    // T-1b9a33e7
    @Test func warnsWhenANewNameStartsWithADot() {
        let result = plan(BatchRenameSettings(mode: .add, addText: ".", addWhere: .before), ["config"])
        guard case .rename(let name, _, _, _, _, let hidden) = result.items[0] else {
            Issue.record("not renamed")
            return
        }
        #expect(name == ".config")
        #expect(hidden)
    }

    // T-3c4e8603
    @Test func settlesEachFolderOnItsOwnSearchResultsMayShareNamesAcrossFolders() {
        let result = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: BatchRenameSettings(find: "draft ", replaceWith: ""),
                items: [
                    item("draft notes.txt", path: "/a/draft notes.txt"),
                    item("draft notes.txt", path: "/b/draft notes.txt"),
                ],
                folders: [
                    "/a": BatchRenameFolder(names: ["draft notes.txt"], caseSensitive: false),
                    "/b": BatchRenameFolder(names: ["draft notes.txt", "notes.txt"], caseSensitive: false),
                ], now: now))
        #expect(result.items.map(outcome) == ["notes.txt", "notes 2.txt"])
    }

    // T-94430ddd
    @Test func takesAFolderItKnowsNothingOfToHoldOnlyTheItemsBeingRenamed() {
        let result = BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: BatchRenameSettings(mode: .format, nameFormat: .date, dateSource: .created),
                items: [item("a.jpg", path: "/elsewhere/a.jpg"), item("b.jpg", path: "/elsewhere/b.jpg")], now: now))
        #expect(result.items.map(outcome) == ["File 2026-09-30.jpg", "File 2026-09-30 2.jpg"])
    }

    // T-477d48d3
    @Test func holdsNothingBackWhenTheSettingsThemselvesAreBrokenNothingIsRenamed() {
        let result = plan(BatchRenameSettings(find: "[", replaceWith: "", useRegex: true), ["a.txt"])
        #expect(result.settingsError != nil)
        #expect(result.renameCount == 0)
    }
}

/// The planning half of batchRenamePlanAndRun.test.ts: the names the plan gives are the ones the test then finds on the
/// disk. That the rename keeps the plan is the execution engine's (P3-08); the plan itself is also checked, over 300
/// cases, by the batch-rename-plan golden.
struct PlanShownTests {
    private let format = BatchRenameSettings(mode: .format)

    private func planned(
        _ folderNames: [String], _ itemPaths: [String], _ settings: BatchRenameSettings, caseSensitive: Bool = false
    ) -> BatchRenamePlan {
        var folders: [String: BatchRenameFolder] = [:]
        for name in folderNames {
            let folder = BatchRename.parentPath(of: name)
            let leaf = String(name.dropFirst(folder.count + 1))
            folders[folder, default: BatchRenameFolder(names: [], caseSensitive: caseSensitive)].names.append(leaf)
        }
        return BatchRename.planBatchRename(
            BatchRenamePlanInput(
                settings: settings,
                items: itemPaths.map { path in
                    item(String(path.dropFirst(BatchRename.parentPath(of: path).count + 1)), path: path)
                }, folders: folders, now: now))
    }

    private func added(_ planItem: BatchRenamePlanItem) -> Int? {
        if case .rename(_, _, let added, _, _, _) = planItem { added } else { nil }
    }

    // T-a966a460
    @Test func numbersATakenNameAlikeWhenFormatHasNoSeparator() {
        var settings = format
        settings.separator = .none
        let result = planned(
            ["/trip/IMG_a.jpg", "/trip/IMG_b.jpg", "/trip/File1.jpg"], ["/trip/IMG_a.jpg", "/trip/IMG_b.jpg"], settings)
        // "File1.jpg" is taken outside the batch: the plan adds a number with a space.
        #expect(result.items.map(outcome) == ["File1 2.jpg", "File2.jpg"])
    }

    // T-5fb53308
    @Test func numbersATakenNameAlikeWithFormatsSeparator() {
        var settings = format
        settings.separator = .underscore
        let result = planned(
            ["/trip/a.jpg", "/trip/b.jpg", "/trip/File_1.jpg"], ["/trip/a.jpg", "/trip/b.jpg"], settings)
        #expect(result.items.map(outcome) == ["File_1_2.jpg", "File_2.jpg"])
    }

    // T-2c22d4ff
    @Test func swapsTwoNamesAndPassesNamesAlongAChainWithoutNumbers() {
        // Listed in reverse: the second becomes "File 1" and the first "File 2".
        let swapped = planned(
            ["/trip/File 1.jpg", "/trip/File 2.jpg"], ["/trip/File 2.jpg", "/trip/File 1.jpg"], format)
        #expect(swapped.items.map(added) == [nil, nil])
        #expect(swapped.items.map(outcome) == ["File 1.jpg", "File 2.jpg"])
        var chainSettings = format
        chainSettings.startAt = 2
        let chain = ["/trip/File 1.jpg", "/trip/File 2.jpg", "/trip/File 3.jpg"]
        #expect(
            planned(chain, chain, chainSettings).items.map(outcome) == ["File 2.jpg", "File 3.jpg", "File 4.jpg"])
    }

    // T-bfffc022
    @Test func givesItemsInSeveralFoldersTheNamesPlannedForEachFolder() {
        let disk = [
            "/trip/a.jpg", "/trip/b.jpg", "/trip/File 3.jpg", "/home/c.jpg", "/home/File 1.jpg", "/home/File 2.jpg",
        ]
        // Numbered across the folders in the order given; each folder settles its own clashes.
        let paths = ["/trip/a.jpg", "/home/c.jpg", "/trip/b.jpg", "/home/File 1.jpg"]
        #expect(
            planned(disk, paths, format).items.map(outcome) == [
                "File 1.jpg", "File 2 2.jpg", "File 3 2.jpg", "File 4.jpg",
            ])
    }

    // T-661d40ce
    @Test func changesOnlyTheCaseOfANameInPlaceAndNumbersItOnADiskThatMindsCase() {
        let lower = BatchRenameSettings(mode: .changeCase, caseStyle: .lower)
        let paths = ["/trip/Notes.txt", "/trip/Todo.txt"]
        #expect(planned(paths, paths, lower).items.map(outcome) == ["notes.txt", "todo.txt"])
        #expect(
            planned(["/trip/Notes.txt", "/trip/notes.txt", "/trip/Todo.txt"], paths, lower, caseSensitive: true)
                .items.map(outcome) == ["notes 2.txt", "todo.txt"])
    }

    // T-669eb707
    @Test func treatsANameWithItsAccentsTypedAnotherWayAsTakenAsTheDiskDoes() {
        let nfd = "Re\u{301}sume\u{301}"
        let settings = BatchRenameSettings(find: "^[ab]$", replaceWith: nfd, useRegex: true)
        let result = planned(
            ["/trip/a.txt", "/trip/b.txt", "/trip/R\u{E9}sum\u{E9}.txt"], ["/trip/a.txt", "/trip/b.txt"], settings)
        #expect(
            result.items.map(outcome).map { Data($0.utf8) } == ["\(nfd) 2.txt", "\(nfd) 3.txt"].map { Data($0.utf8) })
    }

    // T-988f1c26
    @Test func leavesTheItemsSkipLeavesAndGivesTheRestTheirPlannedNames() {
        var settings = format
        settings.onConflict = .skip
        let result = planned(
            ["/trip/a.jpg", "/trip/b.jpg", "/trip/c.jpg", "/trip/File 2.jpg"],
            ["/trip/a.jpg", "/trip/b.jpg", "/trip/c.jpg"], settings)
        #expect(result.skippedCount == 1)
        #expect(result.items.map(outcome) == ["File 1.jpg", "skippedTaken:File 2.jpg", "File 3.jpg"])
    }

    // T-20addbaa
    @Test func leavesAnItemAloneWhenTheNumberedNameItGetsIsTheOneItHas() {
        // "File 1 2.jpg" asks for "File 1.jpg", which is taken, and would be numbered " 2": its own name.
        var settings = format
        settings.startAt = 1
        let result = planned(
            ["/trip/File 1.jpg", "/trip/File 1 2.jpg", "/trip/a.jpg"], ["/trip/File 1 2.jpg", "/trip/a.jpg"], settings)
        #expect(result.items.map(outcome) == ["unchanged", "File 2.jpg"])
    }

    // T-107fe08c
    // The agreement with the rename is checked against the execution engine (P3-08); here the plan is checked for names
    // that clash in every way, a name given only once in a folder, none taken that was not free, and every old name
    // either kept or given up.
    @Test func plansNamesThatClashInEveryWayWithoutGivingAnyNameTwice() {
        let pool = [
            "a.jpg", "A.jpg", "b.jpg", "File 1.jpg", "File 2.jpg", "File 3.jpg", "File1.jpg", "File-1.jpg",
            "File_2.jpg", "file 1.JPG", "File 1 2.jpg", "R\u{E9}sum\u{E9}.jpg", "notes", "Notes.txt",
        ]
        var rng = SeededRandom(seed: 61)
        var renamed = 0
        for _ in 1...60 {
            let caseSensitive = rng.chance(0.25)
            func key(_ name: String) -> String { BatchRename.nameKey(name, caseSensitive: caseSensitive) }
            var onDisk: [String: String] = [:]
            for name in rng.shuffled(pool).prefix(rng.integer(2, 8)) { onDisk[key(name)] = name }
            let diskNames = Array(onDisk.values)
            let itemNames = Array(rng.shuffled(diskNames).prefix(rng.integer(1, diskNames.count)))
            var settings = rng.pick([
                BatchRenameSettings(mode: .format, separator: rng.pick([.space, .hyphen, .underscore, .none])),
                BatchRenameSettings(mode: .format, nameFormat: .counter, startAt: rng.integer(0, 3)),
                BatchRenameSettings(mode: .changeCase, caseStyle: rng.pick([.lower, .upper, .title])),
                BatchRenameSettings(
                    find: rng.pick(["a", "1", "File", " "]), replaceWith: rng.pick(["", "File", "2", "A"])),
                BatchRenameSettings(mode: .add, addText: rng.pick([" 1", "1", " 2"])),
            ])
            settings.onConflict = rng.pick([.number, .skip])
            let result = BatchRename.planBatchRename(
                BatchRenamePlanInput(
                    settings: settings, items: itemNames.map { item($0) },
                    folders: ["/trip": BatchRenameFolder(names: diskNames, caseSensitive: caseSensitive)], now: now))
            // The names the folder ends up with: kept ones and given ones.
            var after = Set(diskNames.map(key))
            for (name, planItem) in zip(itemNames, result.items) {
                if case .rename = planItem { after.remove(key(name)) }
            }
            for (name, planItem) in zip(itemNames, result.items) {
                if case .rename(let newName, _, _, _, _, _) = planItem {
                    renamed += 1
                    #expect(
                        after.insert(key(newName)).inserted, Comment(rawValue: "\(newName) given twice for \(name)"))
                }
            }
        }
        // Most cases rename something: the check isn't made on nothing.
        #expect(renamed > 40)
    }
}

// MARK: Checking the plan against the simplest way to settle clashes

/// mulberry32: the same numbers for the same seed, so a failure can be run again.
struct SeededRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var value = state
        value = (value ^ (value >> 15)) &* (value | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }

    mutating func chance(_ probability: Double) -> Bool { next() < probability }

    mutating func integer(_ least: Int, _ most: Int) -> Int { least + Int(next() * Double(most - least + 1)) }

    mutating func pick<T>(_ items: [T]) -> T { items[integer(0, items.count - 1)] }

    mutating func shuffled<T>(_ items: [T]) -> [T] {
        var keyed = items.map { (next(), $0) }
        keyed.sort { $0.0 < $1.0 }
        return keyed.map(\.1)
    }
}

private enum ClashCase {
    static func outcomeWithClash(_ planItem: BatchRenamePlanItem) -> String {
        if case .problem(_, _, let problem) = planItem {
            switch problem {
            case .taken(let byItem), .skippedTaken(let byItem):
                return "\(outcome(planItem)):\(byItem ? "batch" : "folder")"
            default: break
            }
        }
        return outcome(planItem)
    }

    /// The plan with Skip or Don't Rename, worked out the slow way: each item skipped keeps its old name, so the folder
    /// is settled again from the start until no new item is skipped.
    static func settle(_ input: BatchRenamePlanInput) -> [String] {
        let proposed = BatchRename.proposeNames(settings: input.settings, items: input.items, now: input.now).names
        let folder = input.folders["/trip"]
        func key(_ name: String) -> String { BatchRename.nameKey(name, caseSensitive: folder?.caseSensitive ?? false) }
        var result = input.items.map { _ in "unchanged" }
        var leftAsIs = Set<Int>()
        for (index, name) in proposed.enumerated() {
            guard case .renamed(let newName, _, _, let emptyName) = name else {
                leftAsIs.insert(index)
                continue
            }
            let invalid = emptyName || ItemNames.error(for: newName) != nil
            if invalid || input.cannotRename[input.items[index].path] != nil {
                result[index] = "\(invalid ? "invalid" : "cannotRename"):\(newName)"
                leftAsIs.insert(index)
            }
        }
        var newlySkipped = true
        while newlySkipped {
            newlySkipped = false
            var taken = Set((folder?.names ?? []).map(key))
            var given = Set<String>()
            for (index, each) in input.items.enumerated() {
                if leftAsIs.contains(index) { taken.insert(key(each.name)) } else { taken.remove(key(each.name)) }
            }
            for (index, name) in proposed.enumerated() {
                guard !leftAsIs.contains(index), case .renamed(let newName, _, _, _) = name else { continue }
                if !taken.contains(key(newName)) {
                    taken.insert(key(newName))
                    given.insert(key(newName))
                    result[index] = newName
                    continue
                }
                let skip = input.settings.onConflict == .skip
                let by = given.contains(key(newName)) ? "batch" : "folder"
                result[index] = "\(skip ? "skippedTaken" : "taken"):\(newName):\(by)"
                if skip {
                    leftAsIs.insert(index)
                    newlySkipped = true
                }
            }
        }
        return result
    }

    /// A few numbered files, some of them selected in any order, renamed so that their new names often are each
    /// other's old ones or the unselected files'.
    static func random(_ rng: inout SeededRandom) -> BatchRenamePlanInput {
        var folderNames: [String] = []
        for number in 1...8 where rng.next() < 0.7 {
            folderNames.append("\(rng.next() < 0.8 ? "File" : "file") \(number).txt")
        }
        var selected: [String] = []
        for name in folderNames where rng.next() < 0.6 { selected.append(name) }
        selected = rng.shuffled(selected)
        var settings: BatchRenameSettings
        switch rng.integer(0, 2) {
        case 0: settings = BatchRenameSettings(mode: .format, startAt: rng.integer(1, 4), step: rng.integer(1, 2))
        case 1:
            settings = BatchRenameSettings(
                find: String(rng.integer(1, 8)), replaceWith: String(rng.integer(1, 9)))
        default: settings = BatchRenameSettings(mode: .changeCase, caseStyle: rng.next() < 0.5 ? .lower : .title)
        }
        settings.onConflict = rng.next() < 0.8 ? .skip : .block
        let locked = selected.first { _ in rng.next() < 0.1 }
        return BatchRenamePlanInput(
            settings: settings, items: selected.map { item($0) },
            folders: ["/trip": BatchRenameFolder(names: folderNames, caseSensitive: rng.next() < 0.3)],
            cannotRename: locked.map { ["/trip/\($0)": "The item is locked."] } ?? [:], now: now)
    }
}
