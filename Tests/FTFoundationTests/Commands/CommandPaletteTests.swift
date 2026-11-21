import Testing

@testable import FTFoundation

struct CommandPaletteTests {
    static let window = ApplicationMenu.WindowFacts(explorerFocused: true)

    /// What the menu says of each item for `state`, by id.
    static func states(_ state: ApplicationMenuState = .initial) -> [String: ApplicationMenuItemState] {
        Dictionary(uniqueKeysWithValues: ApplicationMenu.itemStates(state, window: window).map { ($0.id, $0) })
    }

    static func entries(
        _ state: ApplicationMenuState = .initial, menuTitles: [String: String] = [:],
        tabViews: [CommandPaletteSavedView] = [], windowViews: [CommandPaletteSavedView] = [],
        templates: [String] = []
    ) -> [CommandPaletteEntry] {
        CommandPalette.entries(
            bindings: ShortcutCommands.defaultBindings, states: states(state), menuTitles: menuTitles,
            tabViews: tabViews, windowViews: windowViews, templates: templates)
    }

    static func entry(_ id: String, in entries: [CommandPaletteEntry] = entries()) -> CommandPaletteEntry? {
        entries.first { $0.id == id }
    }

    static func titles(_ query: String, recent: [String] = [], entries: [CommandPaletteEntry] = entries())
        -> [String]
    {
        CommandPalette.sections(entries, query: query, recent: recent).flatMap(\.rows).map(\.entry.title)
    }

    // MARK: What is listed

    // A command added to the table is in the palette unless it is left out by name, so none is forgotten.
    @Test func listsEveryCommandOfTheTableButTheOnesLeftOut() {
        let listed = Set(Self.entries().map(\.id))
        for definition in ShortcutCommands.all {
            #expect(
                listed.contains(definition.id.rawValue) != CommandPalette.excludedCommands.contains(definition.id),
                "\(definition.id)")
        }
        #expect(Self.entries().count == Set(Self.entries().map(\.id)).count)
    }

    // A command runs as its menu item does; the ones no menu item of the app's has run as keys or as the system's.
    @Test func runsEachCommandTheWayItsMenuItemOrKeyDoes() {
        #expect(Self.entry("copy")?.run == .menuItem("editCopy"))
        #expect(Self.entry("selectAll")?.run == .menuItem("editSelectAll"))
        #expect(Self.entry("settings")?.run == .menuItem("settings"))
        #expect(Self.entry("sortBySize")?.run == .menuItem("sortBySize"))
        #expect(Self.entry("focusTreePane")?.run == .menuItem("focusTreePane"))
        #expect(Self.entry("halfPageDown")?.run == .windowKey(.halfPageDown))
        #expect(Self.entry("openSelectedItem")?.run == .windowKey(.openSelectedItem))
        #expect(Self.entry("quit")?.run == .system(.quit))
        #expect(Self.entry("Zoom")?.run == .system(.zoom))
        #expect(Self.entry("about")?.run == .menuItem("about"))
        // Every menu item a row runs is one the router knows: a window's command, or Settings.
        for entry in Self.entries() {
            guard case .menuItem(let id) = entry.run, entry.group != .standard || id != "about" else { continue }
            let known =
                AppCommand(rawValue: id) != nil || id == "settings" || id == "about"
                || id == ApplicationMenu.manageTabViewsItemID || id == ApplicationMenu.manageWindowViewsItemID
            #expect(known, "\(id)")
        }
    }

    @Test func showsEachCommandWithItsPlaceAndMainKey() {
        let sort = Self.entry("sortByModified")
        #expect(sort?.title == "Sort by Date Modified")
        #expect(sort?.place == "View > Sort By")
        #expect(sort?.keys == [])
        #expect(Self.entry("openLocationSheet")?.keys == ["⌘", "K"])
        #expect(Self.entry("emptyTrash")?.keys == ["⇧", "⌘", "⌫"])
        #expect(Self.entry("halfPageDown")?.place == nil)
        #expect(Self.entry("quit")?.place == "File Trail")
        #expect(Self.entry("copy")?.place == "Edit")
        #expect(Self.entry("halfPageDown")?.keys == ["⌃", "D"])
        // A key changed in Settings is the one shown.
        var bindings = ShortcutCommands.defaultBindings
        bindings[.sortByModified] = ["Ctrl+Cmd+M"]
        let changed = CommandPalette.entries(bindings: bindings, states: Self.states())
        #expect(Self.entry("sortByModified", in: changed)?.keys == ["⌃", "⌘", "M"])
    }

    // The menu's title is shown where it names what the command acts on; elsewhere the table's label, which reads on
    // its own ("View as Icons" rather than the menu's "as Icons").
    @Test func takesTheMenusTitleWhereItNamesWhatTheCommandActsOn() {
        let entries = Self.entries(
            menuTitles: [
                "compressSelection": "Compress \u{201C}Photos\u{201D}", "viewAsIcons": "as Icons",
                "editSelection": "Edit in BBEdit",
            ])
        #expect(Self.entry("compressSelection", in: entries)?.title == "Compress \u{201C}Photos\u{201D}")
        #expect(Self.entry("editSelection", in: entries)?.title == "Edit in BBEdit")
        #expect(Self.entry("viewAsIcons", in: entries)?.title == "View as Icons")
    }

    @Test func dimsAndChecksAsTheMenuDoes() {
        var state = ApplicationMenuState.initial
        state.disabledCommands = [.renameSelection]
        state.hiddenFilesShown = true
        state.sortBy = .size
        let entries = Self.entries(state)
        #expect(Self.entry("renameSelection", in: entries)?.enabled == false)
        #expect(Self.entry("duplicateSelection", in: entries)?.enabled == true)
        #expect(Self.entry("toggleHiddenFiles", in: entries)?.checked == true)
        #expect(Self.entry("sortBySize", in: entries)?.checked == true)
        #expect(Self.entry("sortByName", in: entries)?.checked == false)
    }

    // Every window view by its name, in a new window and in this one, the first five with their keys; "in This Window"
    // has none to begin with.
    @Test func listsEachWindowViewByItsName() {
        let views = (1...6).map { CommandPaletteSavedView(id: "w\($0)", name: "Work \($0)") }
        let entries = Self.entries(windowViews: views)
        let first = Self.entry("windowView:w1", in: entries)
        #expect(first?.title == "Window View \u{201C}Work 1\u{201D}")
        #expect(first?.keys == ["⌃", "⌘", "1"])
        #expect(first?.place == "Layout > Window Views")
        let here = Self.entry("windowViewHere:w1", in: entries)
        #expect(here?.title == "Window View \u{201C}Work 1\u{201D} in This Window")
        #expect(here?.keys == [])
        #expect(Self.entry("windowView:w6", in: entries)?.keys == [])
        #expect(!entries.contains { $0.id == "openWindowView1" || $0.id == "openWindowView1InThisWindow" })
    }

    // Every tab view by its name, the first five with ⌥⌘1 to ⌥⌘5.
    @Test func listsEachTabViewByItsName() {
        let views = (1...6).map { CommandPaletteSavedView(id: "t\($0)", name: "Compare \($0)") }
        let entries = Self.entries(tabViews: views)
        let first = Self.entry("tabView:t1", in: entries)
        #expect(first?.title == "Tab View \u{201C}Compare 1\u{201D}")
        #expect(first?.keys == ["⌥", "⌘", "1"])
        #expect(first?.place == "Layout > Tab Views")
        #expect(Self.entry("tabView:t5", in: entries)?.keys == ["⌥", "⌘", "5"])
        #expect(Self.entry("tabView:t6", in: entries)?.keys == [])
        #expect(!entries.contains { $0.id == "applyTabView1" })
    }

    // Each template of File ▸ New File by its name, on where Text File is.
    @Test func listsEachTemplateByItsName() {
        let entries = Self.entries(templates: ["Letter.txt", "budget.csv"])
        let letter = Self.entry(ApplicationMenu.templateItemID("Letter.txt"), in: entries)
        #expect(letter?.title == "New File \u{201C}Letter.txt\u{201D}")
        #expect(letter?.place == "File > New File")
        #expect(letter?.run == .menuItem("newFileFromTemplate:Letter.txt"))
        #expect(ApplicationMenu.templateItem("newFileFromTemplate:Letter.txt") == "Letter.txt")
        #expect(ApplicationMenu.templateItem("newTextFile") == nil)
        var locked = ApplicationMenuState.initial
        locked.disabledCommands = [.newTextFile]
        let dimmed = Self.entries(locked, templates: ["Letter.txt"])
        #expect(Self.entry(ApplicationMenu.templateItemID("Letter.txt"), in: dimmed)?.enabled == false)
    }

    // MARK: Order

    // With nothing typed: up to five recent commands, then every command under its group, in Settings' order.
    @Test func listsTheRecentCommandsThenEveryGroupWhileNothingIsTyped() {
        let recent = ["copyPath", "gone", "toggleHiddenFiles", "newTab", "goBack", "swapPanes", "quit"]
        let sections = CommandPalette.sections(Self.entries(), query: "  ", recent: recent)
        #expect(sections.map(\.title) == [CommandPalette.recentTitle] + ShortcutGroup.allCases.map(\.label))
        #expect(
            sections[0].rows.map(\.entry.id) == ["copyPath", "toggleHiddenFiles", "newTab", "goBack", "swapPanes"])
        #expect(sections[1].rows.first?.entry.id == "goBack")
        #expect(sections.dropFirst().map(\.rows.count).reduce(0, +) == Self.entries().count)
    }

    @Test func putsTheBestFitFirstAndMarksItsLetters() {
        let rows = CommandPalette.sections(Self.entries(), query: "sort", recent: []).flatMap(\.rows)
        #expect(rows.prefix(4).map(\.entry.title).allSatisfy { $0.hasPrefix("Sort by") })
        #expect(rows[0].marks == [HighlightRange(start: 0, end: 4)])
        // Letters in order, word starts counting for more.
        #expect(Self.titles("tp").first == "Two Panes")
        #expect(Self.titles("hid").first == "Hidden Files")
        #expect(Self.titles("zzzq").isEmpty)
    }

    // A command that can't run now comes after every one that can, however well it fits.
    @Test func listsTheDimmedCommandsLast() {
        var state = ApplicationMenuState.initial
        state.disabledCommands = [.sortByName]
        let titles = Self.titles("sort", entries: Self.entries(state))
        #expect(titles.first != "Sort by Name")
        #expect(titles.last == "Sort by Name")
    }

    // The menu place matches too, after every title that fits: "go doc" is Go > Documents.
    @Test func findsACommandByItsPlaceInTheMenus() {
        let rows = CommandPalette.sections(Self.entries(), query: "go doc", recent: []).flatMap(\.rows)
        #expect(rows.map(\.entry.id) == ["goDocuments"])
        #expect(rows[0].marks == [HighlightRange(start: 0, end: 3)])
    }

    // Of two that fit as well, the one run most recently comes first.
    @Test func breaksTiesByWhatWasRunLast() {
        let plain = Self.titles("view as")
        #expect(plain.prefix(4) == ["View as Icons", "View as List", "View as Compact List", "View as Previews"])
        let recent = Self.titles("view as", recent: ["viewAsPreviews"])
        #expect(recent.first == "View as Previews")
    }

    // A command named just what was typed comes before the longer names that begin with it, so Return runs it; one
    // whose whole name begins another's comes before that one. What was run last still breaks the other ties.
    @Test func theCommandNamedAsTypedComesFirst() {
        #expect(Self.titles("copy").first == "Copy")
        #expect(Self.titles("COPY ").first == "Copy")
        #expect(Self.titles("paste").first == "Paste")
        #expect(Self.titles("open").first == "Open")
        #expect(Self.titles("share").first == "Share\u{2026}")
        #expect(Self.titles("dup").prefix(2) == ["Duplicate", "Duplicate Tab"])
        #expect(Self.titles("ope").prefix(2) == ["Open", "Open in New Tab"])
        // Run last, the longer name comes first among those that only begin with what was typed.
        #expect(Self.titles("dup", recent: ["duplicateTab"]).first == "Duplicate Tab")
        // Named as typed, a command stays first whatever was run last.
        #expect(Self.titles("copy", recent: ["copyPath"]).prefix(2) == ["Copy", "Copy Path"])
    }

    // In a tab with one pane the menu calls Close Pane "Close Tab": the palette says so too, and lists it once.
    @Test func closePaneIsCloseTabOnceInATabWithOnePane() {
        let twoPanes = Self.entries(menuTitles: ["closePane": "Close Pane"])
        #expect(Self.entry("closePane", in: twoPanes)?.title == "Close Pane")
        #expect(Self.entry("closeTab", in: twoPanes)?.title == "Close Tab")
        let onePane = Self.entries(menuTitles: ["closePane": "Close Tab"])
        #expect(Self.entry("closePane", in: onePane)?.title == "Close Tab")
        #expect(Self.entry("closeTab", in: onePane) == nil)
        #expect(onePane.filter { $0.title == "Close Tab" }.count == 1)
    }

    @Test func thePreviewCountsHaveThePreviewsSymbol() {
        for id in ["showPreviews9", "showPreviews4", "showPreviews2", "showPreviews1"] {
            #expect(Self.entry(id)?.icon == .previews, "\(id)")
        }
    }

    // Folder View Options has the symbol its toolbar button has.
    @Test func folderViewOptionsHasTheFolderViewSymbol() {
        #expect(Self.entry("folderViewOptions")?.icon == .folderView)
    }

    // MARK: Recent commands

    @Test func keepsTheRecentCommandsLastFirstEachOnce() {
        var recent: [String] = []
        for id in ["a", "b", "a"] { recent = CommandPalette.remembering(id, in: recent) }
        #expect(recent == ["a", "b"])
        for index in 0..<30 { recent = CommandPalette.remembering("c\(index)", in: recent) }
        #expect(recent.count == CommandPalette.recentLimit)
        #expect(recent.first == "c29")
        #expect(CommandPalette.sanitizeRecent(["x", 3, "x", "", "y"]) == ["x", "y"])
        #expect(CommandPalette.sanitizeRecent("x").isEmpty)
    }

    // Every command has a line saying what it does, shown under the list while it is selected: Help's line for the
    // commands of the table. It says more than the command's name, fits on the line, and is a phrase, not a sentence.
    @Test func everyCommandHasALineSayingMoreThanItsName() {
        let stop: Set<String> = ["the", "a", "an", "to", "of", "in", "it", "its", "is", "and", "or", "this", "that"]
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { !stop.contains($0) })
        }
        let views = [CommandPaletteSavedView(id: "w1", name: "Photos")]
        for entry in Self.entries(tabViews: views, windowViews: views) {
            #expect(!entry.help.isEmpty, "\(entry.id)")
            #expect(!words(entry.help).isSubset(of: words(entry.title)), "\(entry.id): \(entry.help)")
            #expect(entry.help.count <= 80, "\(entry.id): \(entry.help)")
            #expect(!entry.help.hasSuffix("."), "\(entry.id)")
        }
        // A command Help lists twice has its first line: Refresh's in a folder, not over search results.
        #expect(Self.entry("refreshOrApplySearchSort")?.help == "Refresh the current folder")
        #expect(Self.entry("toggleTwoPanes")?.help == HelpContent.line(of: .toggleTwoPanes))
    }

    @Test func placeIsTheMenuPathWithoutTheItem() {
        #expect(CommandPalette.place("View > Sort By > Name") == "View > Sort By")
        #expect(CommandPalette.place("File > Open") == "File")
        #expect(CommandPalette.place(nil) == nil)
    }
}
