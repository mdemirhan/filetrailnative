import Foundation
import Testing

@testable import FTFoundation

struct PreferencePatchTests {
    static func receive(_ text: String) -> [String: JSONNode] {
        let value = (try? JSONNode.parse(Data(text.utf8)))?.object ?? [:]
        return AppPreferences.patch(from: value)
    }

    static let defaultsJSON: [String: JSONNode] = (try? JSONNode.of(AppPreferences.defaults()))?.object ?? [:]

    @Test func carriesEveryPreferenceAWindowMayChange() {
        #expect(AppPreferences.patch(from: Self.defaultsJSON) == Self.defaultsJSON)
        // Every preference has a way into the store.
        #expect(Set(Self.defaultsJSON.keys) == Set(AppPreferences.keys))
    }

    @Test func carriesEachGroupOfPreferencesAsSent() {
        let groups = [
            #"{"theme": "dark", "returnKeyAction": "open", "shortcutOverrides": {"newTab": ["Cmd+Option+N"]}}"#,
            #"{"searchResultsSortBy": "name", "searchResultsSortDirection": "desc"}"#,
            #"{"restoreSessionOnStartup": false, "markClipboardItems": false}"#,
            """
            {"density": "finder",
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

    @Test func carriesEachPreferenceByItselfAndNothingElse() {
        for key in AppPreferences.keys {
            let value = Self.defaultsJSON[key] ?? .null
            #expect(AppPreferences.patch(from: [key: value]) == [key: value], "\(key)")
        }
    }

    @Test func changesNothingWhenNothingIsSent() {
        #expect(Self.receive("{}") == [:])
    }

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

    @Test func dropsKeysThatAreNotPreferences() {
        #expect(Self.receive("{\"theme\": \"dark\", \"isAdmin\": true, \"version\": 2}") == ["theme": .string("dark")])
        // Even past the contract, only known preferences are copied.
        #expect(Self.receive("{\"theme\": \"light\", \"extra\": \"x\"}") == ["theme": .string("light")])
    }

    @Test func takesTheLimitsOfEachNumberRange() {
        let low = Self.receive(
            "{\"treeWidth\": 220, \"inspectorWidth\": 260, \"openItemLimit\": 1, \"activeTabIndex\": 0}"
        )
        let high = Self.receive(
            "{\"treeWidth\": 520, \"inspectorWidth\": 480, \"openItemLimit\": 50}")
        let defaults = AppPreferences.defaults()
        for patch in [low, high] {
            #expect(patch.count >= 3)
            // The store applies a limit as it is.
            let applied = PreferencesSanitizer.apply(patch, to: defaults, defaults: defaults)
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
            Self.receive("{\"viewMode\": \"details\", \"sortBy\": \"bogus\", \"isAdmin\": true}"),
            to: current, defaults: defaults)
        #expect(applied.viewMode == .details)
        // A bad value takes the default it is applied over.
        #expect(applied.sortBy == defaults.sortBy)
        #expect(applied.treeWidth == 300)
        #expect(!applied.foldersFirst)
    }
}
