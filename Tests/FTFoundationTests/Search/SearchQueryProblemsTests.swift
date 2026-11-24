// A condition's word that can't be read: whether more typing could still make it a value, what is said of it, and
// what the list under the field shows for it.
import FTFoundation
import Foundation
import Testing

@Suite struct SearchQueryProblemsTests {
    private func word(_ text: String) -> SearchQueryWord? { SearchQuery.words(text).first }

    // Each of these is a value being typed, or one already whole: more typing can still make it one, so it is left
    // alone.
    @Test func wordsBeingTypedCanStillBeRead() throws {
        let typing = [
            "kind:", "kind:p", "kind:pd", "kind:pdf,p", "kind:pic", "ext:do", "ext:.d", "size:", "size:1", "size:1.",
            "size:1.5", "size:1m", "size:1k", "size:>", "size:<5", "size:>1k", "size:1mb.", "size:1mb..", "size:1mb..2",
            "size:1mb..2m", "picture:>", "picture:>4", "picture:h", "picture:<19", "picture:19", "picture:!",
            "picture:!>4", "!picture:h", "modified:to", "modified:yest",
            "modified:7", "modified:>1", "modified:2026", "modified:2026-", "modified:2026-0", "modified:2026-03-1",
            "modified:2026-03.", "modified:2026-03..", "modified:2026-01..2026-0", "modified:<2026", "opened:w",
            "is:lo", "not:hid", "perm:", "perm:7", "perm:75", "perm:?5", "perm:rw", "perm:rwxr-", "perm:-rw",
            "perm:drwx", "perm:???r", "kind:!pd", "!kind:pd", "is:!lo", "size:!", "size:!5.6", "size:!5.6k",
            "!size:1", "modified:!to", "!modified:7", "taken:!2026-0", "size:>=", "size:=", "size:=>", "size:<=1",
            "size:=<1.5m", "size:!>=1", "picture:>=", "picture:=", "picture:<=h", "picture:=>19", "modified:>=",
            "modified:=", "modified:>=2026-0", "modified:<=2026", "modified:=>1", "modified:>=7d",
        ]
        for text in typing {
            let read = try #require(word(text), "\(text)")
            #expect(read.canStillBeRead, "\(text)")
            #expect(!SearchQuery.problems(text, caret: text.utf16.count, whileTyping: true).contains { _ in true })
        }
    }

    // Each of these can never be a value, however much more is typed: it is marked at once.
    @Test func wordsNoTypingCanSave() throws {
        let hopeless = [
            "kind:zzz", "kind:pdf,zz", "kind:nothing,pdf", "ext:d-o", "ext:do.c", "size:x", "size:1x", "size:1mbx",
            "size:0mb", "size:>1mb..", "size:1..2mb", "size:1tb", "size:mb", "picture:x", "picture:4kk",
            "picture:hdx", "modified:zz", "modified:0d", "modified:2026-13", "modified:2026-1-", "modified:20266",
            "modified:<7d", "modified:2026-02-32", "is:zzz", "not:hiddenx", "perm:8", "perm:77777", "perm:rwz",
            "perm:rwxr-xr-xx", "perm:www", "perm:wwwwwwwww", "!!kind:pdf", "kind:!!pdf", "size:!!1", "!size:!1",
            "modified:!!7d", "skip:!x", "picture:!!4k", "!picture:!4k", "picture:>!4k", "picture:=4k", "size:=1",
            "size:==", "size:>=>", "size:>=1mb..",
            "size:<>1", "modified:<=7d", "modified:=7", "modified:>=2026-01..", "picture:>==",
        ]
        for text in hopeless {
            let read = try #require(word(text), "\(text)")
            #expect(read.role == .unfinished, "\(text) should be unfinished")
            #expect(!read.canStillBeRead, "\(text)")
        }
    }

    // Tags and folders are names: any can still be one.
    @Test func namesAreNeverHopeless() throws {
        for text in ["tag:", "tag:anything at all", "skip:", "skip:build"] {
            #expect(try #require(word(text)).canStillBeRead, "\(text)")
        }
    }

    // A word that reads as it is is no problem, and plain words are none.
    @Test func wholeWordsHaveNoProblems() {
        #expect(SearchQuery.problems("report kind:pdf size:1mb perm:?5? !draft").isEmpty)
        #expect(SearchQuery.problems("").isEmpty)
        #expect(SearchQuery.problems("note:draft").isEmpty)
    }

    @Test func eachProblemSaysWhatIsWrongAndWhatWouldDo() throws {
        let perm = try #require(SearchQuery.problems("perm:www").first)
        #expect(perm.title == "“perm:www” can’t be read")
        #expect(perm.detail == SearchQueryKey.perm.expects)
        #expect(perm.message == "“perm:www” can’t be read. " + SearchQueryKey.perm.expects)
        #expect(SearchQuery.problems("picture:!>4k").isEmpty)
        #expect(try #require(SearchQuery.problems("picture:x").first).detail == SearchQueryKey.picture.expects)
        #expect(SearchQuery.problems("size:!5.6k").isEmpty)
        #expect(try #require(SearchQuery.problems("skip:!x").first).detail.contains("already left out"))
        #expect(try #require(SearchQuery.problems("!!kind:pdf").first).detail == "One ! is enough")
        #expect(try #require(SearchQuery.problems("kind:").first).detail.hasPrefix("Give a kind"))
        // Every word that can't be read, in order.
        #expect(SearchQuery.problems("size:x report kind:zz").map(\.word.text) == ["size:x", "kind:zz"])
    }

    // While typing, the word at the caret is left alone while it can still become a value; elsewhere, or hopeless, it
    // is a problem at once.
    @Test func theWordBeingTypedIsLeftAloneWhileItCanStillBeRead() {
        let text = "file size:1"
        #expect(SearchQuery.problems(text, caret: text.utf16.count, whileTyping: true).isEmpty)
        #expect(SearchQuery.problems(text, caret: 0, whileTyping: true).map(\.word.text) == ["size:1"])
        #expect(SearchQuery.problems(text).map(\.word.text) == ["size:1"])
        let hopeless = "perm:www"
        #expect(SearchQuery.problems(hopeless, caret: hopeless.utf16.count, whileTyping: true).count == 1)
    }

    // The list under the field says what is wrong instead of offering values, and nothing in it can be taken.
    @Test func theListSaysWhatIsWrong() throws {
        let list = try #require(SearchQuerySuggestions.make(query: "perm:www", caret: 8))
        #expect(list.rows.map(\.tone) == [.problem, .note])
        #expect(list.rows.first?.title == "“perm:www” can’t be read")
        #expect(list.rows.allSatisfy { !$0.canBeChosen })
        #expect(!list.highlightsFirst)
        #expect(list.range == NSRange(location: 0, length: 8))
        // One still being typed offers values.
        #expect(try #require(SearchQuerySuggestions.make(query: "size:1", caret: 6)).rows.allSatisfy(\.canBeChosen))
        // Every problem Return found, each with what would do.
        let all = try #require(SearchQuerySuggestions.problems(SearchQuery.problems("size:x kind:zz")))
        #expect(all.rows.map(\.tone) == [.problem, .note, .problem, .note])
        #expect(all.typedIsComplete)
    }
}
