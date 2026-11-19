// The rules by which a golden's case is written as changes to its base: what each change does, and what is refused
import FTFoundation
import FTTestSupport
import Foundation
import Testing

struct GoldenChangesTests {
    /// A value from its JSON text.
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// `change` applied to `base`, both as JSON text, as JSON text with its keys in order.
    private func applied(_ change: String, to base: String) throws -> String {
        let result = try GoldenChanges.applying(json(change), to: json(base))
        let data = try JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Why `change` applied to `base` is refused, and where; nil when it is applied.
    private func refusal(_ change: String, to base: String) throws -> GoldenChanges.Refused? {
        do {
            _ = try GoldenChanges.applying(json(change), to: json(base))
            return nil
        } catch let refused as GoldenChanges.Refused {
            return refused
        }
    }

    private func refused(_ place: String, _ reason: String) -> GoldenChanges.Refused {
        GoldenChanges.Refused(place: place, reason: reason)
    }

    // MARK: What each change does

    @Test func noChangesLeaveAnObjectAListAndAValueAsTheyAre() throws {
        #expect(try applied("{}", to: #"{"a":1,"b":[2]}"#) == #"{"a":1,"b":[2]}"#)
        #expect(try applied("{}", to: "[1,2]") == "[1,2]")
        #expect(try applied("{}", to: #""text""#) == #""text""#)
        #expect(try applied(#"{"b":{}}"#, to: #"{"a":1,"b":[2]}"#) == #"{"a":1,"b":[2]}"#)
    }

    @Test func anObjectChangesAnObjectKeyByKey() throws {
        let base = #"{"a":1,"b":{"c":2,"d":3},"e":[1]}"#
        #expect(try applied(#"{"a":5}"#, to: base) == #"{"a":5,"b":{"c":2,"d":3},"e":[1]}"#)
        #expect(try applied(#"{"b":{"d":4}}"#, to: base) == #"{"a":1,"b":{"c":2,"d":4},"e":[1]}"#)
        // A key the value doesn't have takes the change as it is, an empty object too.
        #expect(try applied(#"{"f":{"g":[1]}}"#, to: #"{"a":1}"#) == #"{"a":1,"f":{"g":[1]}}"#)
        #expect(try applied(#"{"f":{}}"#, to: #"{"a":1}"#) == #"{"a":1,"f":{}}"#)
        #expect(try applied(#"{"b":{"h":{"i":1}}}"#, to: base) == #"{"a":1,"b":{"c":2,"d":3,"h":{"i":1}},"e":[1]}"#)
    }

    @Test func deleteRemovesAKey() throws {
        #expect(try applied(#"{"a":{"$delete":true}}"#, to: #"{"a":1,"b":2}"#) == #"{"b":2}"#)
        let inner = #"{"b":{"c":{"$delete":true}}}"#
        #expect(try applied(inner, to: #"{"a":1,"b":{"c":2,"d":3}}"#) == #"{"a":1,"b":{"d":3}}"#)
        // A key whose value is null is there, and goes.
        #expect(try applied(#"{"a":{"$delete":true}}"#, to: #"{"a":null}"#) == "{}")
    }

    @Test func removeTakesTheFirstEqualItemAndInsertPutsOneAfterAnother() throws {
        let base = #"["a","b","c"]"#
        #expect(try applied(#"{"$remove":["b"]}"#, to: base) == #"["a","c"]"#)
        #expect(try applied(#"{"$insert":[["a","x"]]}"#, to: base) == #"["a","x","b","c"]"#)
        #expect(try applied(#"{"$insert":[[null,"x"]]}"#, to: base) == #"["x","a","b","c"]"#)
        #expect(try applied(#"{"$insert":[["c","x"]]}"#, to: base) == #"["a","b","c","x"]"#)
        // One inserted can be the next one's `after`, and null puts one first in an empty list.
        #expect(try applied(#"{"$insert":[["a","x"],["x","y"]]}"#, to: base) == #"["a","x","y","b","c"]"#)
        #expect(try applied(#"{"$insert":[[null,"x"]]}"#, to: "[]") == #"["x"]"#)
        // Removed first, then inserted: after an item that stays, and never after the one that went.
        #expect(try applied(#"{"$remove":["b"],"$insert":[["a","x"]]}"#, to: base) == #"["a","x","c"]"#)
        #expect(try applied(#"{"$remove":[],"$insert":[]}"#, to: base) == base)
        // Objects are equal whatever the order of their keys.
        #expect(
            try applied(
                #"{"$remove":[{"id":"b","n":1}],"$insert":[[{"n":2,"id":"c"},7]]}"#,
                to: #"[{"n":1,"id":"b"},{"id":"c","n":2}]"#) == #"[{"id":"c","n":2},7]"#)
        #expect(try applied(#"{"a":{"$remove":[1]}}"#, to: #"{"a":[1,2]}"#) == #"{"a":[2]}"#)
    }

    // An item a list has more than once goes one at a time, the first each time: a case that removes it twice, or as
    // often as it is there, is as written.
    @Test func anItemThereMoreThanOnceIsRemovedOnceForEachTimeItIsNamed() throws {
        let base = #"["a","b","a","c","a"]"#
        #expect(try applied(#"{"$remove":["a"]}"#, to: base) == #"["b","a","c","a"]"#)
        #expect(try applied(#"{"$remove":["a","a"]}"#, to: base) == #"["b","c","a"]"#)
        #expect(try applied(#"{"$remove":["a","a","a"]}"#, to: base) == #"["b","c"]"#)
        #expect(try applied(#"{"$insert":[["a","x"]]}"#, to: base) == #"["a","x","b","a","c","a"]"#)
        #expect(
            try refusal(#"{"$remove":["a","a","a","a"]}"#, to: base)
                == refused("changes.$remove[3]", #""a" isn't in the list"#))
    }

    @Test func setAndAnyOtherValueTakeThePlace() throws {
        #expect(try applied(#"{"$set":{"x":1}}"#, to: #"{"a":1}"#) == #"{"x":1}"#)
        #expect(try applied(#"{"$set":[]}"#, to: "[1,2]") == "[]")
        #expect(try applied(#"{"a":{"$set":{}}}"#, to: #"{"a":{"b":1}}"#) == #"{"a":{}}"#)
        #expect(try applied(#"{"a":{"$set":null}}"#, to: #"{"a":{"b":1}}"#) == #"{"a":null}"#)
        // What a key doesn't have yet is set too.
        #expect(try applied(#"{"n":{"$set":{"b":1}}}"#, to: #"{"a":1}"#) == #"{"a":1,"n":{"b":1}}"#)
        for value in [#""text""#, "5", "true", "false", "null", "[3,4]"] {
            #expect(try applied(value, to: #"{"a":1}"#) == value)
            #expect(try applied(#"{"a":\#(value)}"#, to: #"{"a":[1]}"#) == #"{"a":\#(value)}"#)
        }
        // An object takes the place of a value that isn't one.
        #expect(try applied(#"{"a":{"b":1}}"#, to: #"{"a":null}"#) == #"{"a":{"b":1}}"#)
        #expect(try applied(#"{"a":{"b":1}}"#, to: #"{"a":[1]}"#) == #"{"a":{"b":1}}"#)
    }

    // MARK: What is refused

    @Test func removingOrInsertingAfterAnItemThatIsNotThereIsRefused() throws {
        let base = #"{"list":["a","b"]}"#
        #expect(
            try refusal(#"{"list":{"$remove":["a","z"]}}"#, to: base)
                == refused("changes.list.$remove[1]", #""z" isn't in the list"#))
        #expect(
            try refusal(#"{"list":{"$insert":[["a","x"],["z","y"]]}}"#, to: base)
                == refused("changes.list.$insert[1]", #""z", to insert after, isn't in the list"#))
        // After an item the same change removed: it is gone by then.
        #expect(
            try refusal(#"{"list":{"$remove":["a"],"$insert":[["a","x"]]}}"#, to: base)
                == refused("changes.list.$insert[0]", #""a", to insert after, isn't in the list"#))
    }

    @Test func aRemoveOrAnInsertOfTheWrongShapeIsRefused() throws {
        let base = #"["a","b"]"#
        #expect(
            try refusal(#"{"$remove":"a"}"#, to: base)
                == refused("changes.$remove", "not a list of the items to remove"))
        #expect(
            try refusal(#"{"$insert":["a","x"]}"#, to: base)
                == refused("changes.$insert[0]", "not a pair [after, item]"))
        #expect(
            try refusal(#"{"$insert":[["a","x"],["a","y","z"]]}"#, to: base)
                == refused("changes.$insert[1]", "not a pair [after, item]"))
        #expect(
            try refusal(#"{"$insert":[["x"]]}"#, to: base) == refused("changes.$insert[0]", "not a pair [after, item]"))
        #expect(
            try refusal(#"{"$insert":{"a":"x"}}"#, to: base)
                == refused("changes.$insert", "not a list of pairs [after, item]"))
    }

    @Test func aListChangeToWhatIsNotAListIsRefused() throws {
        #expect(
            try refusal(#"{"a":{"$remove":[1]}}"#, to: #"{"a":{"b":1}}"#)
                == refused("changes.a", "$remove and $insert change a list, and an object isn't one"))
        #expect(
            try refusal(#"{"a":{"$insert":[[null,1]]}}"#, to: #"{"a":"text"}"#)
                == refused("changes.a", #"$remove and $insert change a list, and "text" isn't one"#))
        #expect(
            try refusal(#"{"n":{"$insert":[[null,1]]}}"#, to: #"{"a":1}"#)
                == refused("changes.n", "$remove and $insert change a list, and a key that isn't there isn't one"))
    }

    @Test func aDeleteOfNoKeyOrWithAnythingButTrueIsRefused() throws {
        let base = #"{"a":1,"b":{"c":2}}"#
        #expect(
            try refusal(#"{"z":{"$delete":true}}"#, to: base)
                == refused("changes.z", "$delete of a key that isn't there"))
        #expect(
            try refusal(#"{"b":{"z":{"$delete":true}}}"#, to: base)
                == refused("changes.b.z", "$delete of a key that isn't there"))
        for (value, text) in [("1", "1"), ("false", "false"), (#""true""#, #""true""#), ("null", "null")] {
            #expect(
                try refusal(#"{"a":{"$delete":\#(value)}}"#, to: base)
                    == refused("changes.a", "$delete takes true, not \(text)"))
        }
        // Where no key is being changed: a case's whole changes, a list's place.
        #expect(
            try refusal(#"{"$delete":true}"#, to: base)
                == refused("changes", "$delete removes a key of an object, and there is none here"))
        // In a key the base doesn't have, and in one whose value isn't an object: nothing reads it as a change there.
        #expect(
            try refusal(#"{"n":{"m":{"$delete":true}}}"#, to: base)
                == refused(
                    "changes.n", "$delete isn't read as a change in an object put in place of a key that isn't there"))
        #expect(
            try refusal(#"{"a":{"m":{"$delete":true}}}"#, to: base)
                == refused("changes.a", "$delete isn't read as a change in an object put in place of 1"))
    }

    @Test func aChangeWithOtherKeysBesideItIsRefused() throws {
        #expect(
            try refusal(#"{"a":{"$set":1,"b":2}}"#, to: #"{"a":{"b":1}}"#)
                == refused("changes.a.b", "beside $set, which stands alone"))
        #expect(
            try refusal(#"{"a":{"$set":[1],"$remove":[1]}}"#, to: #"{"a":[1]}"#)
                == refused("changes.a.$remove", "beside $set, which stands alone"))
        #expect(
            try refusal(#"{"a":{"$remove":[1],"b":2}}"#, to: #"{"a":[1]}"#)
                == refused("changes.a.b", "beside $insert and $remove, which stand alone"))
        #expect(
            try refusal(#"{"a":{"$delete":true,"b":2}}"#, to: #"{"a":{"b":1}}"#)
                == refused("changes.a.b", "beside $delete, which stands alone"))
    }

    @Test func anUnknownMarkerIsRefusedAndNeverBecomesAKey() throws {
        let base = #"{"a":{"b":1},"list":[1]}"#
        #expect(
            try refusal(#"{"a":{"$delet":true}}"#, to: base)
                == refused("changes.a.$delet", "not a change: $set, $remove, $insert and $delete are"))
        #expect(
            try refusal(#"{"$sett":1}"#, to: base)
                == refused("changes.$sett", "not a change: $set, $remove, $insert and $delete are"))
        #expect(
            try refusal(#"{"list":{"$removes":[1]}}"#, to: base)
                == refused("changes.list", "$removes isn't read as a change in an object put in place of a list"))
        #expect(
            try refusal(#"{"list":{"$remove":[1],"$inserts":[]}}"#, to: base)
                == refused("changes.list.$inserts", "beside $insert and $remove, which stand alone"))
        // Deep in an object a new key takes as it is, through a list too.
        #expect(
            try refusal(#"{"n":{"m":[{"$set":1}]}}"#, to: base)
                == refused(
                    "changes.n", "$set isn't read as a change in an object put in place of a key that isn't there"))
    }

    // MARK: A file's load

    private struct Output: Decodable, Equatable {
        let list: [String]
        let note: String?
    }

    private func file(_ changes: String) -> Data {
        Data(
            """
            {"bases": {"plain": {"input": 1, "output": {"list": ["a", "b"], "note": "n"}}},
             "cases": [{"name": "first", "input": 2, "changes": {}},
                       {"name": "second: changed", "input": 3, "changes": \(changes)}]}
            """.utf8)
    }

    @Test func aFilesCasesAreItsBasesAndEachCasesChangesApplied() throws {
        let cases: [GoldenCase<Int, Output>] = try GoldenChanges.load(
            suite: "made-up",
            from: file(#"{"list": {"$remove": ["a"], "$insert": [["b", "c"]]}, "note": {"$delete": true}}"#))
        #expect(cases.map(\.name) == ["base plain", "first", "second: changed"])
        #expect(cases.map(\.input) == [1, 2, 3])
        #expect(
            cases.map(\.output) == [
                Output(list: ["a", "b"], note: "n"), Output(list: ["a", "b"], note: "n"),
                Output(list: ["b", "c"], note: nil),
            ])
    }

    // A change that is refused fails the whole load, and the error names the file, the case and the place.
    @Test func aRefusedChangeFailsTheLoadNamingTheFileTheCaseAndThePlace() {
        func failure(_ changes: String) -> String? {
            do {
                let _: [GoldenCase<Int, Output>] = try GoldenChanges.load(suite: "made-up", from: file(changes))
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(
            failure(#"{"list": {"$remove": ["z"]}}"#)
                == #"Golden/made-up.json: second: changed: changes.list.$remove[0]: "z" isn't in the list"#)
        #expect(
            failure(#"{"list": {"$insert": [["z", "c"]]}}"#)
                == "Golden/made-up.json: second: changed: changes.list.$insert[0]: "
                + #""z", to insert after, isn't in the list"#)
        #expect(
            failure(#"{"note": {"$delet": true}}"#)
                == "Golden/made-up.json: second: changed: changes.note: "
                + #"$delet isn't read as a change in an object put in place of "n""#)
        #expect(
            failure(#"{"other": {"$delete": true}}"#)
                == "Golden/made-up.json: second: changed: changes.other: $delete of a key that isn't there")
    }

    // The six goldens written this way hold no change the rules refuse: each loads whole.
    @Test func everyGoldenWrittenAsChangesLoads() throws {
        for suite in [
            "command-availability", "context-menu", "help-content", "prefs-sanitize", "shortcut-resolution",
            "toolbar-sanitize",
        ] {
            let cases: [GoldenCase<JSONNode, JSONNode>] = try GoldenChanges.load(suite: suite)
            #expect(!cases.isEmpty, "\(suite)")
        }
    }
}
