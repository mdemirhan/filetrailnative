// Port of packages/core/src/fs/copyPasteNames.test.ts, checked against tools/parity/golden/keep-both-names.ts and fit-name.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct CopyPasteNamesTests {
    /// A folder "/target" holding the given paths.
    struct Disk {
        var taken: Set<String>
        var failing: Set<String> = []

        init(_ taken: String...) {
            self.taken = Set(taken.map { "/target/\($0)" })
        }

        /// What lstat answers: a path found or failing for another reason than ENOENT is "there".
        func exists(_ path: String) -> Bool {
            taken.contains(path) || failing.contains(path)
        }
    }

    static func duplicate(
        _ name: String, _ disk: Disk = Disk(), isDirectory: Bool = false, isPackage: Bool? = nil
    ) throws -> String {
        try CopyPasteNames.resolveDuplicateName(
            sourceName: name, in: "/target",
            options: .init(isDirectory: isDirectory, isPackage: isPackage), exists: disk.exists)
    }

    // Not in the reference's own tests: copy numbers are doubles there, so they never trap.
    @Test func copyNumbersBeyondIntKeepCounting() throws {
        #expect(
            try Self.duplicate("x copy 9223372036854775807.txt") == "/target/x copy 9223372036854776000.txt")
        #expect(
            try Self.duplicate("x copy 99999999999999999999.txt") == "/target/x copy 100000000000000000000.txt")
        #expect(try Self.duplicate("x copy 9007199254740991.txt") == "/target/x copy 9007199254740992.txt")
        #expect(try Self.duplicate("x copy 9007199254740992.txt") == "/target/x copy 9007199254740992.txt")
        // Adding the attempt count changes nothing at 1e23, so the reference's loop never runs.
        #expect(throws: CopyPasteNames.NoFreeName.self) {
            try Self.duplicate("x copy 123456789012345678901234.txt")
        }
        // The reference would loop here for good; the port gives up after the usual attempts.
        let busy = Disk("x copy 9007199254740992.txt")
        #expect(throws: CopyPasteNames.NoFreeName.self) {
            try Self.duplicate("x copy 9007199254740992.txt", busy)
        }
    }

    // T-27257761
    @Test func resolvesKeepBothPathsFromTheSourceBasename() throws {
        let disk = Disk("report copy.txt")
        let path = try CopyPasteNames.resolveKeepBothDestinationPath(
            sourcePath: "/source/report.txt", destinationPath: "/target/report.txt", exists: disk.exists)
        #expect(path == "/target/report copy 2.txt")
    }

    // T-475241a4
    @Test func generatesDuplicateNamesForFilesWithAndWithoutExtensions() throws {
        let disk = Disk("notes copy.txt", "archive copy")
        #expect(try Self.duplicate("notes.txt", disk) == "/target/notes copy 2.txt")
        #expect(try Self.duplicate("archive", disk) == "/target/archive copy 2")
    }

    // T-93af3adf
    @Test func numbersACopyOfACopyInsteadOfAddingAnotherCopy() throws {
        let disk = Disk("notes copy.txt", "notes copy 2.txt", "plan copy 2.md")
        #expect(try Self.duplicate("notes copy.txt", disk) == "/target/notes copy 3.txt")
        #expect(try Self.duplicate("plan copy 2.md", disk) == "/target/plan copy 3.md")
        #expect(try Self.duplicate("Photos copy", disk, isDirectory: true) == "/target/Photos copy 2")
        #expect(try Self.duplicate("big copy 99999", disk) == "/target/big copy 100000")
    }

    // T-58e31428
    @Test func keepsNamesThatOnlyLookALittleLikeCopies() throws {
        // A file called "copy", a "copy 1" (Finder never makes one) and "copycat".
        #expect(try Self.duplicate("copy.txt") == "/target/copy copy.txt")
        #expect(try Self.duplicate("draft copy 1.txt") == "/target/draft copy 1 copy.txt")
        #expect(try Self.duplicate("a copycat.txt") == "/target/a copycat copy.txt")
    }

    // T-0b9ea230
    @Test func usesTheFirstCopySuffixWhenTheDestinationIsStillFree() throws {
        #expect(try Self.duplicate("fresh.txt") == "/target/fresh copy.txt")
    }

    // T-8db3141c
    @Test func keepsFolderNamesWholeExceptForBundles() throws {
        #expect(try Self.duplicate("Photos 2024.v2", isDirectory: true) == "/target/Photos 2024.v2 copy")
        #expect(try Self.duplicate("Tool.app", isDirectory: true) == "/target/Tool copy.app")
        #expect(try Self.duplicate("report.v2") == "/target/report copy.v2")
    }

    // T-940505a6
    @Test func keepsTheExtensionAtTheEndForDocumentPackagesToo() throws {
        #expect(try Self.duplicate("Talk.key", isDirectory: true) == "/target/Talk copy.key")
        #expect(try Self.duplicate("Trip.photoslibrary", isDirectory: true) == "/target/Trip copy.photoslibrary")
    }

    // T-0635b28a
    @Test func goesByWhatItIsToldAboutAFolderBeingAPackageBeforeItsExtension() throws {
        #expect(
            try Self.duplicate("Model.custompkg", isDirectory: true, isPackage: true) == "/target/Model copy.custompkg")
        #expect(
            try Self.duplicate("Movie.fcpxbundle", isDirectory: true, isPackage: false)
                == "/target/Movie.fcpxbundle copy")
        #expect(
            try Self.duplicate("Backup.sparsebundle", isDirectory: true) == "/target/Backup copy.sparsebundle")
    }

    @Test func askedForAFolderThePackageAnswerWinsOverTheExtension() throws {
        func keepBoth(_ answer: Bool?) throws -> String {
            try CopyPasteNames.resolveKeepBothDestinationPath(
                sourcePath: "/source/Movie.fcpxbundle", destinationPath: "/target/Movie.fcpxbundle",
                options: .init(isDirectory: true), isPackageFolder: { _ in answer }, exists: { _ in false })
        }
        #expect(try keepBoth(false) == "/target/Movie.fcpxbundle copy")
        #expect(try keepBoth(true) == "/target/Movie copy.fcpxbundle")
        #expect(try keepBoth(nil) == "/target/Movie copy.fcpxbundle")
    }

    // T-4e1e808c
    @Test func treatsCompressedTarArchivesAsHavingOneExtension() throws {
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".TAR.GZ"] {
            #expect(try Self.duplicate("backup\(ext)") == "/target/backup copy\(ext)")
        }
    }

    // T-93700bb1
    @Test(arguments: [
        ("decomposed accents", String(repeating: "e\u{301}", count: 90)),
        ("emoji", String(repeating: "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 12)),
        ("multibyte letters", String(repeating: "\u{65E5}\u{672C}\u{8A9E}", count: 28)),
    ])
    func neverSplitsACharacterWhenShorteningALongName(label: String, base: String) throws {
        let name = "\(base).txt"
        #expect(name.utf8.count > 240, "\(label)")
        let copyName = String(try Self.duplicate(name).dropFirst("/target/".count))
        #expect(copyName.utf8.count <= 255)
        #expect(copyName.hasSuffix(" copy.txt"))
        let kept = String(copyName.dropLast(" copy.txt".count))
        #expect(base.unicodeScalars.starts(with: kept.unicodeScalars))
        let unit = try #require(base.first)
        // Whole characters only: what is kept is a run of complete repeats of the character.
        #expect(kept.unicodeScalars.count % unit.unicodeScalars.count == 0)
        #expect(!kept.isEmpty)
    }

    // T-3430b9a8
    @Test func treatsANameAsTakenWhenLookingItUpFailsForAnyReasonOtherThanItMissing() throws {
        var disk = Disk()
        disk.failing = ["/target/a copy.txt"]
        #expect(try Self.duplicate("a.txt", disk) == "/target/a copy 2.txt")
    }

    @Test func throwsAfterTenThousandTakenNames() {
        let error = #expect(throws: CopyPasteNames.NoFreeName.self) {
            try CopyPasteNames.resolveDuplicateName(sourceName: "x.txt", in: "/target", exists: { _ in true })
        }
        #expect(error?.description == "Couldn't find a free name for \u{201C}x.txt\u{201D}.")
    }

    @Test func skipsNamesTheSamePasteHasClaimed() throws {
        let reserved: Set<NameKeys.Exact> = [NameKeys.exactDestinationKey("/target/A copy.txt")]
        let name = try CopyPasteNames.resolveDuplicateName(
            sourceName: "a.txt", in: "/target", reserved: reserved, exists: { _ in false })
        #expect(name == "/target/a copy 2.txt")
        let sensitiveKeys: Set<NameKeys.Exact> = [
            NameKeys.exactDestinationKey("/target/A copy.txt", caseSensitive: true)
        ]
        let sensitive = try CopyPasteNames.resolveDuplicateName(
            sourceName: "a.txt", in: "/target", reserved: sensitiveKeys, options: .init(caseSensitive: true),
            exists: { _ in false })
        #expect(sensitive == "/target/a copy.txt")
    }

    // T-63722dce
    @Test func foldsLetterCaseOnlyOnCaseInsensitiveVolumes() {
        let key = NameKeys.destinationPathKey
        #expect(key("/T/Caf\u{E9}.TXT", false) == key("/t/cafe\u{301}.txt", false))
        #expect(key("/T/Caf\u{E9}.TXT", true) != key("/t/cafe\u{301}.txt", true))
        // Normalization never matters on APFS or HFS+.
        #expect(key("/t/caf\u{E9}", true) == key("/t/cafe\u{301}", true))
        #expect(NameKeys.Exact(key("/t/caf\u{E9}", true)) != NameKeys.Exact("/t/caf\u{E9}"))
    }

    @Test func otherPlacesHaveTheirOwnKeys() {
        #expect(NameKeys.looseKey("CAF\u{C9}") == NameKeys.looseKey("cafe\u{301}"))
        #expect(NameKeys.placeKey("/A/\u{C9}") == NameKeys.placeKey("/a/e\u{301}"))
        #expect(NameKeys.nameKey("A", caseSensitive: true) != NameKeys.nameKey("a", caseSensitive: true))
        #expect(NameKeys.nameKey("A", caseSensitive: false) == NameKeys.nameKey("a", caseSensitive: false))
        #expect(NameKeys.namesMatchIgnoringCase("Caf\u{E9}", "CAFE\u{301}"))
        #expect(!NameKeys.namesMatchIgnoringCase("Cafe", "Caf"))
    }

    // MARK: Case sensitivity

    struct Volume: CopyPasteNames.CaseProbingFileSystem {
        var answer: Bool?
        /// Whether names are told apart by case; decides what a swapped-case lookup finds.
        var caseSensitive: Bool
        var files: [String]

        func isCaseSensitive(_ directory: String) -> Bool? { answer }

        func entries(_ directory: String) -> [String] {
            files.filter { NodePath.dirname($0) == directory }.map { NodePath.basename($0) }
        }

        func lookup(_ path: String) -> CopyPasteNames.Lookup {
            let found = files.firstIndex {
                caseSensitive ? $0 == path : $0.lowercased() == path.lowercased()
            }
            return found.map { .found(dev: 1, ino: UInt64($0 + 10)) } ?? .missing
        }
    }

    // T-7cad0254
    @Test func findsOutWhetherAVolumeIsCaseSensitiveByLookingUpASwappedName() {
        var sensitive = Volume(answer: true, caseSensitive: true, files: ["/target/Readme"])
        #expect(CopyPasteNames.detectCaseSensitivity(sensitive, in: "/target"))
        // Without an answer, looking decides.
        sensitive.answer = nil
        #expect(CopyPasteNames.detectCaseSensitivity(sensitive, in: "/target"))
        // Like APFS: any letter case finds the same item.
        let insensitive = Volume(answer: nil, caseSensitive: false, files: ["/target/Readme"])
        #expect(!CopyPasteNames.detectCaseSensitivity(insensitive, in: "/target"))
    }

    @Test func caseProbeFallsBackToTheFolderItselfAndTheMacDefault() {
        // Nothing in the folder to try: the folder's own name is.
        let sensitive = Volume(answer: nil, caseSensitive: true, files: ["/target"])
        #expect(CopyPasteNames.detectCaseSensitivity(sensitive, in: "/target"))
        // Nothing with a letter to swap anywhere: the default.
        let digits = Volume(answer: nil, caseSensitive: true, files: ["/123/456"])
        #expect(!CopyPasteNames.detectCaseSensitivity(digits, in: "/123"))
        #expect(!CopyPasteNames.detectCaseSensitivity(Volume(answer: nil, caseSensitive: true, files: []), in: "/"))
    }

    @Test func caseProbeIgnoresIdsAJavaScriptNumberCouldNotHold() {
        struct EmptyFiles: CopyPasteNames.CaseProbingFileSystem {
            func isCaseSensitive(_ directory: String) -> Bool? { nil }
            func entries(_ directory: String) -> [String] { ["Readme"] }
            func lookup(_ path: String) -> CopyPasteNames.Lookup { .found(dev: 1, ino: UInt64.max - 1) }
        }
        #expect(!CopyPasteNames.detectCaseSensitivity(EmptyFiles(), in: "/target"))
    }

    @Test func swapsOnlyAsciiLetters() {
        #expect(CopyPasteNames.swapLetterCase("Readme.\u{DF}1") == "rEADME.\u{DF}1")
    }

    @Test func recognizesPackageNamesAndSideFiles() {
        #expect(CopyPasteNames.isPackageName("Tool.APP"))
        #expect(!CopyPasteNames.isPackageName(".app"))
        #expect(!CopyPasteNames.isPackageName("notes.txt"))
        #expect(CopyPasteNames.isFolderViewFile(".DS_Store"))
        #expect(!CopyPasteNames.isFolderViewFile(".ds_store"))
        #expect(CopyPasteNames.isAppleDoubleCompanionName("._a", hasSibling: { $0 == "a" }))
        #expect(!CopyPasteNames.isAppleDoubleCompanionName("._a", hasSibling: { _ in false }))
        #expect(!CopyPasteNames.isAppleDoubleCompanionName("._", hasSibling: { _ in true }))
    }

    // MARK: Golden

    struct KeepBothInput: Codable, Sendable {
        let name: String
        let isFolder: Bool
        let isPackage: Bool?
        let taken: [String]
        let reserved: [String]
        let caseSensitive: Bool
        let allTaken: Bool
    }

    struct KeepBothOutput: Codable, Equatable, Sendable {
        var path: String?
        var error: String?
    }

    @Test func keepBothNamesMatchTheReference() throws {
        let cases: [GoldenCase<KeepBothInput, KeepBothOutput>] = try Golden.load(suite: "keep-both-names")
        #expect(cases.count >= 500)
        Golden.expectMatches(cases) { input in
            // Paths are compared scalar for scalar, as lstat's names are.
            let taken = Set(input.taken.map { NameKeys.Exact("/target/\($0)") })
            let reserved = Set(
                input.reserved.map { NameKeys.exactDestinationKey("/target/\($0)", caseSensitive: input.caseSensitive) }
            )
            do {
                let path = try CopyPasteNames.resolveDuplicateName(
                    sourceName: input.name, in: "/target", reserved: reserved,
                    options: .init(
                        isDirectory: input.isFolder, isPackage: input.isPackage, caseSensitive: input.caseSensitive),
                    exists: { input.allTaken || taken.contains(NameKeys.Exact($0)) })
                return KeepBothOutput(path: path)
            } catch {
                return KeepBothOutput(error: "\(error)")
            }
        }
    }

    struct FitInput: Codable, Sendable {
        let baseName: String
        let suffix: String
        let `extension`: String
    }

    @Test func fitNameMatchesTheReference() throws {
        let cases: [GoldenCase<FitInput, String>] = try Golden.load(suite: "fit-name")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) {
            CopyPasteNames.fitName($0.baseName, suffix: $0.suffix, extension: $0.extension)
        }
    }
}
