// The search's text, as typed, through the walk on real files: words, phrases and words left out; sizes to their
// last digit and at their edges; permissions; `!` on each condition that takes it; and these together.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct SearchSyntaxWalkTests {
    /// What a search typed as `text` finds in `top`'s `folder`, by name.
    private func found(_ runtime: WalkSearchRuntime, _ top: String, _ folder: String, _ text: String) throws
        -> Set<String>
    {
        let parsed = SearchQuery(text)
        #expect(!parsed.hasUnfinished, "\(text) has a word that can't be read")
        let (update, items) = try runWalk(
            runtime,
            SearchRequest(rootPath: top + "/" + folder, query: parsed.text, conditions: parsed.conditions))
        #expect(update.status == .complete, "\(text): \(update.error ?? "")")
        return Set(items.map(\.name))
    }

    private func file(_ path: String, size: Int64 = 0, mode: mode_t = 0o644) throws {
        try makeSearchFile(path)
        if size > 0 { #expect(truncate(path, off_t(size)) == 0) }
        #expect(chmod(path, mode) == 0)
    }

    /// Four folders: files of chosen sizes, of chosen permissions, with chosen tags, and with chosen names.
    private func makeTree(_ top: String) throws {
        for folder in ["sizes", "perms", "tags", "names"] { try makeSearchFolder(top + "/" + folder) }
        let sizes: [(String, Int64)] = [
            ("s999.bin", 999), ("s1000.bin", 1000), ("s1001.bin", 1001), ("s1999.bin", 1999), ("s2000.bin", 2000),
            ("k2109.bin", 2109), ("k2110.bin", 2110), ("k2119.bin", 2119), ("k2120.bin", 2120),
            ("m1.bin", 1_000_000), ("m1-5.bin", 1_500_000), ("m1-9.bin", 1_999_999), ("m2.bin", 2_000_000),
            ("empty.bin", 0),
        ]
        for (name, size) in sizes { try file(top + "/sizes/" + name, size: size) }
        let modes: [(String, mode_t)] = [
            ("p755.sh", 0o755), ("p644.txt", 0o644), ("p600.key", 0o600), ("p777.tmp", 0o777), ("p4755", 0o4755),
            ("p640.txt", 0o640), ("p2755", 0o2755), ("p750", 0o750),
        ]
        for (name, mode) in modes { try file(top + "/perms/" + name, mode: mode) }
        let tags: [(String, [FinderTag])] = [
            ("t-red.txt", [FinderTag(name: "Red", color: .red)]),
            ("t-blue.txt", [FinderTag(name: "Blue", color: .blue)]),
            ("t-both.txt", [FinderTag(name: "Red", color: .red), FinderTag(name: "Blue", color: .blue)]),
            ("t-work.txt", [FinderTag(name: "Work", color: nil)]), ("t-none.txt", []),
        ]
        for (name, list) in tags {
            try file(top + "/tags/" + name)
            if !list.isEmpty { try FinderTags.write(list, to: top + "/tags/" + name) }
        }
        // Opened now, as macOS notes it; the rest never were.
        var opened = (Int64(time(nil)), Int64(0))
        let size = MemoryLayout.size(ofValue: opened)
        #expect(setxattr(top + "/tags/t-red.txt", FileTimes.lastUsedAttribute, &opened, size, 0, 0) == 0)
        for name in [
            "annual report.pdf", "Report, annual.txt", "report-draft.pdf", "old copy of report.pdf", "draft notes.txt",
            "annual  report.key", "caf\u{E9} menu.txt", "r\u{E9}sum\u{E9}.pdf", "kind:pdf notes.txt",
        ] {
            try file(top + "/names/" + name)
        }
    }

    private func withTree(_ body: (WalkSearchRuntime, String) throws -> Void) throws {
        let runtime = WalkSearchRuntime()
        defer { runtime.close() }
        try withTemporaryDirectory { folder in
            try makeTree(folder.path)
            try body(runtime, folder.path)
        }
    }

    // MARK: Sizes

    @Test func aSizeAloneFindsThatSizeToItsLastDigit() throws {
        try withTree { runtime, top in
            let folder = "sizes"
            let cases: [(String, Set<String>)] = [
                ("size:1000b", ["s1000.bin"]),
                ("size:1kb", ["s1000.bin", "s1001.bin", "s1999.bin"]),
                ("size:1k", ["s1000.bin", "s1001.bin", "s1999.bin"]),
                ("size:2kb", ["s2000.bin", "k2109.bin", "k2110.bin", "k2119.bin", "k2120.bin"]),
                ("size:2.1kb", ["k2109.bin", "k2110.bin", "k2119.bin", "k2120.bin"]),
                ("size:2.11kb", ["k2110.bin", "k2119.bin"]),
                ("size:2.10kb", ["k2109.bin"]),
                ("size:2.12kb", ["k2120.bin"]),
                ("size:1mb", ["m1.bin", "m1-5.bin", "m1-9.bin"]),
                ("size:1.5mb", ["m1-5.bin"]),
                ("size:2mb", ["m2.bin"]),
                ("size:999b", ["s999.bin"]),
                ("size:3mb", []),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    @Test func largerSmallerAndBetweenAtTheirEdges() throws {
        try withTree { runtime, top in
            let folder = "sizes"
            let cases: [(String, Set<String>)] = [
                ("size:>1mb", ["m1-5.bin", "m1-9.bin", "m2.bin"]),
                ("size:>1999999b", ["m2.bin"]),
                ("size:<1000b", ["s999.bin", "empty.bin"]),
                ("size:<1kb s", ["s999.bin"]),
                ("size:1mb..2mb", ["m1.bin", "m1-5.bin", "m1-9.bin", "m2.bin"]),
                ("size:1000b..2000b", ["s1000.bin", "s1001.bin", "s1999.bin", "s2000.bin"]),
                // Two sizes, both asked for.
                ("size:>1mb size:<2mb", ["m1-5.bin", "m1-9.bin"]),
                (
                    "size:>1kb size:<1mb",
                    ["s1001.bin", "s1999.bin", "s2000.bin", "k2109.bin", "k2110.bin", "k2119.bin", "k2120.bin"]
                ),
                ("size:1mb size:1.5mb", ["m1-5.bin"]),
                ("size:1kb size:2kb", []),
                // At least and at most take the size itself in.
                ("size:>=1mb", ["m1.bin", "m1-5.bin", "m1-9.bin", "m2.bin"]),
                ("size:=>1mb", ["m1.bin", "m1-5.bin", "m1-9.bin", "m2.bin"]),
                ("size:<=1000b", ["s999.bin", "s1000.bin", "empty.bin"]),
                ("size:=<1kb", ["s999.bin", "s1000.bin", "empty.bin"]),
                ("size:<=1999999b s", ["s999.bin", "s1000.bin", "s1001.bin", "s1999.bin", "s2000.bin"]),
                ("size:>=2.11kb size:<=2.12kb", ["k2110.bin", "k2119.bin", "k2120.bin"]),
                ("size:>=1kb size:<=2kb", ["s1000.bin", "s1001.bin", "s1999.bin", "s2000.bin"]),
                ("size:!>=1kb", ["s999.bin", "empty.bin"]),
                ("size:!<=1mb", ["m2.bin", "m1-5.bin", "m1-9.bin"]),
                // Not a size: every file but those, the empty one too.
                (
                    "size:!1kb",
                    [
                        "s999.bin", "s2000.bin", "k2109.bin", "k2110.bin", "k2119.bin", "k2120.bin", "m1.bin",
                        "m1-5.bin", "m1-9.bin", "m2.bin", "empty.bin",
                    ]
                ),
                (
                    "!size:1kb",
                    [
                        "s999.bin", "s2000.bin", "k2109.bin", "k2110.bin", "k2119.bin", "k2120.bin", "m1.bin",
                        "m1-5.bin", "m1-9.bin", "m2.bin", "empty.bin",
                    ]
                ),
                ("size:!1mb..2mb s", ["s999.bin", "s1000.bin", "s1001.bin", "s1999.bin", "s2000.bin"]),
                (
                    "size:>1kb size:!2.1kb",
                    ["s1001.bin", "s1999.bin", "s2000.bin", "m1.bin", "m1-5.bin", "m1-9.bin", "m2.bin"]
                ),
                ("size:!>1b", ["empty.bin"]),
                ("size:!1kb size:!2kb size:!1mb size:!2mb", ["s999.bin", "empty.bin"]),
                // A size and words of the name, kept and left out.
                ("size:1mb !1-5", ["m1.bin", "m1-9.bin"]),
                ("size:1kb s1", ["s1000.bin", "s1001.bin", "s1999.bin"]),
                // "empty.bin" has an m too.
                ("m size:<2mb !m1-9", ["m1.bin", "m1-5.bin", "empty.bin"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    // MARK: Permissions

    @Test func permissionsFindTheirModeExactly() throws {
        try withTree { runtime, top in
            let folder = "perms"
            let all: Set<String> = [
                "p755.sh", "p644.txt", "p600.key", "p777.tmp", "p4755", "p640.txt", "p2755", "p750",
            ]
            let cases: [(String, Set<String>)] = [
                ("perm:755", ["p755.sh"]),
                ("perm:0755", ["p755.sh"]),
                ("perm:rwxr-xr-x", ["p755.sh"]),
                ("perm:-rwxr-xr-x", ["p755.sh"]),
                ("perm:4755", ["p4755"]),
                ("perm:rwsr-xr-x", ["p4755"]),
                ("perm:644", ["p644.txt"]),
                ("perm:755,644", ["p755.sh", "p644.txt"]),
                ("perm:755 perm:644", []),
                ("perm:!777", all.subtracting(["p777.tmp"])),
                ("!perm:777", all.subtracting(["p777.tmp"])),
                ("perm:!755,644", ["p600.key", "p777.tmp", "p4755", "p640.txt", "p2755", "p750"]),
                ("perm:!755 perm:!644", ["p600.key", "p777.tmp", "p4755", "p640.txt", "p2755", "p750"]),
                ("perm:111", []),
                // With extensions, kinds and words.
                ("perm:!600 ext:!sh,tmp", ["p644.txt", "p4755", "p640.txt", "p2755", "p750"]),
                ("perm:644,640 kind:text", ["p644.txt", "p640.txt"]),
                ("txt perm:!640", ["p644.txt"]),
                ("perm:755,4755 !4755", ["p755.sh"]),
                // `?` in digits is any digit: `?5?` is a group of 5, whatever else, set-user and set-group too.
                ("perm:?5?", ["p755.sh", "p4755", "p750", "p2755"]),
                // In letters, `x` isn't `s`: a set-group 2755 shows r-s.
                ("perm:???r-x???", ["p755.sh", "p4755", "p750"]),
                ("perm:???r-s???", ["p2755"]),
                ("perm:0?5?", ["p755.sh", "p750"]),
                ("perm:7??", ["p755.sh", "p777.tmp", "p4755", "p2755", "p750"]),
                ("perm:?5? perm:7??", ["p755.sh", "p4755", "p2755", "p750"]),
                ("perm:?4?,?0?", ["p644.txt", "p640.txt", "p600.key"]),
                ("perm:??4", ["p644.txt"]),
                ("perm:!?5?", all.subtracting(["p755.sh", "p4755", "p750", "p2755"])),
                ("perm:?5? !p7", ["p4755", "p2755"]),
                ("perm:?6?", []),
                ("perm:?4?", ["p644.txt", "p640.txt"]),
                ("perm:r?????r??", ["p755.sh", "p644.txt", "p777.tmp", "p4755", "p2755"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    // MARK: Tags

    @Test func tagsBothEitherAndNot() throws {
        try withTree { runtime, top in
            let folder = "tags"
            let cases: [(String, Set<String>)] = [
                ("tag:red", ["t-red.txt", "t-both.txt"]),
                ("tag:RED", ["t-red.txt", "t-both.txt"]),
                ("tag:red tag:blue", ["t-both.txt"]),
                ("tag:red,blue", ["t-red.txt", "t-blue.txt", "t-both.txt"]),
                ("tag:!red", ["t-blue.txt", "t-work.txt", "t-none.txt"]),
                ("!tag:red", ["t-blue.txt", "t-work.txt", "t-none.txt"]),
                ("tag:!red,blue", ["t-work.txt", "t-none.txt"]),
                ("tag:!red tag:!blue", ["t-work.txt", "t-none.txt"]),
                ("tag:red tag:!blue", ["t-red.txt"]),
                ("tag:red,work tag:!blue", ["t-red.txt", "t-work.txt"]),
                ("tag:red !both", ["t-red.txt"]),
                ("tag:!red both", []),
                ("tag:green", []),
                ("tag:!green", ["t-red.txt", "t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    // Tags and the date last opened share one list of each item's attributes, and are told from it before either is
    // read; either way round, with the other conditions, they find the same.
    @Test func tagsAndTheDateLastOpenedTogether() throws {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        try withTree { runtime, top in
            let cases: [(String, Set<String>)] = [
                ("opened:7d", ["t-red.txt"]),
                ("opened:>1y", ["t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("tag:red opened:7d", ["t-red.txt"]),
                ("opened:7d tag:red", ["t-red.txt"]),
                ("tag:red opened:>1y", ["t-both.txt"]),
                ("tag:!red opened:7d", []),
                ("tag:!red opened:>1y", ["t-blue.txt", "t-work.txt", "t-none.txt"]),
                ("tag:red,blue opened:>1y !both", ["t-blue.txt"]),
                ("opened:7d size:<1kb tag:red", ["t-red.txt"]),
                ("opened:7d perm:644 kind:text tag:red", ["t-red.txt"]),
                ("opened:7d perm:!644", []),
                // Not a date: never opened counts as long ago.
                ("opened:!7d", ["t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("!opened:7d", ["t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("opened:!>1y", ["t-red.txt"]),
                ("tag:red opened:!7d", ["t-both.txt"]),
                ("modified:!today", []),
                ("modified:!>20y", ["t-red.txt", "t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("created:!week tag:red", []),
                // From a day on, to a day: never opened counts as long ago.
                ("modified:>=\(today)", ["t-red.txt", "t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("modified:<=2000-01", []),
                ("modified:!<=2000-01", ["t-red.txt", "t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("opened:>=2000-01", ["t-red.txt"]),
                ("opened:<=2000-01", ["t-blue.txt", "t-both.txt", "t-work.txt", "t-none.txt"]),
                ("opened:=>\(today) tag:red", ["t-red.txt"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, "tags", text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    // MARK: Names

    @Test func wordsPhrasesAndWordsLeftOut() throws {
        try withTree { runtime, top in
            let folder = "names"
            let cases: [(String, Set<String>)] = [
                ("annual report", ["annual report.pdf", "Report, annual.txt", "annual  report.key"]),
                ("report     annual", ["annual report.pdf", "Report, annual.txt", "annual  report.key"]),
                ("\"annual report\"", ["annual report.pdf"]),
                ("\"annual  report\"", ["annual  report.key"]),
                (
                    "report !draft",
                    ["annual report.pdf", "Report, annual.txt", "old copy of report.pdf", "annual  report.key"]
                ),
                (
                    "!draft",
                    [
                        "annual report.pdf", "Report, annual.txt", "old copy of report.pdf", "annual  report.key",
                        "caf\u{E9} menu.txt", "r\u{E9}sum\u{E9}.pdf", "kind:pdf notes.txt",
                    ]
                ),
                (
                    "report !\"old copy\"",
                    ["annual report.pdf", "Report, annual.txt", "report-draft.pdf", "annual  report.key"]
                ),
                ("annual !annual", []),
                ("cafe", ["caf\u{E9} menu.txt"]),
                ("resume", ["r\u{E9}sum\u{E9}.pdf"]),
                ("!cafe ext:txt", ["Report, annual.txt", "draft notes.txt", "kind:pdf notes.txt"]),
                ("\"!draft\"", []),
                // In quotes, a condition's word is a name.
                ("\"kind:pdf\"", ["kind:pdf notes.txt"]),
                ("notes !\"kind:pdf\"", ["draft notes.txt"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }

    // MARK: Kinds and extensions, with and without not

    @Test func kindsAndExtensionsWithNot() throws {
        try withTree { runtime, top in
            let folder = "names"
            let cases: [(String, Set<String>)] = [
                ("report kind:pdf", ["annual report.pdf", "report-draft.pdf", "old copy of report.pdf"]),
                ("report kind:pdf !draft", ["annual report.pdf", "old copy of report.pdf"]),
                ("report kind:!pdf", ["Report, annual.txt", "annual  report.key"]),
                ("report !kind:pdf", ["Report, annual.txt", "annual  report.key"]),
                ("kind:!pdf,text", ["annual  report.key"]),
                ("ext:!pdf,txt", ["annual  report.key"]),
                ("ext:!pdf ext:!txt", ["annual  report.key"]),
                ("kind:pdf ext:!pdf", []),
                (
                    "kind:pdf,presentation kind:!presentation",
                    ["annual report.pdf", "report-draft.pdf", "old copy of report.pdf", "r\u{E9}sum\u{E9}.pdf"]
                ),
                ("kind:text kind:!text", []),
                ("ext:txt !notes", ["Report, annual.txt", "caf\u{E9} menu.txt"]),
            ]
            for (text, expected) in cases {
                let got = try found(runtime, top, folder, text)
                #expect(got == expected, "\(text)")
            }
        }
    }
}
