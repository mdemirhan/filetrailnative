// What a search keeps of the names it passes: globs as regular expressions, the text a glob needs, smart case, and the
// same answer from a name's bytes as from its text.
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

@Suite struct SearchNameMatchTests {
    private func matches(_ query: String, _ mode: SearchPatternModePreference, _ names: [String]) throws -> [String] {
        let match = try SearchNameMatch(SearchRequest(rootPath: "/", query: query, patternMode: mode))
        return names.filter { match.matches($0) }
    }

    @Test func aGlobMatchesTheWholeName() throws {
        let names = ["report.pdf", "Report.PDF", "report.pdf.bak", "a.txt", "b.md", "photo-01.jpg", "photo-1.jpg"]
        #expect(try matches("*.pdf", .glob, names) == ["report.pdf", "Report.PDF"])
        #expect(try matches("*.PDF", .glob, names) == ["Report.PDF"])
        #expect(try matches("photo-??.jpg", .glob, names) == ["photo-01.jpg"])
        #expect(try matches("[ab].*", .glob, names) == ["a.txt", "b.md"])
        #expect(try matches("[!ab]*", .glob, names).count == 5)
        #expect(try matches("*.{txt,md}", .glob, names) == ["a.txt", "b.md"])
        #expect(try matches("", .glob, names) == names)
    }

    // Plain Text finds a name holding every word, in any order; words in quotes are one run, spaces and all.
    @Test func plainTextFindsEveryWordInAnyOrder() throws {
        let names = [
            "annual report.pdf", "Report, Annual 2025.pdf", "annual.pdf", "report.pdf", "annual  report.pdf",
            "My Annual Report.key", "kind:pdf notes.txt", "caf\u{E9} menu.txt", "cafe\u{301} carte.txt",
        ]
        #expect(
            try matches("annual report", .text, names) == [
                "annual report.pdf", "Report, Annual 2025.pdf", "annual  report.pdf", "My Annual Report.key",
            ])
        #expect(try matches("report   annual", .text, names) == (try matches("annual report", .text, names)))
        #expect(try matches("\"annual report\"", .text, names) == ["annual report.pdf", "My Annual Report.key"])
        #expect(try matches("\"annual  report\"", .text, names) == ["annual  report.pdf"])
        #expect(try matches("annual 2025 pdf", .text, names) == ["Report, Annual 2025.pdf"])
        #expect(try matches("\"kind:pdf\"", .text, names) == ["kind:pdf notes.txt"])
        // Each word as Contains matches it: a plain letter finds its accented forms, however they are stored.
        #expect(try matches("cafe txt", .text, names) == ["caf\u{E9} menu.txt", "cafe\u{301} carte.txt"])
        #expect(try matches("caf\u{E9} carte", .text, names) == ["cafe\u{301} carte.txt"])
        // Quotes with nothing in them, or only spaces typed, find everything as empty text does.
        #expect(try matches("\"\"", .text, names) == names)
        #expect(try matches("   ", .text, names) == names)
        // A glob or a regular expression is the pattern as typed, spaces and quotes and all.
        #expect(try matches("annual report*", .glob, names) == ["annual report.pdf"])
        #expect(try matches("annual report", .regex, names) == ["annual report.pdf", "My Annual Report.key"])
    }

    @Test func aGlobsStarsStopAtASlashAndDoubleStarsCrossFolders() throws {
        let path = { (glob: String) in try GlobPattern.regex(for: glob) }
        #expect(try path("*.swift") == "^[^/]*\\.swift$")
        #expect(try path("**/x") == "^(?:.*/)?x$")
        #expect(try path("a/**/b") == "^a/(?:.*/)?b$")
        #expect(try path("a/**") == "^a/.*$")
        #expect(try path("**") == "^.*$")
        #expect(try path("a**b") == "^a[^/]*b$")
        #expect(try path("[]a]") == "^[\\]a]$")
        #expect(try path("[!a]") == "^[^/a]$")
        #expect(try path("\\*x") == "^\\*x$")
        for broken in ["[abc", "{a,b", "x\\"] {
            #expect(throws: SearchPatternError.invalid) { try GlobPattern.regex(for: broken) }
        }
    }

    @Test func aGlobsRequiredTextIsItsLongestPlainRun() {
        #expect(GlobPattern.requiredText("*.dylib") == ".dylib")
        #expect(GlobPattern.requiredText("**/Contents/Info.plist") == "/Contents/Info.plist")
        #expect(GlobPattern.requiredText("photo-??.jpg") == "photo-")
        #expect(GlobPattern.requiredText("[abc]*.md") == ".md")
        #expect(GlobPattern.requiredText("star\\*name") == "star*name")
        // Alternatives make any text optional; none, or beyond ASCII, is nothing to look for.
        #expect(GlobPattern.requiredText("*.{md,txt}") == nil)
        #expect(GlobPattern.requiredText("*") == nil)
        #expect(GlobPattern.requiredText("caf\u{E9}*") == nil)
    }

    @Test func capitalsMakeGlobAndRegexMatchCase() throws {
        #expect(!SmartCase.regexHasUppercase("report\\S+\\d"))
        #expect(!SmartCase.regexHasUppercase("\\p{Lu}\\P{Ll}\\x{41}"))
        #expect(SmartCase.regexHasUppercase("Report"))
        #expect(SmartCase.regexHasUppercase("[A-Z]"))
        #expect(SmartCase.regexHasUppercase("\u{C9}t\u{E9}"))
        #expect(SmartCase.globHasUppercase("\\A*"))
        #expect(try matches("report", .regex, ["Report", "report"]) == ["Report", "report"])
        #expect(try matches("Report", .regex, ["Report", "report"]) == ["Report"])
        #expect(try matches("\\Sreport", .regex, ["xReport"]) == ["xReport"])
    }

    // A name's bytes give the answer its text does, fast or not: ASCII names without a string, others through one.
    @Test func aNamesBytesMatchAsItsText() throws {
        let names = [
            "report.pdf", "Report 2024.PDF", "caf\u{E9}.txt", "cafe\u{301}.md", "\u{FB01}le", "\u{212A}elvin",
            "STRASSE", "Stra\u{DF}e", "notes.md", "a.b.c",
        ]
        let requests: [(SearchPatternModePreference, String)] = [
            (.text, "re"), (.text, "\u{E9}"), (.text, "e"), (.text, "fi"), (.text, "k"), (.text, "ss"),
            (.text, "re pdf"), (.text, "caf\u{E9} txt"), (.text, "\"report 2024\""), (.text, "e k"), (.text, "fi le"),
            (.text, "md notes"), (.text, "\"\" a"), (.text, "!re"), (.text, "re !pdf"), (.text, "!\u{E9}"),
            (.text, "!caf\u{E9}"), (.text, "!fi"), (.text, "!k e"), (.text, "!\"report 2024\""), (.text, "!a !b !c"),
            (.glob, "*.md"), (.glob, "*.PDF"), (.glob, "k*"), (.glob, "caf*"), (.regex, "^c"), (.regex, "k"),
            (.regex, "\\d+"),
        ]
        for (mode, query) in requests {
            let match = try SearchNameMatch(SearchRequest(rootPath: "/", query: query, patternMode: mode), copies: 2)
            for name in names {
                var spelled = name
                let fromBytes = spelled.withUTF8 { bytes in match.outcome(bytes: bytes, worker: 1) { name } }
                #expect(fromBytes == match.outcome(name), "\(mode) \(query) \(name)")
            }
        }
    }

    // A path search folds each folder once and the names in it one by one: it finds what matching each whole path
    // finds, however the folder and the name spell their accents, the text inside the folder's path, across the slash
    // or inside the name.
    @Test func aPathMatchedFolderByFolderMatchesAsTheWholePath() throws {
        let folders = [
            "/Users/demo/Caf\u{E9}", "/Users/demo/Cafe\u{301} b", "/\u{65E5}\u{672C}", "/x/\u{1EAD}y", "/plain/folder",
        ]
        let names = ["report.pdf", "caf\u{E9}.txt", "\u{FB01}le", "e\u{301}t\u{E9}", "b/x", "\u{301}mark"]
        let queries = [
            "caf\u{E9}/r", "cafe", "e b/caf", "\u{65E5}\u{672C}/f", "/f", "y/\u{FB01}", "demo", "\u{E9}t\u{E9}", "r/re",
            "\u{1EAD}", "a", "x", "demo report", "caf\u{E9} txt", "\"e b/caf\"", "x y", "\u{65E5} f", "plain mark",
            "!demo", "demo !report", "!caf\u{E9}", "!\"e b/caf\"", "x !y", "!\u{65E5}", "a !a",
        ]
        let scratch = SearchNameMatch.Scratch()
        for query in queries {
            let match = try SearchNameMatch(SearchRequest(rootPath: "/", query: query, matchScope: .path))
            for folder in folders {
                for name in names {
                    var path = folder + "/" + name
                    let nameOffset = folder.utf8.count + 1
                    let partly = path.withUTF8 {
                        match.outcome(path: $0, nameOffset: nameOffset, worker: 0, scratch: scratch)
                    }
                    #expect(partly == match.outcome(folder + "/" + name), "\(query) in \(folder)/\(name)")
                }
            }
        }
    }
}
