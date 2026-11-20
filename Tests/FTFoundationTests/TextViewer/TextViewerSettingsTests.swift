import Foundation
import Testing

@testable import FTFoundation

@Suite struct TextViewerSettingsTests {
    private func node(_ json: String) throws -> JSONNode {
        try JSONNode.parse(Data(json.utf8))
    }

    @Test func savedSettingsAreReadBackAndWhatIsntUnderstoodTakesItsDefault() throws {
        let read = TextViewerSettings.sanitize(
            try node(
                """
                {"appearance": "dark", "lightTheme": "sand", "darkTheme": "nope", "fontSize": 99, "wrapLines": false}
                """))
        #expect(read.viewerAppearance == .dark)
        #expect(read.lightTheme == "sand")
        #expect(read.darkTheme == TextViewerTheme.defaultDarkID)
        #expect(read.fontSize == 13)
        #expect(!read.wrapLines)
        #expect(read.lineNumbers)
        #expect(!read.opensForEditing)
        #expect(TextViewerSettings.sanitize(try node(#"{"opensForEditing": true}"#)).opensForEditing)
        #expect(TextViewerSettings.sanitize(nil) == .defaults)
    }

    @Test func theThemeFollowsTheAppOnlyWhenAskedTo() {
        var settings = TextViewerSettings.defaults
        #expect(settings.theme(appAppearance: .light).id == "paper")
        #expect(settings.theme(appAppearance: .dark).id == "graphite")
        settings.viewerAppearance = .dark
        settings.darkTheme = "midnight"
        #expect(settings.theme(appAppearance: .light).id == "midnight")
        settings.viewerAppearance = .light
        #expect(settings.theme(appAppearance: .dark).id == "paper")
    }

    @Test func everyThemeColorsEveryKind() {
        for theme in TextViewerTheme.light + TextViewerTheme.dark {
            for kind in SyntaxKind.allCases where kind != .plain {
                #expect(theme.color(for: kind) != theme.text || kind == .strong, "\(theme.id) \(kind)")
            }
        }
    }

    @Test func aSavedViewerIsReadBackOrDropped() throws {
        let following = ViewerPreference.sanitize(try node(#"{"mode": "following", "editing": true}"#))
        #expect(following == ViewerPreference(mode: .following, path: nil, preview: true, editing: true))
        let pinned = ViewerPreference.sanitize(try node(#"{"mode": "pinned", "path": "/a/b.md", "preview": false}"#))
        #expect(pinned == ViewerPreference(mode: .pinned, path: "/a/b.md", preview: false))
        // A file in place or pinned needs its file; a path that isn't one, or a mode not known, is no viewer.
        #expect(ViewerPreference.sanitize(try node(#"{"mode": "inPlace"}"#)) == nil)
        #expect(ViewerPreference.sanitize(try node(#"{"mode": "inPlace", "path": "relative"}"#)) == nil)
        #expect(ViewerPreference.sanitize(try node(#"{"mode": "sideways", "path": "/a"}"#)) == nil)
    }
}

/// A tab saved with a viewer reads back with it; one saved before the viewer reads as none.
@Suite struct ViewerInSavedTabsTests {
    @Test func aSavedTabsViewersAreReadBack() throws {
        let json = """
            [{"path": "/Users/me", "viewMode": "list", "viewer": {"mode": "inPlace", "path": "/Users/me/a.txt"},
              "secondPane": {"path": "/Users/me", "viewMode": "list",
                             "viewer": {"mode": "following", "path": "/Users/me/b.txt", "editing": true}}},
             {"path": "/Users/me", "viewMode": "list", "viewer": {"mode": "following"}}]
            """
        let tabs = PreferencesSanitizer.openTabs(
            try JSONNode.parse(Data(json.utf8)), includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true)
        #expect(tabs.count == 2)
        #expect(tabs[0].viewer == ViewerPreference(mode: .inPlace, path: "/Users/me/a.txt"))
        #expect(
            tabs[0].secondPane?.viewer == ViewerPreference(mode: .following, path: "/Users/me/b.txt", editing: true))
        // A first pane shows a file only in place: following needs a pane beside it.
        #expect(tabs[1].viewer == nil)
        #expect(tabs[0].activePaneAlone.viewer == tabs[0].viewer)
    }
}
