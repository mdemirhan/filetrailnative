import FTFoundation
import Foundation
import Testing

struct NameOrderTests {
    private func sorted(_ names: [String], _ order: NameOrder) -> [String] {
        names.sorted { order.compare($0, $1) < 0 }
    }

    @Test func putsNumbersInOrderOfValueAndSetsCaseAndAccentsAside() {
        let english = NameOrder(localeIdentifier: "en_US")
        #expect(sorted(["file10.txt", "File2.txt", "file1.txt"], english) == ["file1.txt", "File2.txt", "file10.txt"])
        #expect(english.compare("Résumé", "resume") == 0)
        #expect(english.compare("apple", "Apple") == 0)
        // Words (kinds, extensions): case and accents decide only between words otherwise the same, lowercase first;
        // digits count one by one.
        #expect(english.compareWords("apple", "Apple") < 0)
        #expect(english.compareWords("Apple", "banana") < 0)
        #expect(english.compareWords("MP10 File", "MP2 File") < 0)
    }

    @Test func followsTheAlphabetOfTheLanguage() {
        let names = ["öga", "zebra", "åsna", "apa", "ärta"]
        // In English, å, ä and ö are a and o with accents.
        #expect(sorted(names, NameOrder(localeIdentifier: "en_US")) == ["apa", "ärta", "åsna", "öga", "zebra"])
        // In Swedish they are letters of their own, after z.
        #expect(sorted(names, NameOrder(localeIdentifier: "sv_SE")) == ["apa", "zebra", "åsna", "ärta", "öga"])
        // In Turkish, dotless ı comes before i.
        let turkish = ["jilet", "inek", "ırmak", "hasta"]
        #expect(sorted(turkish, NameOrder(localeIdentifier: "en_US")) == ["hasta", "inek", "ırmak", "jilet"])
        #expect(sorted(turkish, NameOrder(localeIdentifier: "tr_TR")) == ["hasta", "ırmak", "inek", "jilet"])
    }

    @Test func comparesAsTextTheSameWayWithoutTheSystemsCollator() {
        let names = ["öga", "zebra", "file10", "File2", "åsna", "Apa"]
        let text = NameOrder(localeIdentifier: "sv_SE", systemCollator: false)
        #expect(sorted(names, text) == sorted(names, NameOrder(localeIdentifier: "sv_SE")))
        var key: [UInt8] = []
        #expect(!text.appendSortKey(of: "a", to: &key))
        #expect(key.isEmpty)
    }

    @Test func sortKeysCompareAsTheNamesDo() {
        let order = NameOrder(localeIdentifier: "sv_SE")
        func key(_ name: String) -> [UInt8] {
            var bytes: [UInt8] = []
            #expect(order.appendSortKey(of: name, to: &bytes))
            return bytes
        }
        let names = ["öga", "Zebra", "file10", "file2", "åsna", "apa", "Apa"]
        let byKey = names.sorted { key($0).lexicographicallyPrecedes(key($1)) }
        #expect(byKey.map { key($0) } == sorted(names, order).map { key($0) })
        #expect(key("apa") == key("Apa"))
    }

    @Test func naturalCompareIsTheCurrentOrder() {
        for (left, right) in [("file2", "file10"), ("b", "A"), ("same", "SAME"), ("z", "å")] {
            #expect(naturalCompare(left, right).rawValue == NameOrder.current.compare(left, right))
        }
    }
}
