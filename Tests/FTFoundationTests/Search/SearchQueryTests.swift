// The search field's text read as a search: its condition words, the text left to find, and what the list offers at
// the caret.
import FTFoundation
import Foundation
import Testing

@Suite struct SearchQueryTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func query(_ text: String) -> SearchQuery { SearchQuery(text, calendar: calendar) }

    private func size(_ comparison: SearchComparison, _ value: Double, _ unit: SearchSizeUnit) -> [SearchCondition] {
        [.size(SearchSizeRule(comparison: comparison, value: value, unit: unit))]
    }

    // MARK: Text and conditions

    @Test func nothingTypedIsNoSearch() {
        for text in ["", " ", "\t\n ", "  "] {
            let read = query(text)
            #expect(read.text.isEmpty)
            #expect(read.names.isEmpty)
            #expect(read.conditions.isEmpty)
            #expect(!read.hasUnfinished)
        }
    }

    @Test func plainTextIsTheTextToFind() {
        let read = query("  quarterly  report ")
        // The text keeps its own spacing; its words are what is looked for.
        #expect(read.text == "quarterly  report")
        #expect(read.names == ["quarterly", "report"])
        #expect(read.conditions.isEmpty)
        #expect(!read.hasUnfinished)
    }

    @Test func tabsAndLineBreaksSeparateWordsAsSpacesDo() {
        let read = query("report\tkind:pdf\nq3")
        #expect(read.names == ["report", "q3"])
        #expect(read.conditions == [.kind([.pdf])])
    }

    @Test func conditionWordsAreTakenOutOfTheText() {
        let read = query("report kind:pdf q3 size:>10mb")
        #expect(read.text == "report q3")
        #expect(read.conditions == [.kind([.pdf])] + size(.larger, 10, .megabytes))
    }

    // Wherever the condition is, the words on either side are still the name's.
    @Test func aConditionAnywhereLeavesTheWordsAround() {
        #expect(query("kind:pdf report").text == "report")
        #expect(query("report kind:pdf").text == "report")
        #expect(query("mustafa size:>1mb demirhan").names == ["mustafa", "demirhan"])
        #expect(query("mustafa   size:>1mb   demirhan").names == ["mustafa", "demirhan"])
        #expect(query("kind:pdf").text.isEmpty)
        #expect(query("kind:pdf size:>1mb").names.isEmpty)
    }

    // A word the field doesn't know, or with no colon, is text to find.
    @Test func otherColonsAreText() {
        #expect(query("note:draft").text == "note:draft")
        #expect(query("12:30").conditions.isEmpty)
        #expect(query("12:30").text == "12:30")
        #expect(query(":pdf").text == ":pdf")
        #expect(query("http://example.com").conditions.isEmpty)
        #expect(query("kinds:pdf").text == "kinds:pdf")
        #expect(query("re:kind:pdf").conditions.isEmpty)
    }

    // A condition's word whose value can't be read is neither text nor a condition yet.
    @Test func anUnfinishedWordIsLeftOut() {
        let read = query("report kind:pd")
        #expect(read.text == "report")
        #expect(read.conditions.isEmpty)
        #expect(read.hasUnfinished)
        for word in [
            "size:", "size:10", "size:>", "kind:", "kind:,", "tag:", "tag:,", "skip:", "is:", "not:", "modified:",
        ] {
            #expect(query(word).hasUnfinished, "\(word)")
            #expect(query(word).conditions.isEmpty, "\(word)")
            #expect(query(word).names.isEmpty, "\(word)")
        }
    }

    @Test func wordsAreReadCaseAside() {
        #expect(query("Kind:PDF").conditions == [.kind([.pdf])])
        #expect(query("KIND:pdf").conditions == [.kind([.pdf])])
        #expect(query("kind:Pictures,video").conditions == [.kind([.picture, .video])])
        #expect(query("SIZE:>1MB").conditions == size(.larger, 1, .megabytes))
        #expect(query("IS:Hidden").conditions == [.attribute(.hidden, is: true)])
        #expect(query("Modified:Today").conditions == [.date(.modified, .today)])
    }

    // Every word is a condition of its own; the walk asks for all of them.
    @Test func aWordTypedTwiceIsTwoConditions() {
        #expect(
            query("tag:orange tag:purple").conditions == [.tags(["orange"], all: false), .tags(["purple"], all: false)])
        #expect(query("kind:pdf kind:picture").conditions == [.kind([.pdf]), .kind([.picture])])
        #expect(
            query("size:>1mb size:<10mb").conditions == size(.larger, 1, .megabytes) + size(.smaller, 10, .megabytes))
    }

    // A comma gives a choice within one word.
    @Test func commasListChoicesInOneWord() {
        #expect(query("tag:orange,purple").conditions == [.tags(["orange", "purple"], all: false)])
        #expect(query("kind:pdf,picture").conditions == [.kind([.pdf, .picture])])
        #expect(query("ext:jpg,heic").conditions == [.fileExtension(["jpg", "heic"])])
        #expect(query("skip:node_modules,.git").conditions == [.skipFolders(["node_modules", ".git"])])
        // An empty choice, as typing a comma leaves one, is passed over.
        #expect(query("tag:red,").conditions == [.tags(["red"], all: false)])
        #expect(query("tag:,red,,blue").conditions == [.tags(["red", "blue"], all: false)])
        #expect(query("kind:pdf,").conditions == [.kind([.pdf])])
        // One choice that can't be read leaves the whole word unread.
        #expect(query("kind:pdf,nothing").hasUnfinished)
        #expect(query("ext:jpg,h-e").hasUnfinished)
    }

    @Test func eachWordAndItsValues() {
        #expect(query("ext:.HEIC,jpg").conditions == [.fileExtension(["heic", "jpg"])])
        #expect(query("ext:.").hasUnfinished)
        #expect(query("ext:tar.gz").hasUnfinished)
        #expect(query("picture:>4k").conditions == [.pictureSize(SearchPixelRule(larger: true, pixels: 3840))])
        #expect(query("picture:<1920").conditions == [.pictureSize(SearchPixelRule(larger: false, pixels: 1920))])
        // Alone, that size exactly, as a file's size alone is that size.
        #expect(query("picture:1920").conditions == [.pictureSize(SearchPixelRule(comparison: .equal, pixels: 1920))])
        #expect(query("picture:hd").conditions == query("picture:1920").conditions)
        #expect(query("picture:4k").conditions == [.pictureSize(SearchPixelRule(comparison: .equal, pixels: 3840))])
        #expect(query("picture:8k").conditions == [.pictureSize(SearchPixelRule(comparison: .equal, pixels: 7680))])
        #expect(query("picture:2k").conditions == [.pictureSize(SearchPixelRule(comparison: .equal, pixels: 2000))])
        #expect(query("picture:>HD").conditions == [.pictureSize(SearchPixelRule(larger: true, pixels: 1920))])
        // Not that size, nor larger, nor smaller.
        let hd = SearchPixelRule(comparison: .equal, pixels: 1920)
        #expect(query("picture:!1920").conditions == [.not(.pictureSize(hd))])
        #expect(query("!picture:hd").conditions == [.not(.pictureSize(hd))])
        #expect(
            query("picture:!>4k").conditions == [.not(.pictureSize(SearchPixelRule(larger: true, pixels: 3840)))])
        for text in ["picture:0", "picture:!0", "picture:-5", "picture:1920px", "picture:4kk", "picture:=1920"] {
            #expect(query(text).conditions.isEmpty, "\(text)")
        }
        #expect(query("tag:Red,work").conditions == [.tags(["Red", "work"], all: false)])
        #expect(query("tag:Café").conditions == [.tags(["Café"], all: false)])
        #expect(
            query("is:locked not:hidden").conditions == [.attribute(.locked, is: true), .attribute(.hidden, is: false)])
        #expect(query("is:read-only").conditions == [.attribute(.readOnly, is: true)])
        #expect(query("skip:node_modules,build").conditions == [.skipFolders(["node_modules", "build"])])
        #expect(query("is:sleepy").hasUnfinished)
        // An attribute is one at a time: no choice of two.
        #expect(query("is:hidden,locked").hasUnfinished)
    }

    @Test func sizes() {
        #expect(query("size:<500kb").conditions == size(.smaller, 500, .kilobytes))
        // A size alone is that size, to its last digit (`SearchSyntaxTests`).
        #expect(query("size:10mb").conditions == size(.equal, 10, .megabytes))
        #expect(query("size:>1000b").conditions == size(.larger, 1000, .bytes))
        #expect(query("size:>1.5gb").conditions == size(.larger, 1.5, .gigabytes))
        // k, m and g are kb, mb and gb.
        #expect(query("size:>1k").conditions == size(.larger, 1, .kilobytes))
        #expect(query("size:<20m").conditions == size(.smaller, 20, .megabytes))
        #expect(query("size:2g").conditions == size(.equal, 2, .gigabytes))
        // A range in two units is held in the smaller.
        #expect(
            query("size:500kb..2mb").conditions == [
                .size(SearchSizeRule(comparison: .between, value: 500, upper: 2000, unit: .kilobytes))
            ])
        for word in [
            "size:0mb", "size:>0b", "size:>-1mb", "size:>1tb", "size:>1 mb", "size:mb", "size:>1.mb.", "size:1mb..",
        ] {
            #expect(query(word).hasUnfinished, "\(word)")
        }
    }

    @Test func dates() {
        #expect(query("modified:today").conditions == [.date(.modified, .today)])
        #expect(query("created:week").conditions == [.date(.created, .thisWeek)])
        #expect(query("opened:7d").conditions == [.date(.lastOpened, .withinLast(7, .days))])
        #expect(query("added:2w").conditions == [.date(.added, .withinLast(2, .weeks))])
        #expect(query("taken:>1y").conditions == [.date(.taken, .moreThanAgo(1, .years))])
        #expect(
            query("modified:2026-03-15").conditions == [.date(.modified, .between(day(2026, 3, 15), day(2026, 3, 15)))])
        // A month is its first to its last day.
        #expect(query("modified:2026-02").conditions == [.date(.modified, .between(day(2026, 2, 1), day(2026, 2, 28)))])
        #expect(query("modified:<2026-01-01").conditions == [.date(.modified, .before(day(2026, 1, 1)))])
        // After a month is after its last day.
        #expect(query("modified:>2026-01").conditions == [.date(.modified, .after(day(2026, 1, 31)))])
        #expect(
            query("modified:2026-01..2026-03").conditions == [
                .date(.modified, .between(day(2026, 1, 1), day(2026, 3, 31)))
            ])
        for word in ["modified:2026-02-30", "modified:0d", "modified:2026-13", "modified:soon", "modified:7"] {
            #expect(query(word).hasUnfinished, "\(word)")
        }
    }

    // MARK: Quotes

    // Words in double quotes are one word of the name, spaces and all, and never a condition.
    @Test func quotesKeepAPhraseAndHideConditions() {
        let phrase = query("\"annual  report\" kind:pdf")
        #expect(phrase.names == ["annual  report"])
        #expect(phrase.conditions == [.kind([.pdf])])
        #expect(query("\"kind:pdf\"").conditions.isEmpty)
        #expect(query("\"kind:pdf\"").names == ["kind:pdf"])
        #expect(query("\"kind:pdf notes\" size:>1k").names == ["kind:pdf notes"])
        #expect(query("\"kind:pdf notes\" size:>1k").conditions == size(.larger, 1, .kilobytes))
        #expect(!query("\"size:\"").hasUnfinished)
    }

    // A quote with no other after it is an ordinary character, and conditions after it are read.
    @Test func anUnclosedQuoteIsACharacter() {
        let read = query("\"annual report kind:pdf")
        #expect(read.names == ["\"annual", "report"])
        #expect(read.conditions == [.kind([.pdf])])
        #expect(query("5\" floppy").names == ["5\"", "floppy"])
        #expect(query("kind:\"pdf\"").hasUnfinished)
    }

    // Quotes with nothing in them are no name: a condition alone is searched, or nothing is.
    @Test func emptyQuotesAreNoName() {
        #expect(query("\"\"").names.isEmpty)
        #expect(query("\"\" kind:pdf").names.isEmpty)
        #expect(query("\"\" kind:pdf").conditions == [.kind([.pdf])])
        #expect(query("\"   \"").names == ["   "])
    }

    @Test func wordsKnowWhereTheyAre() {
        let words = SearchQuery.words("ab Kind:pdf  ext:", calendar: calendar)
        #expect(
            words.map(\.range) == [
                NSRange(location: 0, length: 2), NSRange(location: 3, length: 8), NSRange(location: 13, length: 4),
            ])
        #expect(words[1].keyLength == 5)
        #expect(words[1].value == "pdf")
        #expect(words[2].role == .unfinished)
    }

    // A quoted run is one word; where words are is counted in UTF-16, as AppKit counts.
    @Test func quotedRunsAndWideCharactersKnowWhereTheyAre() {
        let quoted = SearchQuery.words("\"a b\" kind:pdf", calendar: calendar)
        #expect(quoted.map(\.range) == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 8)])
        #expect(quoted[0].role == .text)
        let wide = SearchQuery.words("📁 kind:pdf", calendar: calendar)
        #expect(wide.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 8)])
    }

    @Test func clearingConditionsLeavesTheText() {
        #expect(SearchQuery.removingConditions(from: "report kind:pdf size:>1 q3") == "report q3")
        #expect(SearchQuery.removingConditions(from: "\"kind:pdf notes\" kind:pdf") == "\"kind:pdf notes\"")
        #expect(SearchQuery.removingConditions(from: "kind:pdf").isEmpty)
    }

    // MARK: Any text

    // Text made of the pieces that trip a parser (quotes, colons, commas, spaces at either end, wide characters, a
    // word cut short), each read and offered for at every caret: nothing fails, and every word is where it says.
    @Test func anyTextIsReadAndOfferedForAtEveryCaret() {
        let pieces = [
            "\"", " ", "  ", "\t", ":", ",", "kind", "kind:", "size:>", "1k", "tag:", "a", "pdf", "📁", "e\u{301}", "..",
            "is:", "-", ">", "<", "\u{65E5}", "skip:", "2026-01", "\n", "!", "!!", "perm:", "755", "rwx", "..",
            "\"!", "1.50", "mb", "!kind:", "size:1", "not:",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<1500 {
            let text = (0..<next(9)).map { _ in pieces[next(pieces.count)] }.joined()
            let length = text.utf16.count
            let words = SearchQuery.words(text, calendar: calendar)
            var end = 0
            for word in words {
                #expect(word.range.location >= end, "\(text.debugDescription)")
                #expect(word.range.length > 0 && NSMaxRange(word.range) <= length, "\(text.debugDescription)")
                #expect((text as NSString).substring(with: word.range) == word.text, "\(text.debugDescription)")
                end = NSMaxRange(word.range)
            }
            let read = query(text)
            #expect(read.names == NameTerms.words(read.text), "\(text.debugDescription)")
            #expect(
                read.conditions.count == words.filter { if case .condition = $0.role { true } else { false } }.count,
                "\(text.debugDescription)")
            for caret in 0...length {
                for newWord in [false, true] {
                    if let list = suggest(text, caret: caret, newWord: newWord) {
                        #expect(!list.rows.isEmpty, "\(text.debugDescription) at \(caret)")
                        #expect(NSMaxRange(list.range) <= length, "\(text.debugDescription) at \(caret)")
                    }
                }
            }
        }
    }

    // MARK: Suggestions

    private func suggest(_ text: String, caret: Int? = nil, newWord: Bool = false) -> SearchQuerySuggestions? {
        SearchQuerySuggestions.make(
            query: text, caret: caret ?? text.utf16.count, tags: ["Red", "Work"], folders: ["node_modules", "build"],
            listsWordsForNewWord: newWord, now: day(2026, 11, 24), calendar: calendar)
    }

    @Test func aWordAndColonListItsValues() throws {
        let list = try #require(suggest("report kind:pd"))
        #expect(list.range == NSRange(location: 7, length: 7))
        #expect(list.sections.first?.title == "Kind")
        #expect(list.rows.first == SearchQuerySuggestion(title: "PDF", hint: "pdf", replacement: "kind:pdf "))
        #expect(list.highlightsFirst)
    }

    // After a comma, the next value is offered, the ones before kept.
    @Test func aListGoesOnAfterAComma() throws {
        let list = try #require(suggest("tag:red,w"))
        #expect(list.rows.map(\.replacement) == ["tag:red,Work "])
        let kinds = try #require(suggest("kind:pdf,pic"))
        #expect(kinds.rows.first?.replacement == "kind:pdf,picture ")
    }

    @Test func numbersAreOfferedInEachUnit() throws {
        let sizes = try #require(suggest("size:>50"))
        #expect(sizes.rows.map(\.hint) == [">50kb", ">50mb", ">50gb", ">50b"])
        #expect(sizes.rows[1].title == "Larger than 50 MB")
        #expect(sizes.rows[3].title == "Larger than 50 bytes")
        #expect(try #require(suggest("size:>1")).rows.last?.title == "Larger than 1 byte")
        let days = try #require(suggest("modified:3"))
        #expect(days.rows.first?.hint == "3d")
    }

    // What is typed in full and isn't a listed value is offered first, as it reads.
    @Test func aFullValueIsOfferedAsTyped() throws {
        let list = try #require(suggest("size:>37mb"))
        #expect(
            list.rows.first
                == SearchQuerySuggestion(title: "Larger than 37 MB", hint: ">37mb", replacement: "size:>37mb "))
        let short = try #require(suggest("size:>1k"))
        #expect(short.rows.contains { $0.title == "Larger than 1 KB" })
    }

    @Test func aPlainWordOffersWhatItCouldBe() throws {
        let list = try #require(suggest("pdf"))
        #expect(list.rows.map(\.hint) == ["kind:pdf", "ext:pdf"])
        // Nothing is chosen until ↑ or ↓: Return searches for the word.
        #expect(!list.highlightsFirst)
        let start = try #require(suggest("mo"))
        #expect(start.rows.map(\.hint) == ["modified:"])
        #expect(start.rows.last?.keepsListOpen == true)
        // A word that is no condition offers nothing.
        #expect(suggest("report") == nil)
        #expect(suggest("x") == nil)
    }

    // A word is found by its name's words as well as by what is typed for it.
    @Test func aWordIsFoundByItsName() throws {
        let dates = try #require(suggest("d"))
        #expect(dates.rows.map(\.hint) == ["modified:", "created:", "added:", "opened:", "taken:"])
        #expect(try #require(suggest("date")).rows.count == 5)
        #expect(try #require(suggest("tak")).rows.map(\.hint) == ["taken:"])
        #expect(try #require(suggest("si")).rows.map(\.hint) == ["size:", "picture:"])
        #expect(try #require(suggest("Ta")).rows.map(\.hint).contains("tag:"))
    }

    // An extension is typed and listed without its dot.
    @Test func extensionsAreListedWithoutADot() throws {
        let list = try #require(suggest("ext:do"))
        #expect(list.rows.first == SearchQuerySuggestion(title: "DOCX files", hint: "docx", replacement: "ext:docx "))
        let all = try #require(suggest("ext:"))
        #expect(all.rows.allSatisfy { !$0.title.contains(".") && !$0.hint.contains(".") })
        #expect(query("ext:docx").conditions == query("ext:.docx").conditions)
        #expect(query("ext:docx").conditions == [.fileExtension(["docx"])])
    }

    @Test func skipAndTagsOfferWhatTheyAreGiven() throws {
        #expect(try #require(suggest("skip:no")).rows.map(\.hint) == ["node_modules"])
        #expect(try #require(suggest("tag:")).rows.map(\.hint) == ["Red", "Work"])
        // A value is found by any part of its name, those that start with what is typed first.
        #expect(try #require(suggest("tag:r")).rows.map(\.hint) == ["Red", "Work"])
        // A tag can be any name: what is typed comes first when no tag starts with it.
        #expect(try #require(suggest("tag:ork")).rows.map(\.hint) == ["ork", "Work"])
        #expect(try #require(suggest("re")).rows.contains { $0.hint == "tag:Red" })
    }

    // A new word lists every condition's word, when asked, after nothing or a whole condition: after a word of the
    // name, the name goes on.
    @Test func aNewWordListsTheWordsAfterNothingOrACondition() throws {
        #expect(suggest("") == nil)
        let words = try #require(suggest("", newWord: true))
        #expect(words.rows.map(\.hint).prefix(3) == ["kind:", "ext:", "size:"])
        #expect(!words.highlightsFirst)
        #expect(suggest("   ", newWord: true) != nil)
        #expect(suggest("size:>1kb ", newWord: true) != nil)
        #expect(suggest("report kind:pdf ", newWord: true) != nil)
        #expect(try #require(suggest("size:>1kb ", newWord: true)).range == NSRange(location: 10, length: 0))
        // After the name, or a word that can't be read yet, nothing.
        #expect(suggest("report ", newWord: true) == nil)
        #expect(suggest("kind:pd ", newWord: true) == nil)
        #expect(suggest("\"annual report\" ", newWord: true) == nil)
        // Not asked: nothing at a new word.
        #expect(suggest("size:>1kb ") == nil)
    }

    // The caret decides which word is offered for, wherever it is.
    @Test func theCaretChoosesTheWord() throws {
        let text = "kind:pd report"
        #expect(try #require(suggest(text, caret: 7)).sections.first?.title == "Kind")
        #expect(suggest(text, caret: text.utf16.count) == nil)
        // Between two words of the name, after the first: the name goes on.
        #expect(suggest("a  b", caret: 2, newWord: true) == nil)
        // Past a wide character, counted in UTF-16.
        let wide = try #require(suggest("📁 kind:pd"))
        #expect(wide.range == NSRange(location: 3, length: 7))
    }

    // Inside quotes, nothing is offered: it is a name.
    @Test func nothingIsOfferedInQuotes() {
        #expect(suggest("\"kind:") == nil)
        #expect(suggest("\"kind:pd") == nil)
        #expect(suggest("\"pdf\"") == nil)
    }
}
