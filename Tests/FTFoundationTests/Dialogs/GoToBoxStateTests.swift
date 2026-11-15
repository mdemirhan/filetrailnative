// The rules of the Go To box without its views: mode, rows, selection, keys, label, hint, empty texts, submit, and
// when completions are asked for
import Foundation
import Testing

@testable import FTFoundation

@MainActor
struct GoToBoxStateTests {
    static let home = "/Users/demo"

    static func place(_ path: String, _ name: String, _ score: Double, favorite: Bool = false, visited: Bool = true)
        -> Place
    {
        Place(
            path: path, name: name, displayPath: path.replacingOccurrences(of: home, with: "~"), isFavorite: favorite,
            isVisited: visited, score: score)
    }

    static let places: [Place] = [
        place("/Users/demo/src/filetrail", "filetrail", 9),
        place("/Users/demo/Downloads", "Downloads", 4, favorite: true),
        place("/Users/demo/src/render-farm", "render-farm", 2),
        place("/Users/demo/Desktop", "Desktop", 0, favorite: true, visited: false),
    ]

    private func names(_ state: GoToBoxState) -> [String] { state.rows.map(\.name) }
    private func selected(_ state: GoToBoxState) -> String? { state.selectedRow?.name }

    @Test func opensListingThePlacesInUseWithTheTopOneSelected() {
        let state = GoToBoxState(places: Self.places)
        #expect(state.text.isEmpty)
        #expect(state.label == "Recent and favorite folders")
        #expect(names(state) == ["filetrail", "Downloads", "render-farm", "Desktop"])
        #expect(selected(state) == "filetrail")
        #expect(state.rows.map(\.detail) == ["~/src", "~", "~/src", "~"])
        #expect(state.submitValue == "/Users/demo/src/filetrail")
        #expect(state.hint == "⌘⌫ Removes from List")
    }

    @Test func findsByLettersMarksThemAndMovesTheSelectionWithinTheEnds() {
        var state = GoToBoxState(places: Self.places)
        #expect(state.setText("d") == .none)
        #expect(names(state) == ["Downloads", "Desktop", "render-farm"])
        #expect(selected(state) == "Downloads")
        #expect(state.label == "3 matches")
        #expect(state.rows.map(\.nameRanges) == [[0..<1], [0..<1], [3..<4]])
        state.moveSelection(1)
        #expect(selected(state) == "Desktop")
        state.moveSelection(1)
        state.moveSelection(1)
        #expect(selected(state) == "render-farm")
        state.moveSelection(-1)
        state.moveSelection(-1)
        #expect(selected(state) == "Downloads")
        // ↑ from the first row gives the field what was typed back.
        state.moveSelection(-1)
        #expect(state.text == "d")
        #expect(selected(state) == "Downloads")
        #expect(state.click(1) == .submit("/Users/demo/Desktop"))
        _ = state.setText("zzz")
        #expect(state.rows.isEmpty)
        #expect(state.emptyText == "No folder you have opened has that name. Start with / or ~ to type a path.")
        #expect(!state.canSubmit)
        #expect(state.pressReturn() == .none)
        _ = state.setText("downloads")
        #expect(state.label == "1 match")
    }

    // ⌘⌫ forgets an opened folder, never a favorite that was never opened.
    @Test func forgetsTheSelectedOpenedFolderOnly() {
        var state = GoToBoxState(places: Self.places)
        #expect(state.forgetKey() == .forget("/Users/demo/src/filetrail"))
        state.forgetPlace("/Users/demo/src/filetrail")
        #expect(names(state) == ["Downloads", "render-farm", "Desktop"])
        #expect(selected(state) == "Downloads")
        _ = state.setText("desk")
        #expect(selected(state) == "Desktop")
        #expect(state.forgetKey() == nil)
        #expect(state.hint == nil)
        let noForget = GoToBoxState(places: Self.places, canForgetPlaces: false)
        #expect(noForget.forgetKey() == nil)
        #expect(noForget.hint == nil)
    }

    @Test func completesAPathFolderByFolder() {
        var state = GoToBoxState(places: Self.places)
        #expect(state.setText("de") == .none)
        #expect(state.setText("/Users/de") == .requestCompletions("/Users/de"))
        // The opened folders are not offered for a path.
        #expect(state.rows.isEmpty)
        #expect(state.emptyText == "No folders match this path")
        state.setCompletions([
            GoToCompletion(path: "/Users/demo", name: "demo"), GoToCompletion(path: "/Users/desktop", name: "desktop"),
        ])
        #expect(names(state) == ["demo", "desktop"])
        #expect(state.label == "2 matches")
        #expect(state.hint == "⇥ Completes")
        #expect(state.selectedRow == nil)
        #expect(state.submitValue == "/Users/de")
        // Tab completes with the first folder and moves on to what is inside it.
        #expect(state.tab() == .requestCompletions("/Users/demo/"))
        #expect(state.text == "/Users/demo/")
        #expect(state.rows.isEmpty)
        state.setCompletions([GoToCompletion(path: "/Users/demo/src", name: "src")])
        state.moveSelection(1)
        #expect(selected(state) == "src")
        // ↓ shows the folder in the field, as typed from "/"; Return opens it at once.
        #expect(state.text == "/Users/demo/src/")
        #expect(state.pressReturn() == .submit("/Users/demo/src"))
        // Tab with nothing listed moves the focus.
        _ = state.setText("/nowhere")
        #expect(state.tab() == nil)
    }

    // A typed path opens as typed, trimmed.
    @Test func opensATypedPathWithoutChoosingACompletion() {
        var state = GoToBoxState(places: Self.places)
        _ = state.setText(" ~/Documents ")
        #expect(state.isPathMode)
        #expect(state.pressReturn() == .submit("~/Documents"))
        state.submitting = true
        #expect(!state.canSubmit)
    }

    // While a folder is being gone to or moved into, a click or Return asks for nothing more: a double click on a
    // place in Move To starts one move, not two.
    @Test func doesNothingMoreWhileSubmitting() {
        var state = GoToBoxState(places: Self.places)
        #expect(state.click(0) == .submit("/Users/demo/src/filetrail"))
        state.submitting = true
        #expect(state.click(0) == .none)
        #expect(state.pressReturn() == .none)
        _ = state.setText("/Users/")
        state.setCompletions([GoToCompletion(path: "/Users/demo", name: "demo")])
        state.moveSelection(1)
        #expect(state.click(0) == .none)
        #expect(state.pressReturn() == .none)
        #expect(state.text == "/Users/demo/")
        state.submitting = false
        #expect(state.click(0) == .submit("/Users/demo"))
    }

    // In Go To a click on a completion goes there; choosing a folder, it shows the folder in the field, and a double
    // click sends the items there.
    @Test func aClickGoesInGoToAndChoosesWhenChoosingAFolder() {
        var state = GoToBoxState(places: [])
        _ = state.setText("/Users/")
        state.setCompletions([GoToCompletion(path: "/Users/demo", name: "demo")])
        #expect(state.click(0) == .submit("/Users/demo"))
        var choosing = GoToBoxState(places: Self.places, purpose: .chooseFolder, homePath: Self.home)
        #expect(choosing.click(1) == .none)
        #expect(choosing.text == "~/Downloads/")
        #expect(selected(choosing) == "Downloads")
        #expect(choosing.submitValue == "/Users/demo/Downloads")
        // The pointer doesn't move the choice while it is in the field.
        choosing.pointerMoved(over: 2, at: CGPoint(x: 1, y: 1))
        choosing.pointerMoved(over: 2, at: CGPoint(x: 2, y: 1))
        #expect(selected(choosing) == "Downloads")
        #expect(choosing.doubleClick(2) == .submit("/Users/demo/src/render-farm"))
    }

    // Where a folder is chosen for items, the pointer over a row chooses nothing: Return sends them where the field
    // says, a folder still to be made too.
    @Test func thePointerOverARowDoesntChooseWhereItemsGo() {
        var choosing = GoToBoxState(places: Self.places, purpose: .chooseFolder, homePath: Self.home)
        _ = choosing.setText("~/src/new")
        choosing.setCompletions([GoToCompletion(path: "/Users/demo/src/news-archive", name: "news-archive")])
        choosing.pointerMoved(over: 0, at: CGPoint(x: 1, y: 1))
        choosing.pointerMoved(over: 0, at: CGPoint(x: 2, y: 1))
        #expect(choosing.selectedRow == nil)
        #expect(choosing.submitValue == "~/src/new")
        choosing.offerToCreate(notice: "It will be made.")
        choosing.pointerMoved(over: 0, at: CGPoint(x: 3, y: 1))
        #expect(choosing.createsFolder)
        #expect(choosing.pressReturn() == .submit("~/src/new"))
        // In Go To the pointer still selects, as a click there goes at once.
        var going = GoToBoxState(places: Self.places)
        going.pointerMoved(over: 2, at: CGPoint(x: 1, y: 1))
        going.pointerMoved(over: 2, at: CGPoint(x: 2, y: 1))
        #expect(selected(going) == "render-farm")
    }

    // A folder shown in the field that is forgotten (it was gone when Return went to it) gives the field back what
    // was typed: the next Return goes where the field and the selection say, not to whichever row took its place.
    @Test func aRowShownInTheFieldThatLeavesTheListGivesBackWhatWasTyped() {
        var state = GoToBoxState(places: Self.places, homePath: Self.home)
        state.moveSelection(1)
        state.moveSelection(1)
        #expect(state.text == "~/src/render-farm/")
        // Another place going leaves the row shown where it is.
        state.setPlaces(Self.places.filter { $0.name != "filetrail" })
        #expect(state.isShowingRow)
        #expect(selected(state) == "render-farm")
        #expect(state.submitValue == "/Users/demo/src/render-farm")
        // Its own going lets go of it.
        state.setPlaces(Self.places.filter { $0.name != "filetrail" && $0.name != "render-farm" })
        #expect(!state.isShowingRow)
        #expect(state.text.isEmpty)
        #expect(selected(state) == "Downloads")
        #expect(state.submitValue == "/Users/demo/Downloads")
    }

    @Test func saysHowToTypeAPathWhenThereIsNothingToList() {
        var state = GoToBoxState(places: [])
        #expect(state.emptyText == "Folders you open are listed here. Start with / or ~ to type a path.")
        #expect(!state.showsClear)
        _ = state.setText("/nowhere")
        #expect(state.showsClear)
        state.clear()
        #expect(state.text.isEmpty)
        #expect(state.emptyText == "Folders you open are listed here. Start with / or ~ to type a path.")
    }

    // Choosing a folder selects nothing until something is typed or ↓ is pressed.
    @Test func moveToSelectsNothingUntilTyped() {
        var state = GoToBoxState(places: Self.places, purpose: .chooseFolder)
        #expect(names(state) == ["filetrail", "Downloads", "render-farm", "Desktop"])
        #expect(state.selectedRow == nil)
        #expect(!state.canSubmit)
        #expect(state.pressReturn() == .none)
        _ = state.setText("down")
        #expect(selected(state) == "Downloads")
        #expect(state.pressReturn() == .submit("/Users/demo/Downloads"))
        _ = state.setText("")
        #expect(state.selectedRow == nil)
        state.moveSelection(-1)
        #expect(selected(state) == "Desktop")
    }

    // A row chosen with ↓ is in the field, and typing goes on from it: a place's path from "~", ending in "/".
    @Test func typingGoesOnFromTheRowInTheField() {
        var state = GoToBoxState(places: Self.places, homePath: Self.home)
        _ = state.setText("src")
        #expect(names(state) == ["filetrail", "render-farm"])
        state.moveSelection(1)
        #expect(selected(state) == "render-farm")
        #expect(state.text == "~/src/render-farm/")
        #expect(state.isShowingRow)
        // The list stays as typed while the field shows the row.
        #expect(names(state) == ["filetrail", "render-farm"])
        #expect(state.setText("~/src/render-farm/sh") == .requestCompletions("~/src/render-farm/sh"))
        #expect(state.isPathMode)
        #expect(!state.isShowingRow)
        // A completion of a path from "~" is shown from "~" too.
        state.setCompletions([GoToCompletion(path: "/Users/demo/src/render-farm/shaders", name: "shaders")])
        state.moveSelection(1)
        #expect(state.text == "~/src/render-farm/shaders/")
    }

    // Escape lets go of the row in the field first; only then does it close the box.
    @Test func escapeGivesBackWhatWasTyped() {
        var state = GoToBoxState(places: Self.places, homePath: Self.home)
        _ = state.setText("down")
        let first = state.escape()
        #expect(!first)
        state.moveSelection(1)
        #expect(state.text == "~/Downloads/")
        let second = state.escape()
        #expect(second)
        #expect(state.text == "down")
        #expect(selected(state) == "Downloads")
        let third = state.escape()
        #expect(!third)
    }

    // Tab puts the selected place in the field, and the list moves on to the folders inside it.
    @Test func tabTakesAPlaceIntoTheField() {
        var state = GoToBoxState(places: Self.places, homePath: Self.home)
        _ = state.setText("render")
        #expect(state.tab() == .requestCompletions("~/src/render-farm/"))
        #expect(state.text == "~/src/render-farm/")
        #expect(state.isPathMode)
        var choosing = GoToBoxState(places: Self.places, purpose: .chooseFolder, homePath: Self.home)
        // Nothing is chosen for the user: Tab moves the focus.
        #expect(choosing.tab() == nil)
    }

    // A box choosing a folder can open on the folder shown: a path, so Return sends the items there.
    @Test func opensOnAPath() {
        var state = GoToBoxState(
            places: Self.places, purpose: .chooseFolder, homePath: Self.home, text: "~/src/")
        #expect(state.isPathMode)
        #expect(state.rows.isEmpty)
        #expect(state.emptyText == "No folders in this folder")
        #expect(state.pressReturn() == .submit("~/src/"))
        // What is said about the text goes once it is changed.
        state.error = "\u{201C}a\u{201D} is already in this folder."
        // Typing a name replaces it and finds the places again.
        _ = state.setText("down")
        #expect(state.error == nil)
        #expect(selected(state) == "Downloads")
    }

    // A folder that doesn't exist is made on the next submit of the same text, and only that text.
    @Test func offersToCreateForTheTextAsked() {
        var state = GoToBoxState(places: [], purpose: .chooseFolder, homePath: Self.home)
        _ = state.setText("~/New")
        #expect(!state.createsFolder)
        state.error = "Destination must be an existing folder."
        state.offerToCreate(notice: "There’s no folder “New”.")
        #expect(state.createsFolder)
        #expect(state.error == nil)
        _ = state.setText("~/Newer")
        #expect(!state.createsFolder)
    }

    // ".", "..", "./…" and "../…" are paths from the folder on screen; "~" and "." and ".." are followed.
    @Test func resolvesPathsFromTheFolderOnScreen() {
        let home = Self.home
        let here = "/Users/demo/src/filetrail"
        #expect(GoToBoxState.resolve("../", homePath: home, currentPath: here) == "/Users/demo/src/")
        #expect(
            GoToBoxState.resolve("./Sources", homePath: home, currentPath: here) == "/Users/demo/src/filetrail/Sources")
        #expect(GoToBoxState.resolve(" .. ", homePath: home, currentPath: here) == "/Users/demo/src")
        #expect(GoToBoxState.resolve("~/a/../b/", homePath: home, currentPath: here) == "/Users/demo/b/")
        #expect(GoToBoxState.resolve("/../..", homePath: home, currentPath: here) == "/")
        #expect(GoToBoxState.resolve(".config", homePath: home, currentPath: here) == ".config")
        #expect(GoToBoxState.folderPath("~/src/", homePath: home, currentPath: here) == "/Users/demo/src")
        #expect(GoToBoxState.folderPath("/", homePath: home, currentPath: here) == "/")
    }

    // Only a pointer that really moved selects a row.
    @Test func aPointerSelectsOnlyOnceItMoved() {
        var state = GoToBoxState(places: Self.places)
        state.pointerMoved(over: 2, at: CGPoint(x: 10, y: 10))
        #expect(selected(state) == "filetrail")
        state.pointerMoved(over: 2, at: CGPoint(x: 10, y: 10))
        #expect(selected(state) == "filetrail")
        state.pointerMoved(over: 2, at: CGPoint(x: 11, y: 10))
        #expect(selected(state) == "render-farm")
    }
}

/// Timers moved by hand.
@MainActor
final class StepTimers: TimerScheduling {
    private var jobs: [(id: Int, at: TimeInterval, action: @MainActor () -> Void)] = []
    private var next = 0
    private(set) var time: TimeInterval = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        next += 1
        let id = next
        jobs.append((id, time + delay, action))
        return TimerToken { [weak self] in MainActor.assumeIsolated { self?.jobs.removeAll { $0.id == id } } }
    }

    func advance(_ seconds: TimeInterval) {
        let limit = time + seconds
        while let job = jobs.filter({ $0.at <= limit }).min(by: { $0.at < $1.at }) {
            jobs.removeAll { $0.id == job.id }
            time = job.at
            job.action()
        }
        time = limit
    }
}

@MainActor
struct PathCompletionRequestsTests {
    // One request 350 ms after the last change; an answer for older text is dropped.
    @Test func asksAfterThePauseAndDropsStaleAnswers() async {
        let timers = StepTimers()
        var asked: [String] = []
        var heard: [[GoToCompletion]] = []
        let requests = PathCompletionRequests(timers: timers) { input in
            asked.append(input)
            return [GoToCompletion(path: input, name: "x")]
        }
        requests.onAnswer = { heard.append($0) }
        requests.setOpen(true)
        requests.setValue("/Us", requests: true)
        timers.advance(0.25)
        requests.setValue("/Use", requests: true)
        timers.advance(0.25)
        #expect(asked.isEmpty)
        timers.advance(1)
        #expect(await settle { asked == ["/Use"] && heard.count == 1 })
        // A name asks nothing; the field no longer holding the text drops the answer.
        requests.setValue("/Users", requests: true)
        timers.advance(0.35)
        requests.setValue("docs", requests: false)
        #expect(await settle { asked.count == 2 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(heard.count == 1)
        // A closed box hears nothing.
        requests.setValue("/a", requests: true)
        timers.advance(0.35)
        requests.setOpen(false)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(heard.count == 1)
    }

    // The request is trimmed with ~ expanded; a failed one is no completions.
    @Test func expandsTheHomeFolderAndTakesAFailureAsNothing() async {
        #expect(PathCompletionRequests.requestPath(" ~/src ", homePath: "/Users/demo") == "/Users/demo/src")
        #expect(PathCompletionRequests.requestPath("~", homePath: "/Users/demo") == "/Users/demo")
        let timers = StepTimers()
        var heard: [[GoToCompletion]] = []
        let requests = PathCompletionRequests(timers: timers) { _ in nil }
        requests.onAnswer = { heard.append($0) }
        requests.setOpen(true)
        requests.setValue("/x", requests: true)
        timers.advance(0.35)
        #expect(await settle { heard == [[]] })
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

struct AlertButtonsTests {
    // The default is on the right; Cancel is the default for what can't be undone or is best answered no.
    @Test func confirmationsPutTheDefaultOnTheRight() {
        let trash = AlertButtons.confirmation("Move to Trash", destructive: true, cancelIsDefault: false)
        #expect(trash.map(\.title) == ["Cancel", "Move to Trash"])
        #expect(trash.map(\.variant) == [.plain, .default])
        let delete = AlertButtons.confirmation("Delete", destructive: true, cancelIsDefault: true)
        #expect(delete.map(\.title) == ["Delete", "Cancel"])
        #expect(delete.map(\.variant) == [.destructive, .default])
        let dotName = AlertButtons.confirmation("Use “.”", destructive: false, cancelIsDefault: true)
        #expect(dotName.map(\.variant) == [.plain, .default])
        #expect(AlertButtons.prompt(submitLabel: "Rename").map(\.title) == ["Cancel", "Rename"])
        #expect(AlertButtons.notice.map(\.title) == ["OK"])
    }

    @Test func threeOrMoreAreStacked() {
        #expect(!AlertButtons.isStacked(count: 2))
        #expect(AlertButtons.isStacked(count: 3))
    }
}
