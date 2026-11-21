// Checks what a pane shows, and where each setting comes from, against the view-resolution golden: the folder's view
// (its own, from above, stopped, changed on screen) with each kind of tab view override
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct PaneViewResolutionGoldenTests {
    struct Input: Codable {
        struct Override: Codable {
            var folder: String
            var choice: FolderViewsChoice
            var kept: [String]
        }

        var views: [FolderView]
        var folder: String
        /// The settings changed on screen and not saved: over the folder's view, or a view waiting for Save.
        var unsaved: FolderViewKeeps?
        var override: Override?
    }

    /// What the pane carries: a value in every setting that no folder view in the golden has.
    static let carried = FolderViewKeeps(
        view: .icons, groupBy: GroupByPreference.none, sort: FolderViewSort(by: .name, direction: .asc),
        foldersFirst: true,
        columns: FolderViewColumns(
            visibility: .defaults, order: OptionalDetailColumnKey.menuOrder, widths: .defaults),
        size: FolderViewSizes(
            iconSizes: .iconDefaults, compactListWidths: .compactListDefaults, previewCounts: .previewCountDefaults))

    /// Each setting as "value · source".
    static func output(_ shown: PaneViewResolution.Shown) -> [String: String] {
        let keeps = shown.keeps
        func value(_ setting: FolderViewSetting) -> String {
            switch setting {
            case .view: keeps.view?.rawValue ?? "?"
            case .groupBy: keeps.groupBy?.rawValue ?? "?"
            case .sort: keeps.sort.map { "\($0.by.rawValue) \($0.direction.rawValue)" } ?? "?"
            case .foldersFirst: keeps.foldersFirst.map { "\($0)" } ?? "?"
            case .columns: keeps.columns.map { $0.visibility.kind ? "kind shown" : "kind hidden" } ?? "?"
            case .size: keeps.size.map { "\($0.iconSizes.standard)" } ?? "?"
            }
        }
        var result: [String: String] = [:]
        for setting in FolderViewSetting.allCases {
            result[setting.rawValue] = "\(value(setting)) · \(shown.sources[setting]?.rawValue ?? "?")"
        }
        return result
    }

    static func shown(_ input: Input) -> [String: String] {
        let views = FolderViews(input.views)
        var onScreen = views.use(for: input.folder).map(FolderViewOnScreen.init)
        if let unsaved = input.unsaved {
            var changed = onScreen ?? .draft(FolderView(path: input.folder))
            for setting in unsaved.kept { changed.shown.take(setting, from: unsaved) }
            onScreen = changed
        }
        let override = input.override.map { override in
            TabViewOverride(
                folder: override.folder, choice: override.choice,
                kept: Set(override.kept.compactMap(FolderViewSetting.init(rawValue:))))
        }
        return output(
            PaneViewResolution.shown(carried: carried, onScreen: onScreen, override: override, folder: input.folder))
    }

    @Test func eachSettingShowsTheValueAndSourceTheGoldenGives() throws {
        let cases: [GoldenCase<Input, [String: String]>] = try GoldenChanges.load(suite: "view-resolution")
        #expect(cases.count == 72)
        Golden.expectMatches(cases) { Self.shown($0) }
    }

    @Test func everySettingHasExactlyOneSource() {
        let override = TabViewOverride(folder: "/u/a", choice: .tabViewFirst, kept: [.view])
        let shown = PaneViewResolution.shown(carried: Self.carried, onScreen: nil, override: override, folder: "/u/a")
        #expect(Set(shown.sources.keys) == Set(FolderViewSetting.allCases))
        #expect(FolderViewSetting.allCases.allSatisfy { shown.keeps.keeps($0) })
    }

    @Test func anOverrideHoldsByThePathsBytes() {
        let override = TabViewOverride(folder: "/u/caf\u{E9}", choice: .notUsed, kept: [])
        #expect(override.holds(in: "/u/caf\u{E9}"))
        // The same name with its accent stored apart is another folder on a disk that keeps them apart.
        #expect(!override.holds(in: "/u/cafe\u{301}"))
        #expect(!override.holds(in: nil))
        #expect(!TabViewOverride(folder: "/u", choice: .folderFirst, kept: [.view]).holds(in: "/u"))
    }

    @Test func aChangeByHandTakesItsSettingOutOfTheOverride() {
        let first = TabViewOverride(folder: "/u", choice: .tabViewFirst, kept: [.view, .sort])
        #expect(first.without(.view)?.kept == [.sort])
        #expect(first.without(.view)?.without(.sort) == nil)
        #expect(first.without(.groupBy) == first)
        // Not using the folder's view is one choice: any change by hand brings the folder's view back whole.
        #expect(TabViewOverride(folder: "/u", choice: .notUsed, kept: [.view]).without(.sort) == nil)
    }
}
