import Testing

@testable import FTFoundation

struct NameMatcherTests {
    private func marks(_ query: String, _ name: String, _ mode: NameMatchMode = .fuzzy) -> [String] {
        guard let matcher = NameMatcher(query, mode: mode) else { return [] }
        let units = Array(name.utf16)
        return matcher.marks(in: name).map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) }
    }

    @Test func textThatFoldsToNothingMakesNoMatcher() {
        #expect(NameMatcher("", mode: .fuzzy) == nil)
        #expect(NameMatcher(" ", mode: .contains) != nil)
    }

    @Test func marksARunWhereItFirstIs() {
        #expect(marks("port", "report-port.txt", .contains) == ["port"])
        #expect(marks("port", "report-port.txt") == ["port"])
        #expect(marks("zzz", "report.txt", .contains) == [])
    }

    @Test func marksTheLettersAFuzzyMatchFitsBest() {
        // The letters starting words, not the first t and s along the way.
        #expect(marks("fts", "FileTrailSettings.swift") == ["F", "T", "S"])
        #expect(marks("rpt", "report.pdf") == ["r", "p", "t"])
        // Letters side by side are marked as one.
        #expect(marks("filset", "FileTrailSettings.swift") == ["Fil", "Set"])
        #expect(marks("tpr", "report.pdf") == [])
    }

    @Test func marksTheLettersAsTheNameStoresThem() {
        // "é" stored as "e" and its accent: the mark takes both.
        let decomposed = "Cafe\u{301} menu"
        #expect(marks("cafe", decomposed, .contains) == ["Cafe\u{301}"])
        #expect(marks("\u{E9}", decomposed, .contains) == ["e\u{301}"])
        #expect(marks("cm", decomposed) == ["C", "m"])
    }

    @Test func comparesLettersOneWayForAccents() {
        func matches(_ query: String, _ name: String) -> Bool {
            NameMatcher(query, mode: .contains)?.matches(name) ?? false
        }
        #expect(matches("e", "\u{E9}t\u{E9}"))
        #expect(matches("E", "\u{C9}T\u{C9}"))
        #expect(!matches("\u{E9}", "ete"))
        #expect(matches("\u{E9}", "e\u{301}te"))
        // Greek: a plain vowel finds the accented one, and either sigma finds the other.
        #expect(matches("σισυφος", "Σίσυφος"))
        #expect(matches("ς", "σοφία"))
        #expect(matches("σ", "ΟΔΟΣ"))
        // Letters of their own, and scripts whose marks are not accents on a Latin, Greek or Cyrillic letter.
        #expect(!matches("o", "ø"))
        #expect(!matches("l", "ł"))
        #expect(!matches("か", "が"))
        #expect(matches("i", "İzmir"))
        // Case folds as Unicode folds it, as fd's case rule does: the long s is an s, the micro sign a mu.
        #expect(matches("\u{17F}", "Sun.txt"))
        #expect(matches("s", "\u{17F}un.txt"))
        #expect(matches("\u{B5}", "ΜΑΘ.txt"))
        #expect(!matches("ss", "Straße"))
        #expect(!matches("ı", "izmir"))
    }

    @Test func fuzzyScoresLettersSideBySideAndAtWordStartsHigher() throws {
        let matcher = try #require(NameMatcher("fts", mode: .fuzzy))
        let wordStarts = try #require(matcher.score("FileTrailSettings.swift"))
        let scattered = try #require(matcher.score("afterthoughts.txt"))
        #expect(wordStarts > scattered)
        #expect(matcher.score("nothing here") == nil)
        let run = try #require(NameMatcher("rep", mode: .fuzzy))
        #expect(try #require(run.score("report")) > (try #require(run.score("ramp-equipment"))))
    }

    // MARK: Ligatures and full-width forms

    @Test func aLigatureIsItsLettersAndAFullWidthLetterTheLetter() {
        func matches(_ query: String, _ name: String, _ mode: NameMatchMode = .contains) -> Bool {
            NameMatcher(query, mode: mode)?.matches(name) ?? false
        }
        #expect(matches("fi", "\u{FB01}le.txt"))
        #expect(matches("file", "\u{FB01}le.txt"))
        #expect(matches("FILE", "\u{FB01}le.txt"))
        #expect(matches("office", "o\u{FB03}ce"))
        // A run may begin or end inside a ligature.
        #expect(matches("fic", "o\u{FB03}ce"))
        #expect(matches("of", "o\u{FB03}ce"))
        #expect(matches("st", "be\u{FB06}"))
        #expect(!matches("fl", "\u{FB01}le.txt"))
        // Typed as a ligature, it finds the letters.
        #expect(matches("\u{FB01}le", "FILE.TXT"))
        #expect(matches("\u{FB01}", "\u{FB01}le.txt"))
        #expect(matches("abc", "\u{FF21}\u{FF22}\u{FF23}"))
        #expect(matches("ABC", "\u{FF41}\u{FF42}\u{FF43}"))
        #expect(matches("\u{FF41}\u{FF42}", "abc.txt"))
        #expect(matches("12", "\u{FF11}\u{FF12}.txt"))
        #expect(matches("a.t", "a\u{FF0E}txt"))
        #expect(matches("fe", "\u{FB01}le", .fuzzy))
        #expect(!matches("ss", "Stra\u{DF}e"))
    }

    // Marks are offsets into the name as stored, whole characters only.
    @Test func marksStayWithinTheNameAsStored() {
        // A ligature is one character: any of its letters marks it whole.
        #expect(marks("fi", "\u{FB01}le.txt", .contains) == ["\u{FB01}"])
        #expect(marks("il", "\u{FB01}le.txt", .contains) == ["\u{FB01}l"])
        #expect(marks("fc", "o\u{FB03}ce") == ["\u{FB03}c"])
        #expect(marks("bc", "\u{FF21}\u{FF22}\u{FF23}", .contains) == ["\u{FF22}\u{FF23}"])
        #expect(marks("ac", "\u{FF21}\u{FF22}\u{FF23}") == ["\u{FF21}", "\u{FF23}"])
        // A family joined by zero-width joiners, a flag and a skin tone are one character each.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(marks("ab", "a\(family)b") == ["a", "b"])
        #expect(marks("\u{1F469}", "a\(family)b", .contains) == [family])
        #expect(marks("b", "\(family)b", .contains) == ["b"])
        let flag = "\u{1F1F9}\u{1F1F7}"
        #expect(marks("tr", "\(flag) trip") == ["tr"])
        #expect(marks("\u{1F1F7}", "x\(flag)y", .contains) == [flag])
        #expect(marks("xy", "x\(flag)y") == ["x", "y"])
        // The dotted capital I lowercases to an "i" and a dot above: one character of the name.
        #expect(marks("iz", "\u{130}zmir", .contains) == ["\u{130}z"])
        #expect(marks("zm", "\u{130}zmir", .contains) == ["zm"])
        // A decomposed letter with two marks stacked on it.
        let stacked = "e\u{302}\u{301}"
        #expect(marks("vet", "Vi\(stacked)t", .fuzzy) == ["V", "\(stacked)t"])
        #expect(marks("t", "Vi\(stacked)t", .contains) == ["t"])
        #expect(marks("\u{1EBF}", "Vi\(stacked)t", .contains) == [stacked])
    }

    @Test func everyMarkIsARangeOfWholeCharactersOfTheName() throws {
        let names = [
            "\u{FB01}le o\u{FB03}ce.txt", "\u{FF21}\u{FF22}\u{FF23} \u{FF11}.txt", "\u{130}zmir \u{131}",
            "Vie\u{302}\u{301}t Nam", "a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b", "\u{1F1F9}\u{1F1F7}x",
            "q\u{303}1x", "\u{1F44D}\u{1F3FD} ok", "Stra\u{DF}e", "\u{3A3}\u{3AF}\u{3C3}\u{3C5}\u{3C6}\u{3BF}\u{3C2}",
        ]
        let queries = ["f", "fi", "i", "ce", "a", "abc", "1", "iz", "e", "vt", "ab", "x", "q1", "ok", "s", "\u{3C3}"]
        for name in names {
            let units = Array(name.utf16)
            // Where each character of the name begins, in its units.
            var starts: Set<Int> = [units.count]
            var offset = 0
            for character in name {
                starts.insert(offset)
                offset += String(character).utf16.count
            }
            for query in queries {
                for mode in NameMatchMode.allCases {
                    let matcher = try #require(NameMatcher(query, mode: mode))
                    let found = matcher.marks(in: name)
                    #expect(found.isEmpty != matcher.matches(name), "\(query) in \(name)")
                    var end = 0
                    for mark in found {
                        #expect(mark.start >= end && mark.start < mark.end && mark.end <= units.count)
                        #expect(starts.contains(mark.start) && starts.contains(mark.end), "\(query) in \(name)")
                        end = mark.end
                    }
                }
            }
        }
    }

    // MARK: The best fit

    /// The fit worked out the plain way, over a whole table, for ASCII names: what `score` must give.
    private func plainScore(_ query: String, _ name: String) -> Int? {
        let typed = Array(query.lowercased().utf8)
        let stored = Array(name.utf8)
        let letters = stored.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        func isLetterOrDigit(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        func startsWord(_ index: Int) -> Bool {
            guard index > 0 else { return true }
            let before = stored[index - 1]
            return !isLetterOrDigit(before) || ((97...122).contains(before) && (65...90).contains(stored[index]))
        }
        let none = Int.min / 4
        var best = [[Int]](repeating: [Int](repeating: none, count: letters.count), count: typed.count)
        for i in typed.indices {
            for j in letters.indices where letters[j] == typed[i] {
                let landing = 16 + (startsWord(j) ? 8 : 0)
                if i == 0 {
                    best[i][j] = landing - min(j, 8)
                    continue
                }
                var value = none
                if j >= 1, best[i - 1][j - 1] > none { value = best[i - 1][j - 1] + 16 + 8 }
                for k in 0..<max(0, j - 1) where best[i - 1][k] > none {
                    value = max(value, best[i - 1][k] - 3 - (j - 2 - k) + landing)
                }
                best[i][j] = value
            }
        }
        let top = best.last?.max() ?? none
        return top > none ? top : nil
    }

    @Test func theFitIsTheBestOverEveryWayTheLettersCanLand() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcAB_ .1")
        for _ in 0..<400 {
            let name = String((0..<Int.random(in: 1...24, using: &generator)).map { _ in alphabet.randomElement()! })
            let query = String((0..<Int.random(in: 1...5, using: &generator)).map { _ in "abc1".randomElement()! })
            let matcher = try #require(NameMatcher(query, mode: .fuzzy))
            #expect(matcher.score(name) == plainScore(query, name), "\(query) in \(name)")
        }
    }

    @Test func weighingOneNameAfterAnotherGivesWhatEachGivesAlone() throws {
        struct Entry: ListFilterEntry {
            var name: String
        }
        // Long and short names, ASCII and beyond, through one cache: the room kept between names is not read stale.
        let names = [
            String(repeating: "x", count: 600) + "f-t-s", "f t s", "FileTrailSettings.swift", "afterthoughts.txt",
            "Fe\u{301}te du Soleil.txt", "\u{FB01}tness.txt", "fits", "f-t-s", "\u{C9}f_ts",
        ]
        let matcher = try #require(NameMatcher("fts", mode: .fuzzy))
        let scores = names.map { matcher.score($0) ?? Int.min }
        let cache = FoldedNameCache()
        for start in names.indices {
            let order = Array(names[start...] + names[..<start])
            let expected = try #require(
                order.enumerated().max {
                    let (a, b) = (matcher.score($0.element) ?? Int.min, matcher.score($1.element) ?? Int.min)
                    return a < b || (a == b && $0.offset > $1.offset)
                })
            let picked = ListFilter.selection(in: order.map(Entry.init), query: "fts", mode: .fuzzy, cache: cache)
            #expect(picked?.name == expected.element, "\(order)")
        }
        #expect(scores.contains { $0 > Int.min })
    }

    @Test func tellsAPrefixAndARunWhateverTheMode() throws {
        let matcher = try #require(NameMatcher("doc", mode: .fuzzy))
        #expect(matcher.isPrefix(of: "Documents"))
        #expect(!matcher.isPrefix(of: "my doc.txt"))
        #expect(matcher.isContained(in: "my doc.txt"))
        #expect(!matcher.isContained(in: "d-o-c"))
        #expect(matcher.matches("d-o-c"))
    }
}
