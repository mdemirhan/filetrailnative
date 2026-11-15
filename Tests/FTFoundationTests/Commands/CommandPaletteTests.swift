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
        workspaces: [CommandPaletteWorkspace] = []
    ) -> [CommandPaletteEntry] {
        CommandPalette.entries(
            bindings: ShortcutCommands.defaultBindings, states: states(state), menuTitles: menuTitles,
            workspaces: workspaces)
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
                || id == ApplicationMenu.manageWorkspacesItemID
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

    // Every workspace by its name, in a new window and in this one, the first five with their keys.
    @Test func listsEachWorkspaceByItsName() {
        let workspaces = (1...6).map { CommandPaletteWorkspace(id: "w\($0)", name: "Work \($0)") }
        let entries = Self.entries(workspaces: workspaces)
        let first = Self.entry("workspace:w1", in: entries)
        #expect(first?.title == "Workspace \u{201C}Work 1\u{201D}")
        #expect(first?.keys == ["⌃", "⌘", "1"])
        #expect(first?.place == "Window > Workspaces")
        #expect(Self.entry("workspaceHere:w1", in: entries)?.title == "Workspace \u{201C}Work 1\u{201D} in This Window")
        #expect(Self.entry("workspaceHere:w1", in: entries)?.keys == ["⌃", "⌥", "⌘", "1"])
        #expect(Self.entry("workspace:w6", in: entries)?.keys == [])
        #expect(!entries.contains { $0.id == "openWorkspace1" })
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
        let workspaces = [CommandPaletteWorkspace(id: "w1", name: "Photos")]
        for entry in Self.entries(workspaces: workspaces) {
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
