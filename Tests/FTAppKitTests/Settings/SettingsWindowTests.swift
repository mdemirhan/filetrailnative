// Ports apps/desktop/src/renderer/SettingsWindowApp.test.tsx and SettingsView.test.tsx on the Settings window, built and
// never shown; openSettingsWindow (main.ts) through PageWindows; main.test.tsx's opaque Settings window
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SettingsWindowTests {
    typealias Kit = SettingsTestKit

    // MARK: The window

    // T-d914b204 F-633 F-887 B-DLG-162 B-DLG-234
    @Test func isAWindowOf720By540ThatIsOpaqueAndNotFullScreenable() throws {
        let (controller, _) = Kit.make()
        let window = try #require(controller.window)
        #expect(window.title == "Settings")
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 540))
        #expect(window.contentMinSize == NSSize(width: 680, height: 420))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(controller.spec.trafficLights == NSPoint(x: 14, y: 16))
        // The page window's background stands behind the page, so the window is never see-through.
        #expect(window.isOpaque)
        #expect(window.backgroundColor == NSColor(controller.model.theme.pageWindowBackground))
    }

    // T-39107d68 T-4abe070b F-633 F-887 F-888 F-889 B-DLG-163 B-DLG-229
    @Test func namesTheSectionOnScreenAboveItWithTheShortcutsSearchBesideTheName() throws {
        let (controller, _) = Kit.make()
        let view = controller.settingsView
        #expect(view.sectionTitles == ["General", "Browsing", "Search", "Files", "Shortcuts"])
        #expect(texts("settings.title", in: view) == ["General"])
        #expect(views("settings.shortcuts.search", in: view).isEmpty)
        var told: [SettingsTab] = []
        controller.onTabChange = { told.append($0) }
        Kit.click(view.items[4])
        Kit.layout(controller)
        #expect(texts("settings.title", in: view) == ["Shortcuts"])
        #expect(told == [.shortcuts])
        let field = try #require(views("settings.shortcuts.search", in: view).first)
        #expect(field.isDescendant(of: view.header))
        #expect(field.frame.width == 200)
        #expect(view.items.map(\.isCurrent) == [false, false, false, false, true])
        // Sidebar 196 wide: items 10 in, 52 down, 30 tall and 2 apart; the header is 52 tall.
        #expect(view.sidebar.frame.width == 196)
        #expect(view.items[0].frame == NSRect(x: 10, y: 52, width: 175, height: 30))
        #expect(view.items[1].frame.minY == 84)
        #expect(view.header.frame.height == 52)
    }

    // T-71bef353 T-4abe070b F-633 B-DLG-164
    @Test func opensOnTheTabAskedForOrTheOneItWasLeftOn() throws {
        let (pages, _) = PageWindowsTests.make()
        pages.settingsServices.schedule = { _, _ in {} }
        pages.openSettings(tab: .files)
        let first = try #require(pages.settingsWindow)
        #expect(first.activeTab == .files)
        // Asking again shows the open one, switched to the tab asked for.
        pages.openSettings(tab: .search)
        #expect(pages.settingsWindow === first)
        #expect(first.activeTab == .search)
        pages.openSettings()
        #expect(first.activeTab == .search)
        first.settingsView.select(tab: .browsing)
        #expect(pages.lastSettingsTab == .browsing)
        first.close()
        #expect(pages.settingsWindow == nil)
        // It opens again where it was left, for this session.
        pages.openSettings()
        #expect(pages.settingsWindow?.activeTab == .browsing)
        pages.settingsWindow?.close()
        // Help's Customize… opens Settings on Shortcuts.
        pages.openSettingsOnShortcuts()
        #expect(pages.settingsWindow?.activeTab == .shortcuts)
        pages.settingsWindow?.close()
    }

    // T-4f43cba4 T-7e5d1158 F-891 F-886 B-DLG-167 B-DLG-168 B-DLG-203
    @Test func escapeClosesAnOpenPopUpBeforeTheWindow() throws {
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: "/Users/demo")
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences)
        let window = try #require(controller.window as? PageWindow)
        #expect(window.closesOnEscape)
        let button = try #require(
            views("settings.favoriteIcon", in: controller.settingsView).first as? FavoriteIconButton)
        Kit.click(button)
        #expect(controller.popovers.isOpen)
        let escape = Kit.key(Kit.escape.0, code: Kit.escape.1, window: window)
        // The grid takes Escape: only it closes, and its button has the keyboard again.
        #expect(controller.handle(escape))
        #expect(!controller.popovers.isOpen)
        #expect(window.firstResponder === button)
        // A second Escape goes on to the window, which closes.
        #expect(!controller.handle(escape))
    }

    // F-891 B-DLG-165
    @Test func showsOnlyTheSidebarAndANoticeWhenThePreferencesDontLoad() throws {
        let (controller, _) = Kit.make(loads: false)
        let view = controller.settingsView
        #expect(view.page == nil)
        #expect(texts("settings.section", in: view).count == 5)
        let notice = try #require(view.noticeText)
        #expect(notice.stringValue == "Couldn’t load the settings.")
        Kit.click(view.noticeButton)
        #expect(view.notice == nil)
    }

    // F-889 B-DLG-166
    @Test func drawsTheLineUnderTheTitleOnlyOnceThePageHasScrolled() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        let view = controller.settingsView
        #expect(!view.headerShowsLine)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        #expect(view.headerShowsLine)
        view.select(tab: .general)
        #expect(!view.headerShowsLine)
    }

    // F-889 F-890: the page is at most 560 wide, 20 in from the sidebar and 4 under the header; groups are cards
    // T-f1f09224
    @Test func laysThePageOutAsTheStylesheetDoes() throws {
        let (controller, _) = Kit.make()
        let page = try Kit.page(controller)
        // 720 - 196 = 524 for the pane; the scroll bar's 8, then 20 and 12 of padding: 484.
        #expect(page.frame == NSRect(x: 20, y: 4, width: 484, height: page.frame.height))
        let groups = views("settings.group", in: page).compactMap { $0 as? SettingsSectionView }
        #expect(groups.map { $0.titleText?.stringValue } == ["Appearance", "Behavior"])
        let behavior = try #require(groups.last)
        // A title row of 22, then the card; rows at least 40, 12 in from its sides.
        #expect(behavior.card.frame.minY == 22)
        let rows = behavior.card.rows.compactMap { $0 as? SettingsRowView }
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.frame.height >= 40 && $0.frame.minX == 12 })
        // No line under the last row of a group, whichever row that is (T-f1f09224).
        #expect(rows.map(\.drawsSeparator) == [true, true, true, false])
    }

    // MARK: General

    // T-81e624d1 T-e24d31cb T-515dbe35 T-495a7b2e T-08189372 F-892 F-893 F-895 B-DLG-175 B-DLG-197
    @Test func offersAutoLightAndDarkOneAccentAndNothingElseToStyle() throws {
        let (controller, recorder) = Kit.make()
        let view = controller.settingsView
        let options = views("settings.appearance", in: view).compactMap { $0 as? AppearanceOption }
        #expect(options.map(\.title) == ["Auto", "Light", "Dark"])
        #expect(options.map(\.isSelected) == [false, true, false])
        let titles = views("settings.row.title", in: view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(
            titles == [
                "Theme", "Accent color", "Reopen the last folder and tabs", "Show notifications",
                "Mark copied and cut items", "Calculate folder sizes automatically",
            ])
        // No palette, font, tab style, toolbar, rail, pointer highlight or text colour.
        for word in ["Palette", "Font", "Tab", "Toolbar", "Rail", "pointer", "Text color", "Zoom"] {
            #expect(!titles.contains { $0.contains(word) }, "\(word)")
        }
        Kit.click(options[2])
        Kit.flush(controller)
        #expect(recorder.saved["theme"] == .string("dark"))
        #expect(options.map(\.isSelected) == [false, false, true])
        // The thumbnail is 56 by 36 in a ring of 2.
        #expect(options[0].frame.size.width == 60)
    }

    // T-e4637185 T-cacbdcd8 F-893 B-DLG-176 B-DLG-235 B-DLG-236
    @Test func offersTheAccentsAndACustomColorForAnyOther() throws {
        let preferences = AppPreferences.defaults(theme: .light).with { $0.accent = "#a550a7" }
        let (controller, recorder) = Kit.make(preferences: preferences)
        let swatches = views("settings.accent", in: controller.settingsView).compactMap { $0 as? AccentSwatch }
        #expect(
            swatches.map { $0.accessibilityLabel() ?? "" } == [
                "Accent color Blue", "Accent color Purple", "Accent color Pink", "Accent color Red",
                "Accent color Orange", "Accent color Yellow", "Accent color Green", "Accent color Graphite",
                "Accent color Copper", "Accent color Custom",
            ])
        #expect(swatches.filter(\.isSelected).map(\.toolTip) == ["Purple"])
        #expect(swatches.last?.toolTip == "Custom Color")
        // 15 across, 7 apart.
        #expect(swatches[1].frame.minX - swatches[0].frame.minX == 22)
        Kit.click(swatches[6])
        Kit.flush(controller)
        #expect(recorder.saved["accent"] == .string("#62ba46"))

        // A color that is no preset: the custom swatch is pressed and shows it.
        recorder.pickedColor = "#123ABC"
        Kit.click(swatches.last)
        Kit.flush(controller)
        #expect(recorder.saved["accent"] == .string("#123abc"))
        #expect(swatches.last?.isSelected == true)
        #expect(swatches.last?.customFill == RGBA(hex: "#123abc"))
        // A value that is not #rrggbb is ignored.
        recorder.pickedColor = "red"
        Kit.click(swatches.last)
        Kit.flush(controller)
        #expect(recorder.saved["accent"] == .string("#123abc"))
    }

    // T-914587da T-10d689b4 F-894 B-DLG-178 D-005: Restore Defaults puts back the theme and the accent only
    @Test func restoresTheDefaultAppearanceWithThePushButton() throws {
        let preferences = AppPreferences.defaults(theme: .dark).with {
            $0.accent = "#e0383e"
            $0.markClipboardItems = false
        }
        let (controller, recorder) = Kit.make(preferences: preferences)
        let restore = try #require(
            Kit.button("Restore the default appearance", in: controller.settingsView) as? SystemButton)
        #expect(restore.title == "Restore Defaults")
        Kit.click(restore)
        Kit.flush(controller)
        #expect(recorder.patches == [["theme": .string("auto"), "accent": .string("#007aff")]])
    }

    // T-40aa4b53 T-e054b024 T-9cccb915 T-9b1e3197 F-895 B-DLG-179
    // B-INFO-173
    @Test func changesTheBehaviorWithOneSwitchEach() throws {
        let (controller, recorder) = Kit.make()
        let switches = views("settings.switch", in: controller.settingsView).compactMap { $0 as? SettingsSwitch }
        #expect(
            switches.map { $0.accessibilityLabel() ?? "" } == [
                "Reopen the last folder and tabs", "Show notifications", "Mark copied and cut items",
                "Calculate folder sizes automatically",
            ])
        #expect(switches.allSatisfy { $0.isOn })
        #expect(switches.allSatisfy { $0.frame.size == SettingsMetrics.switchSize })
        for control in switches { Kit.click(control) }
        Kit.flush(controller)
        #expect(
            recorder.patches == [
                [
                    "restoreSessionOnStartup": .bool(false), "notificationsEnabled": .bool(false),
                    "markClipboardItems": .bool(false), "autoCalculateFolderSizes": .bool(false),
                ]
            ])
        // No duration to set for notifications.
        let notifications = try Kit.row("Show notifications", in: controller)
        #expect(notifications.descriptionText?.stringValue == "When a copy, a move or the Trash finishes.")
    }

    // MARK: Saving

    // F-891 B-DLG-169 B-DLG-170 B-DLG-171 B-DLG-173
    @Test func savesEditsAndShowsTheOnesMadeElsewhere() throws {
        let (controller, recorder) = Kit.make()
        Kit.flush(controller)
        // Loading is not written back.
        #expect(recorder.patches.isEmpty)
        let switches = views("settings.switch", in: controller.settingsView).compactMap { $0 as? SettingsSwitch }
        // A refused write is sent again with the next change.
        recorder.refuseWrites = true
        Kit.click(switches[1])
        Kit.flush(controller)
        recorder.refuseWrites = false
        Kit.click(switches[2])
        Kit.flush(controller)
        #expect(recorder.patches.last == ["notificationsEnabled": .bool(false), "markClipboardItems": .bool(false)])
        // Another window's change is shown and not written back; its window keys are ignored.
        controller.preferencesChanged(
            PreferencesChange(
                patch: ["autoCalculateFolderSizes": .bool(false), "viewMode": .string("list")], senderID: 3))
        Kit.flush(controller)
        #expect(!switches[3].isOn)
        #expect(recorder.patches.count == 2)
        // The window's own change, told back to it, changes nothing.
        controller.preferencesChanged(PreferencesChange(patch: ["markClipboardItems": .bool(false)], senderID: nil))
        #expect(!switches[2].isOn)
    }

    // MARK: Browsing

    // T-5c2e2b1c T-b7c4ec80 F-072 F-896 B-DLG-181 B-DLG-182
    @Test func setsEveryViewsDensityAtOnceAndShowsAMixAsCustom() throws {
        let mixed = AppPreferences.defaults(theme: .light).with { $0.compactIconView = true }
        let (controller, recorder) = Kit.make(tab: .browsing, preferences: mixed)
        let density = try Kit.control("Density", SettingsPopup.self, in: controller)
        #expect(density.title == "Custom")
        #expect(density.options.map(\.title) == ["Comfortable", "Compact", "Custom"])
        #expect(density.options.map(\.enabled) == [true, true, false])
        // Custom can't be chosen.
        density.choose("custom")
        density.choose("compact")
        Kit.flush(controller)
        #expect(
            recorder.saved == [
                "compactListView": .bool(true), "compactDetailsView": .bool(true), "compactTreeView": .bool(true),
            ])
        #expect(density.title == "Compact")
        #expect(density.options.map(\.title) == ["Comfortable", "Compact"])
        let single = try Kit.control("Expand folders with a single click", SettingsSwitch.self, in: controller)
        Kit.click(single)
        Kit.flush(controller)
        #expect(recorder.saved["singleClickExpandTreeItems"] == .bool(true))
        // A pop-up is as wide as its longest choice, and at least 120.
        #expect(density.frame.width >= 120)
        #expect(density.frame.height == 24)
    }

    // T-b272528a T-8098e331 F-898 B-DLG-184
    @Test func listsFavoritesInTheFolderTreeFirst() throws {
        let (controller, recorder) = Kit.make(tab: .browsing)
        let placement = try Kit.control("Show favorites", SettingsPopup.self, in: controller)
        #expect(placement.options.map(\.title) == ["In the folder tree", "In their own section"])
        #expect(placement.title == "In the folder tree")
        placement.choose("separate")
        Kit.flush(controller)
        #expect(recorder.saved == ["favoritesPlacement": .string("separate")])
    }

    // T-78748d9f T-357ae792 T-74a645ae T-6a7e76c6 F-886 F-898 B-DLG-198 B-DLG-199 B-DLG-201 B-DLG-202 B-DLG-203
    // B-TREE-045
    @Test func editsTheFavoritesWithTheListItsBarAndTheIconGrid() async throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: home)
        }
        let (controller, recorder) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let list = try Kit.list("Favorites", in: controller)
        let start = Kit.names(list)
        #expect(start == ["Applications", "Desktop", "Documents", "Downloads"])
        #expect(list.rows[1].spec.path == "\(home)/Desktop")
        let icons = views("settings.favoriteIcon", in: controller.settingsView).compactMap { $0 as? FavoriteIconButton }
        #expect(icons.count == start.count)
        #expect(icons.first?.accessibilityLabel() == "Favorite icon for Applications")

        // The icon grid: 6 columns of 30, 4 apart, 6 of padding, the icon chosen filled; a choice applies and closes.
        Kit.click(icons[1])
        let grid = try #require(controller.popovers.view as? FavoriteIconGrid)
        #expect(grid.cells.count == FavoriteIconID.allCases.count)
        // The icons not chosen keep the neutral color.
        #expect(grid.frame.size == NSSize(width: 212, height: 144))
        #expect(grid.cells[0].frame.origin == NSPoint(x: 6, y: 6))
        #expect(grid.cells[1].frame.minX - grid.cells[0].frame.minX == 34)
        #expect(grid.cells.filter { !$0.isSelected }.allSatisfy { $0.iconColor == $0.theme.palette.iconNeutral })
        #expect(grid.cells.filter(\.isSelected).map(\.icon) == [icons[1].icon])
        let star = try #require(grid.cells.first { $0.icon == .star })
        #expect(star.accessibilityLabel() == "Favorite icon for \(start[1]): Star")
        Kit.click(star)
        #expect(!controller.popovers.isOpen)
        Kit.flush(controller)
        let saved = try #require(recorder.saved["favorites"]?.array)
        #expect(saved[1]["icon"] == .string("star"))
        // The click on the icon selected no row.
        #expect(list.selectedIndex == nil)

        // The list takes the keyboard on its first row; ↓ selects the next, ⌥↓ moves the row and keeps it selected,
        // Return changes it, ⌫ removes it.
        controller.window?.makeFirstResponder(list)
        #expect(list.selectedIndex == 0)
        list.keyDown(with: Kit.key(Kit.down.0, code: Kit.down.1, window: controller.window))
        #expect(list.selectedIndex == 1)
        list.keyDown(with: Kit.key(Kit.up.0, code: Kit.up.1, window: controller.window))
        list.keyDown(with: Kit.key(Kit.down.0, code: Kit.down.1, modifiers: .option, window: controller.window))
        #expect(list.selectedIndex == 1)
        #expect(Kit.names(list).prefix(2) == [start[1], start[0]])
        recorder.pickedDirectory = "/Users/demo/Projects"
        list.keyDown(with: Kit.key(Kit.returnKey.0, code: Kit.returnKey.1, window: controller.window))
        await Kit.settle()
        #expect(recorder.directoryRequests.last == "/Applications")
        #expect(list.rows[1].spec.path == "/Users/demo/Projects")
        list.keyDown(with: Kit.key(Kit.backspace.0, code: Kit.backspace.1, window: controller.window))
        #expect(!Kit.names(list).contains("Projects"))
        #expect(list.selectedIndex == 1)

        // + adds a folder once; a cancelled picker adds nothing.
        recorder.pickedDirectory = "/Users/demo/Music"
        let count = list.rows.count
        Kit.click(Kit.button("Add Favorite", in: controller.settingsView))
        await Kit.settle()
        #expect(list.rows.count == count + 1)
        Kit.click(Kit.button("Add Favorite", in: controller.settingsView))
        await Kit.settle()
        #expect(list.rows.count == count + 1)
        recorder.pickedDirectory = nil
        Kit.click(Kit.button("Add Favorite", in: controller.settingsView))
        await Kit.settle()
        #expect(list.rows.count == count + 1)
        #expect(recorder.directoryRequests.last == home)
        // The new favorite's icon is inferred from its path.
        Kit.flush(controller)
        #expect(recorder.saved["favorites"]?.array?.last?["icon"] == .string("music"))
        // Restore Defaults puts back the home folder's favorites.
        Kit.click(Kit.button("Restore the default favorites", in: controller.settingsView))
        #expect(Kit.names(list) == start)
    }

    // T-5cefcb66 F-898 B-DLG-202
    @Test func letsATrashFavoriteBeRemoved() throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = [FavoritePreference(path: "\(home)/.Trash", icon: .trash)]
        }
        let (controller, recorder) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let list = try Kit.list("Favorites", in: controller)
        #expect(Kit.names(list) == ["Trash"])
        list.select(0)
        let remove = try #require(Kit.button("Remove Trash", in: controller.settingsView) as? SettingsControlView)
        #expect(remove.isEnabled)
        Kit.click(remove)
        Kit.flush(controller)
        #expect(recorder.saved["favorites"] == .array([]))
        #expect(
            Kit.button("Remove", in: controller.settingsView).map { ($0 as? SettingsControlView)?.isEnabled } == false)
    }

    // F-898 B-DLG-195: a picker that fails says so; a cancelled one changes nothing
    @Test func saysWhenAPickerCouldNotBeShown() async throws {
        let (controller, recorder) = Kit.make(tab: .browsing)
        recorder.pickerFails = true
        Kit.click(Kit.button("Add Favorite", in: controller.settingsView))
        await Kit.settle()
        #expect(controller.settingsView.noticeText?.stringValue == "Couldn’t choose a folder.")
        controller.settingsView.select(tab: .files)
        Kit.click(Kit.button("Add app to Open With", in: controller.settingsView))
        await Kit.settle()
        #expect(controller.settingsView.noticeText?.stringValue == "Couldn’t choose an app.")
    }

    // T-89b64fc1 T-d3457b5a T-113ec9a4 T-608dd674 F-897 B-DLG-205 B-DLG-206 B-DLG-207
    // B-DLG-183 B-DLG-200
    @Test func listsTheColumnsInTheirOrderWithNameFirstAndFixed() throws {
        let (controller, recorder) = Kit.make(tab: .browsing)
        let list = try Kit.list("Columns in List view", in: controller)
        #expect(Kit.names(list) == ["Date Modified", "Size", "Kind", "Date Created", "Permissions"])
        let fixed = views("settings.list.row", in: list).compactMap { $0 as? SettingsListRow }.first
        #expect(fixed?.spec.name == "Name")
        #expect(fixed?.spec.trailingNote == "Always first")
        #expect(fixed?.frame.height == 30)
        let checks = list.rows.compactMap { $0.spec.leading as? SettingsCheckbox }
        #expect(checks.map(\.isChecked) == [true, true, true, false, false])
        #expect(checks[3].accessibilityLabel() == "Show Date Created")
        // Checked with its checkbox, or with Space.
        Kit.click(checks[3])
        controller.window?.makeFirstResponder(list)
        list.select(4)
        list.keyDown(with: Kit.key(Kit.space.0, code: Kit.space.1, window: controller.window))
        Kit.flush(controller)
        #expect(recorder.saved["detailColumns"]?["created"] == .bool(true))
        #expect(recorder.saved["detailColumns"]?["permissions"] == .bool(true))
        // Moved with the arrow buttons, the keyboard, or a drag.
        let restore = try #require(Kit.button("Restore the default column order", in: list) as? SettingsControlView)
        #expect(!restore.isEnabled)
        let down = try #require(Kit.button("Move Permissions Down", in: list) as? SettingsControlView)
        #expect(!down.isEnabled)
        list.select(0)
        Kit.click(Kit.button("Move Date Modified Down", in: list))
        #expect(Kit.names(list).prefix(2) == ["Size", "Date Modified"])
        list.keyDown(with: Kit.key(Kit.up.0, code: Kit.up.1, modifiers: .command, window: controller.window))
        #expect(Kit.names(list).prefix(2) == ["Date Modified", "Size"])
        list.drop(4, on: 0)
        #expect(Kit.names(list).first == "Permissions")
        // Restore Defaults puts back the order and leaves the checked columns alone.
        #expect(restore.isEnabled)
        Kit.click(restore)
        Kit.flush(controller)
        #expect(Kit.names(list) == ["Date Modified", "Size", "Kind", "Date Created", "Permissions"])
        #expect(recorder.saved["detailColumns"]?["created"] == .bool(true))
    }

    // MARK: Search

    // T-9220003b F-899 B-DLG-185 B-DLG-187 B-DLG-208
    @Test func listsSearchResultsColumnsOnTheSearchTabApartFromAFolders() throws {
        let (controller, recorder) = Kit.make(tab: .search)
        let titles = views("settings.row.title", in: controller.settingsView).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        #expect(
            titles == [
                "Search in", "Match as", "Search subfolders", "Skip .git folders", "Skip files ignored by Git",
            ])
        let match = try Kit.control("Match as", SettingsPopup.self, in: controller)
        #expect(match.options.map(\.title) == ["Plain Text", "Glob", "Regex"])
        let scope = try Kit.control("Search in", SettingsPopup.self, in: controller)
        #expect(scope.options.map(\.title) == ["Names", "Full Paths"])
        scope.choose("path")
        let ignored = try Kit.control("Skip files ignored by Git", SettingsSwitch.self, in: controller)
        Kit.click(ignored)
        Kit.flush(controller)
        #expect(recorder.saved == ["searchMatchScope": .string("path"), "searchSkipGitIgnored": .bool(true)])
        let list = try Kit.list("Columns in search results", in: controller)
        #expect(Kit.names(list) == ["Folder", "Date Modified", "Size", "Kind", "Date Created", "Permissions"])
        #expect(
            list.rows.compactMap { ($0.spec.leading as? SettingsCheckbox)?.isChecked } == [
                true, true, true, false, false, false,
            ])
        #expect(Kit.lists(in: controller).count == 1)
    }

    // MARK: Files

    // T-cb0050b5 T-60a2dfc5 F-900 B-DLG-188 B-DLG-189 B-DLG-190 B-DLG-191
    @Test func rendersAndUpdatesFileOpeningPreferences() throws {
        let (controller, recorder) = Kit.make(tab: .files)
        let titles = views("settings.row.title", in: controller.settingsView).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        #expect(
            titles == [
                "Double-click a file to", "Return key", "Open disk images in", "Ask before opening more than",
                "Text editor", "Terminal",
            ])
        let returnRow = try Kit.row("Return key", in: controller)
        #expect(returnRow.descriptionText?.stringValue == "⌘O and ⌘↓ always open.")
        try Kit.control("Double-click a file to", SettingsPopup.self, in: controller).choose("edit")
        try Kit.control("Return key", SettingsPopup.self, in: controller).choose("open")
        try Kit.control("Open disk images in", SettingsPopup.self, in: controller).choose("tab")
        let limit = try Kit.control("Ask before opening more than", SettingsNumberField.self, in: controller)
        #expect(limit.field.stringValue == "5")
        // Not whole digits: the default; else brought into 1 to 50.
        limit.field.stringValue = "80"
        limit.commit()
        #expect(limit.field.stringValue == "50")
        limit.field.stringValue = "2.5"
        limit.commit()
        #expect(limit.field.stringValue == "5")
        limit.field.stringValue = " 12 "
        limit.commit()
        Kit.flush(controller)
        #expect(
            recorder.saved == [
                "fileActivationAction": .string("edit"), "returnKeyAction": .string("open"),
                "diskImageOpensIn": .string("tab"), "openItemLimit": .number(12),
            ])
    }

    // T-7f2056be F-901 B-DLG-193
    @Test func choosesTheTerminalAppFromItsPopUpOrGoesBackToTheDefault() async throws {
        let (controller, recorder) = Kit.make(tab: .files)
        let terminal = try Kit.control("Terminal", SettingsAppPopup.self, in: controller)
        #expect(terminal.application.appName == "Terminal")
        Kit.click(terminal)
        var menu = try #require(controller.popovers.menus.menu)
        #expect(menu.rows.map(\.title) == ["Terminal", "Choose…"])
        #expect(menu.rows.map(\.checked) == [true, nil])
        #expect(menu.nsMenu.items[1].isSeparatorItem)
        #expect(menu.nsMenu.minimumWidth == terminal.frame.width)
        #expect(terminal.isExpanded())
        recorder.pickedApplication = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")
        menu.onChoose(2)
        await Kit.settle()
        #expect(terminal.application.appName == "iTerm")
        Kit.flush(controller)
        #expect(recorder.saved["terminalApp"]?["appName"] == .string("iTerm"))
        Kit.click(terminal)
        menu = try #require(controller.popovers.menus.menu)
        #expect(menu.rows.map(\.title) == ["iTerm", "Terminal", "Choose…"])
        // Choosing the default clears the custom app.
        menu.onChoose(1)
        #expect(!controller.popovers.menus.isOpen)
        Kit.flush(controller)
        #expect(recorder.saved["terminalApp"] == .null)
        #expect(terminal.application.appName == "Terminal")
        // A cancelled picker changes nothing.
        recorder.pickedApplication = nil
        let editor = try Kit.control("Text editor", SettingsAppPopup.self, in: controller)
        Kit.click(editor)
        controller.popovers.menus.menu?.onChoose(2)
        await Kit.settle()
        #expect(editor.application.appName == "TextEdit")
    }

    // T-5d780e3c T-2b0f3eff T-43a5730e F-901 B-DLG-194 B-DLG-201 B-DLG-204
    @Test func editsTheAppsAlwaysInOpenWithByTheirIDs() async throws {
        let apps = [
            OpenWithApplication(id: "a", appPath: "/Applications/Zed.app", appName: "Zed"),
            OpenWithApplication(id: "b", appPath: "/Applications/Gone.app", appName: "Gone"),
        ]
        let preferences = AppPreferences.defaults(theme: .light).with { $0.openWithApplications = apps }
        let recorderMissing: Set<String> = ["/Applications/Gone.app"]
        let (controller, recorder) = Kit.make(tab: .files, preferences: preferences)
        recorder.missing = recorderMissing
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        await Kit.settle()
        Kit.layout(controller)
        let list = try Kit.list("Always in Open With", in: controller)
        #expect(Kit.names(list) == ["Zed", "Gone"])
        #expect(list.rows.map(\.spec.missing) == [false, true])
        #expect(list.rows[1].pathText.stringValue == "Not found · /Applications/Gone.app")
        list.select(1)
        list.move(1, to: 0)
        Kit.flush(controller)
        #expect(recorder.saved["openWithApplications"]?.array?.map { $0["id"] } == [.string("b"), .string("a")])
        recorder.pickedApplication = ApplicationSelection(appPath: "/Applications/Nova.app", appName: "Nova")
        Kit.click(Kit.button("Change Gone", in: controller.settingsView))
        await Kit.settle()
        #expect(Kit.names(list) == ["Nova", "Zed"])
        Kit.click(Kit.button("Add app to Open With", in: controller.settingsView))
        await Kit.settle()
        #expect(Kit.names(list) == ["Nova", "Zed", "Nova"])
        Kit.flush(controller)
        let ids = recorder.saved["openWithApplications"]?.array?.compactMap { $0["id"]?.string } ?? []
        #expect(ids.count == 3 && Set(ids).count == 3 && ids[2].hasPrefix("open-with-"))
        list.select(0)
        Kit.click(Kit.button("Remove Nova", in: controller.settingsView))
        #expect(Kit.names(list) == ["Zed", "Nova"])
    }

    // F-900 F-901: the press on a favorite's icon scrolls the page before the release (260): the release still lands on
    // the button it pressed, and the grid opens under where the button went.
    @Test func aPressThatScrollsThePageStillOpensTheIconGrid() throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: home)
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 720, height: 300))
        window.contentView?.layoutSubtreeIfNeeded()
        controller.settingsView.layoutSubtreeIfNeeded()
        let icons = views("settings.favoriteIcon", in: controller.settingsView).compactMap { $0 as? FavoriteIconButton }
        let button = try #require(icons.first)
        let clip = try #require(button.enclosingScrollView?.contentView)
        #expect(clip.bounds.minY == 0)
        let location = button.convert(NSPoint(x: 13, y: 13), to: nil)
        button.beginPress(at: location)
        // The page moved under the pointer, and the press stayed the button's.
        #expect(clip.bounds.minY > 0)
        #expect(!button.bounds.contains(button.convert(location, from: nil)))
        button.release(at: location)
        #expect(controller.popovers.view is FavoriteIconGrid)
        controller.popovers.close(returnFocus: false)
        // A release that really left the button is no click.
        button.beginPress(at: button.convert(NSPoint(x: 13, y: 13), to: nil))
        button.release(at: button.convert(NSPoint(x: 13, y: 200), to: nil))
        #expect(!controller.popovers.isOpen)
    }

    // F-900: `.settings-row` keeps its border in its height (a row of a pop-up is 41, the last 40), and the checkbox of
    // the column that is always on is dimmed (263).
    @Test func rowsCountTheirLineAndTheFixedColumnsCheckboxIsDimmed() throws {
        let (controller, _) = Kit.make(tab: .files)
        let rows = views("settings.row", in: controller.settingsView).compactMap { $0 as? SettingsRowView }
        let editor = try #require(rows.first { $0.titleText.stringValue == "Text editor" })
        #expect(editor.frame.height == 41)
        #expect(editor.control.frame.minY == 8)
        #expect(editor.titleText.frame.minY == 12.5)
        let terminal = try #require(rows.first { $0.titleText.stringValue == "Terminal" })
        #expect(terminal.frame.height == 40)

        let (browsing, _) = Kit.make(tab: .browsing)
        let boxes = views("settings.checkbox", in: browsing.settingsView).compactMap { $0 as? SettingsCheckbox }
        let fixed = try #require(boxes.first { !$0.isEnabled })
        #expect(fixed.alphaValue == CGFloat(DesignTokens.disabledOpacity))
        #expect(boxes.filter(\.isEnabled).count > 1)
    }

    // F-900 F-901: the app menu's labels, a list's names and a trailing note start and end where the text box does: a
    // `FlushTextField` draws from its frame's edge.
    @Test func settingsTextStartsAtItsBoxesEdge() throws {
        let (controller, _) = Kit.make(tab: .browsing)
        let names = views("settings.list.name", in: controller.settingsView).compactMap { $0 as? FlushTextField }
        let name = try #require(names.first)
        let row = try #require(name.superview as? SettingsListRow)
        #expect(name.frame.minX > row.spec.leading.map { $0.frame.maxX } ?? 0)
        if let leading = row.spec.leading {
            #expect(name.frame.minX == leading.frame.maxX + SettingsMetrics.listRowGap)
        }
    }

    // F-900 F-901 B-DLG-191 B-DLG-209: the Files tab as the checkpoint drew it (262-settings-files-app-popup)
    @Test func laysTheFilesTabOutAsTheOriginalWithItsAppMenuFoundRowByRow() throws {
        let (controller, _) = Kit.make(tab: .files)
        // The number sits right-aligned before the room Chromium keeps for a number input's stepper: 48 less 8 of
        // padding on each side and 15.
        let limit = try Kit.control("Ask before opening more than", SettingsNumberField.self, in: controller)
        limit.layoutSubtreeIfNeeded()
        #expect(limit.field.alignment == .right)
        // The field's cell keeps 2 from each side of its frame, which reaches 2 past the text box.
        #expect(limit.field.frame.minX == 6 && limit.field.frame.maxX == 27)
        // An empty Always in Open With is its bar at the top of a row that keeps the 40 every row has; the note
        // comes 6 under that.
        let groups = views("settings.group", in: controller.settingsView).compactMap { $0 as? SettingsSectionView }
        let openWith = try #require(groups.first { $0.titleText?.stringValue == "Always in Open With" })
        let list = try Kit.list("Always in Open With", in: controller)
        #expect(list.rows.isEmpty)
        #expect(list.frame == NSRect(x: 0, y: 0, width: openWith.card.frame.width, height: 28))
        #expect(openWith.card.frame.height == 40)
        // The bar's buttons are centred under its top line.
        #expect(list.barButtons.allSatisfy { $0.frame.minY == 4.5 && $0.frame.height == 20 })
        // The app menu's rows, the checked one first, with the app's icon.
        Kit.click(try Kit.control("Text editor", SettingsAppPopup.self, in: controller))
        let menu = try #require(controller.popovers.menus.menu)
        #expect(menu.identifier == "toolbarMenu" && menu.rowIdentifier == "toolbarMenu.item")
        #expect(menu.rows.map(\.title) == ["TextEdit", "Choose…"])
        #expect(menu.rows.filter { $0.checked == true }.map(\.title) == ["TextEdit"])
        #expect(menu.nsMenu.items[0].image != nil && menu.nsMenu.items[2].image == nil)
    }

    // F-898 B-DLG-198 B-DLG-203: a press on a favorite's icon focuses the button in the row, so the row is selected
    // and the list shows the accent, as the original's row does when a control in it takes the focus
    @Test func aPressOnAFavoritesIconSelectsItsRowWithTheAccent() async throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: home)
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let list = try Kit.list("Favorites", in: controller)
        let icons = list.rows.compactMap { $0.spec.leading as? FavoriteIconButton }
        #expect(list.selectedIndex == nil)
        icons[0].focusForPress()
        Kit.click(icons[0])
        #expect(controller.window?.firstResponder === icons[0])
        #expect(list.selectedIndex == 0)
        #expect(list.rows[0].showsAccent)
        #expect(icons[0].onSelection)
        #expect(controller.popovers.view is FavoriteIconGrid)
        // Escape closes the grid and leaves the keyboard on the button: the row keeps the accent.
        #expect(controller.handle(Kit.key(Kit.escape.0, code: Kit.escape.1, window: controller.window)))
        #expect(!controller.popovers.isOpen)
        await Kit.settle()
        #expect(list.rows[0].showsAccent)
        // The keyboard reaching another icon selects that row; leaving the list keeps the selection, without accent.
        controller.window?.makeFirstResponder(icons[2])
        await Kit.settle()
        #expect(list.selectedIndex == 2)
        #expect(list.rows[2].showsAccent)
        controller.window?.makeFirstResponder(nil)
        await Kit.settle()
        #expect(list.selectedIndex == 2)
        #expect(!list.rows[2].showsAccent && list.rows[2].isSelected)
    }

    // F-898 B-DLG-203: a press on the icon of a favorite cut by the window's bottom brings its row into view, the
    // page going as far as it can toward centring it, so the grid then hangs under the button
    // (260-settings-browsing-icon-grid: the original's page moves 195 up, to its end).
    // The rows are made anew with the icon chosen: the keyboard stays on the row's new button, so the row keeps the
    // accent and the keys go on working (a16).
    @Test func choosingAFavoritesIconLeavesTheKeyboardOnItsRow() throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: home)
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let list = try Kit.list("Favorites", in: controller)
        let icons = list.rows.compactMap { $0.spec.leading as? FavoriteIconButton }
        icons[1].focusForPress()
        Kit.click(icons[1])
        let grid = try #require(controller.popovers.view as? FavoriteIconGrid)
        Kit.click(try #require(grid.cells.first { $0.icon == .star }))
        Kit.flush(controller)
        let now = try #require(list.rows[1].spec.leading as? FavoriteIconButton)
        #expect(now !== icons[1] && now.icon == .star)
        #expect(controller.window?.firstResponder === now)
        #expect(list.hasFocus)
        #expect(list.selectedIndex == 1)
        #expect(list.rows[1].listFocused)
    }

    @Test func aPressOnACutFavoritesIconScrollsItsRowIntoView() throws {
        let home = "/Users/demo"
        let preferences = AppPreferences.defaults(theme: .light).with {
            $0.favorites = Favorites.defaults(homePath: home)
        }
        let (controller, _) = Kit.make(tab: .browsing, preferences: preferences, homePath: home)
        let list = try Kit.list("Favorites", in: controller)
        let icons = list.rows.compactMap { $0.spec.leading as? FavoriteIconButton }
        let scroll = controller.settingsView.scroll
        let clip = scroll.contentView
        let document = try #require(scroll.documentView)
        let row = list.rows[0]
        #expect(clip.bounds.minY == 0)
        #expect(!clip.bounds.contains(row.convert(row.bounds, to: clip)))
        icons[0].focusForPress()
        Kit.click(icons[0])
        let end = document.frame.height - clip.bounds.height
        #expect(end > 0 && clip.bounds.minY == end)
        #expect(clip.bounds.contains(row.convert(row.bounds, to: clip)))
        #expect(controller.popovers.view is FavoriteIconGrid)
        // A press on an icon whose row is wholly in view leaves the page where it is.
        controller.popovers.close(returnFocus: false)
        clip.scroll(to: NSPoint(x: 0, y: end - 20))
        scroll.reflectScrolledClipView(clip)
        #expect(clip.bounds.contains(list.rows[1].convert(list.rows[1].bounds, to: clip)))
        icons[1].focusForPress()
        #expect(clip.bounds.minY == end - 20)
    }

    // N/A T-f7150cd1 the Settings window has one layout: the single-panel layout modes are Help's (F-664)
    // N/A T-418f2d7d T-0a67899e there is no stylesheet or inline style: the controls draw with ThemePalette tokens,
    // one control height (DesignTokens.controlHeights) and the push button's bezel, checked by the frames above
    // N/A T-c8bd0b66 T-c91ec44b T-a6ffd8db the Zoom row is not drawn (DEVIATIONS D-005)
}

extension AppPreferences {
    /// These preferences with a change.
    func with(_ change: (inout AppPreferences) -> Void) -> AppPreferences {
        var copy = self
        change(&copy)
        return copy
    }
}
