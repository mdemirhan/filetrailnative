// The rules of apps/desktop/src/renderer/components/GoToFolderDialog.tsx and hooks/usePathSuggestions.ts without the
// views: mode, rows, selection, keys, label, hint, empty texts, submit, and when completions are asked for
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

    // B-DLG-021 B-DLG-028 B-DLG-031 B-DLG-032
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

    // B-DLG-022 B-DLG-023 B-DLG-026 B-DLG-027 B-DLG-029 B-DLG-030 B-DLG-033 B-DLG-036
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
    // B-DLG-037
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

    // B-DLG-041 B-DLG-042 B-DLG-048 B-DLG-049 B-DLG-051
    // B-DLG-017
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
        // Return puts the selected folder into the field; Return again opens it.
        #expect(state.pressReturn() == .requestCompletions("/Users/demo/src"))
        #expect(state.text == "/Users/demo/src")
        #expect(state.pressReturn() == .submit("/Users/demo/src"))
        // Tab with nothing listed moves the focus.
        _ = state.setText("/nowhere")
        #expect(state.tab() == nil)
    }

    // A typed path opens as typed, trimmed.
    // B-DLG-050 B-DLG-015
    @Test func opensATypedPathWithoutChoosingACompletion() {
        var state = GoToBoxState(places: Self.places)
        _ = state.setText(" ~/Documents ")
        #expect(state.isPathMode)
        #expect(state.pressReturn() == .submit("~/Documents"))
        state.submitting = true
        #expect(!state.canSubmit)
    }

    // A click on a completion puts it into the field without a slash, and selects nothing.
    // B-DLG-052
    @Test func aClickOnACompletionFillsTheField() {
        var state = GoToBoxState(places: [])
        _ = state.setText("/Users/")
        state.setCompletions([GoToCompletion(path: "/Users/demo", name: "demo")])
        #expect(state.click(0) == .requestCompletions("/Users/demo"))
        #expect(state.text == "/Users/demo")
        #expect(state.selectedIndex == -1)
    }

    // B-DLG-030 B-DLG-040
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

    // Move To selects nothing until something is typed or ↓ is pressed.
    // B-DLG-058 B-DLG-059
    @Test func moveToSelectsNothingUntilTyped() {
        var state = GoToBoxState(places: Self.places, selectFirstPlace: false)
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

    // Only a pointer that really moved selects a row.
    // B-DLG-034
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
    // B-DLG-043 B-DLG-045
    // B-DLG-017
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
    // B-DLG-044 B-DLG-045
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
        #expect(AlertButtons.defaultIndex(trash) == 1)
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
