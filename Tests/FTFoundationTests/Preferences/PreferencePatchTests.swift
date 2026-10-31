// Port of apps/desktop/src/main/bootstrap/preferencesPatch.test.ts
//
// The original's test sends each change through the IPC contract's zod schema first; the port has no IPC, so the cases
// that exercise that schema are not ported:
// N/A T-3c18b9d6 refuses numbers out of range: the IPC schema; the store clamps them (see the next test)
// N/A T-24bfbdc8 refuses values that are not one of the choices: the IPC schema; the store takes the default
// N/A T-8674afdf refuses non-booleans: the IPC schema; the store takes the default
// N/A T-ad53b11d refuses an empty folder path: the IPC schema; the store reads it as no folder
// N/A T-1fe46df6 refuses partial column settings: the IPC schema; the store fills them from the defaults
// N/A T-f1ba97c3 refuses applications without a path or name: the IPC schema; the store drops or defaults them
// N/A T-47cf769c refuses shortcuts with more than two keys: the IPC schema; the resolver keeps two
// N/A T-7207335f refuses malformed tabs and favorites: the IPC schema; the store drops them
// N/A T-88a68151 refuses out-of-bounds Rename settings: the IPC schema; the batch-rename sanitizers
// N/A T-05554ea3 applies none of a change when any part is refused: the IPC schema
import Foundation
import Testing

@testable import FTFoundation

struct PreferencePatchTests {
    static func receive(_ text: String) -> [String: JSONNode] {
        let value = (try? JSONNode.parse(Data(text.utf8)))?.object ?? [:]
        return AppPreferences.patch(from: value)
    }

    static let defaultsJSON: [String: JSONNode] = (try? JSONNode.of(AppPreferences.defaults()))?.object ?? [:]

    // T-32d7e49f F-073
    @Test func carriesEveryPreferenceAWindowMayChange() {
        #expect(AppPreferences.patch(from: Self.defaultsJSON) == Self.defaultsJSON)
        // Every preference has a way into the store.
        #expect(Set(Self.defaultsJSON.keys) == Set(AppPreferences.keys))
    }

    // T-1f095054 T-7f92bce5 T-53d8323d T-e6f6decc T-ef11b04e T-09050d18 T-c8cd6ef9 T-1bd1f865
    @Test func carriesEachGroupOfPreferencesTheOriginalListsAsSent() {
        let groups = [
            #"{"theme": "dark", "returnKeyAction": "open", "shortcutOverrides": {"newTab": ["Cmd+Option+N"]}}"#,
            #"{"searchResultsSortBy": "name", "searchResultsSortDirection": "desc"}"#,
            #"{"restoreSessionOnStartup": false, "markClipboardItems": false}"#,
            """
            {"compactDetailsView": true,
             "detailColumns": {"size": true, "modified": false, "permissions": true, "kind": true, "created": false},
             "detailColumnWidths": {"name": 360, "size": 120, "modified": 180, "permissions": 160, "kind": 148, "created": 168}}
            """,
            #"{"terminalApp": {"appPath": "/Applications/iTerm.app", "appName": "iTerm"}}"#,
            #"{"topToolbarItems": ["back", "search", "copyPath"]}"#,
            """
            {"defaultTextEditor": {"appPath": "/Applications/Zed.app", "appName": "Zed"},
             "fileActivationAction": "edit", "openItemLimit": 9}
            """,
            #"{"openWithApplications": [{"id": "zed", "appPath": "/Applications/Zed.app", "appName": "Zed"}]}"#,
        ]
        for text in groups {
            let sent = (try? JSONNode.parse(Data(text.utf8)))?.object ?? [:]
            #expect(!sent.isEmpty, "\(text)")
            #expect(Self.receive(text) == sent, "\(text)")
        }
    }

    // T-39ae895f
    @Test func carriesEachPreferenceByItselfAndNothingElse() {
        for key in AppPreferences.keys {
            let value = Self.defaultsJSON[key] ?? .null
            #expect(AppPreferences.patch(from: [key: value]) == [key: value], "\(key)")
        }
    }

    // T-3437fed8
    @Test func changesNothingWhenNothingIsSent() {
        #expect(Self.receive("{}") == [:])
    }

    // T-8b4cf80b
    @Test func keepsFalseZeroEmptyAndClearedValuesWhichAreChangesToo() {
        let text = """
            {"foldersFirst": false, "activeTabIndex": 0, "terminalApp": null, "treeRootPath": null,
             "lastVisitedPath": null, "favorites": [], "openTabs": [], "shortcutOverrides": {},
             "topToolbarItems": []}
            """
        let patch = Self.receive(text)
        #expect(patch.count == 9)
        #expect(patch["foldersFirst"] == .bool(false))
        #expect(patch["activeTabIndex"] == .number(0))
        #expect(patch["terminalApp"] == .null)
        #expect(patch["treeRootPath"] == .null)
        #expect(patch["favorites"] == .array([]))
        #expect(patch["shortcutOverrides"] == .object([:]))
        #expect(patch["topToolbarItems"] == .array([]))
    }

    // T-195759be
    @Test func dropsKeysThatAreNotPreferences() {
        #expect(Self.receive("{\"theme\": \"dark\", \"isAdmin\": true, \"version\": 2}") == ["theme": .string("dark")])
        // Even past the contract, only known preferences are copied.
        #expect(Self.receive("{\"theme\": \"light\", \"extra\": \"x\"}") == ["theme": .string("light")])
    }

    // T-5e2111de
    @Test func takesTheLimitsOfEachNumberRange() {
        let low = Self.receive(
            "{\"zoomPercent\": 75, \"treeWidth\": 220, \"inspectorWidth\": 260, \"openItemLimit\": 1, \"activeTabIndex\": 0}"
        )
        let high = Self.receive(
            "{\"zoomPercent\": 150, \"treeWidth\": 520, \"inspectorWidth\": 480, \"openItemLimit\": 50}")
        let defaults = AppPreferences.defaults()
        for patch in [low, high] {
            #expect(patch.count >= 4)
            // The store applies a limit as it is.
            let applied = PreferencesSanitizer.apply(patch, to: defaults, defaults: defaults)
            #expect(Double(applied.zoomPercent) == patch["zoomPercent"]?.number)
            #expect(Double(applied.treeWidth) == patch["treeWidth"]?.number)
            #expect(Double(applied.inspectorWidth) == patch["inspectorWidth"]?.number)
            #expect(Double(applied.openItemLimit) == patch["openItemLimit"]?.number)
        }
    }

    @Test func aPatchIsAppliedOnTopOfWhatIsStoredAndSanitized() {
        let defaults = AppPreferences.defaults(theme: .dark)
        var current = defaults
        current.treeWidth = 300
        current.foldersFirst = false
        let applied = PreferencesSanitizer.apply(
            Self.receive("{\"viewMode\": \"details\", \"zoomPercent\": 500, \"sortBy\": \"bogus\", \"isAdmin\": true}"),
            to: current, defaults: defaults)
        #expect(applied.viewMode == .details)
        #expect(applied.zoomPercent == 150)
        // A bad value takes the default it is applied over.
        #expect(applied.sortBy == defaults.sortBy)
        #expect(applied.treeWidth == 300)
        #expect(!applied.foldersFirst)
    }
}
