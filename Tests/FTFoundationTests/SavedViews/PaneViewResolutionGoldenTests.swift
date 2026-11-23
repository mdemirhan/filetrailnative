// Checks what a pane shows, and where each setting comes from, against the view-resolution golden: the folder's view
// (its own, from above, stopped, changed on screen) over what the pane carries
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct PaneViewResolutionGoldenTests {
    struct Input: Codable {
        var views: [FolderView]
        var folder: String
        /// The settings changed on screen and not saved: over the folder's view, or a view waiting for Save.
        var unsaved: FolderViewKeeps?
    }

    /// What the pane carries: a value in every setting that no folder view in the golden has.
    static let carried = FolderViewKeeps(
        view: .icons, groupBy: GroupByPreference.none, sort: FolderViewSort(by: .name, direction: .asc),
        foldersFirst: true,
        columns: FolderViewColumns(
            visibility: .defaults, order: OptionalDetailColumnKey.menuOrder, widths: .defaults),
        size: FolderViewSizes(
            iconSizes: .iconDefaults, compactListWidths: .compactListDefaults, previewCounts: .previewCountDefaults))

    /// Each setting as "value · source": the folder's view's value where it decides the setting, else the pane's.
    static func output(onScreen: FolderViewOnScreen?) -> [String: String] {
        var keeps = carried
        var sources: [FolderViewSetting: PaneViewResolution.Source] = [:]
        for setting in FolderViewSetting.allCases {
            sources[setting] = PaneViewResolution.source(of: setting, onScreen: onScreen)
            if let onScreen, PaneViewResolution.folderViewDecides(setting, onScreen: onScreen) {
                keeps.take(setting, from: onScreen.shown)
            }
        }
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
            result[setting.rawValue] = "\(value(setting)) · \(sources[setting]?.rawValue ?? "?")"
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
        return output(onScreen: onScreen)
    }

    @Test func eachSettingShowsTheValueAndSourceTheGoldenGives() throws {
        let cases: [GoldenCase<Input, [String: String]>] = try GoldenChanges.load(suite: "view-resolution")
        #expect(cases.count == 9)
        Golden.expectMatches(cases) { Self.shown($0) }
    }

    // With no folder's view, every setting is the pane's.
    @Test func everySettingHasExactlyOneSource() {
        let shown = Self.output(onScreen: nil)
        #expect(Set(shown.keys) == Set(FolderViewSetting.allCases.map(\.rawValue)))
        #expect(shown.values.allSatisfy { $0.hasSuffix(" · pane") })
    }
}
