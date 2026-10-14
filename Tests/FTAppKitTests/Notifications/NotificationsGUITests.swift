// Ports the UI cases of components/ToastViewport.test.tsx, CopyPasteProgressCard.test.tsx and App.notifications.test.tsx,
// and the Quick Look cases of App.menusAndTree.test.tsx, on a real explorer window
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

@MainActor
final class FakeQuickLookPanel: QuickLookPanelControlling {
    var isVisible = false
    var presented = 0

    func present(_ controller: QuickLookController) {
        isVisible = true
        presented += 1
    }

    func refresh() {}

    func dismiss() { isVisible = false }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct NotificationsGUITests {
        func overlay(_ tab: MainWindowController) throws -> NotificationOverlay {
            try #require(tab.notifications)
        }

        func cards(_ overlay: NotificationOverlay) -> [ToastCardView] {
            overlay.subviews.compactMap { $0 as? ToastCardView }.sorted { $0.frame.minY < $1.frame.minY }
        }

        func opened(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            #expect(await waitUntil { tab.content.entries.count >= 4 })
            return tab
        }

        /// Timers a test fires itself.
        final class Clock {
            var now = 0.0
            var pending: [(due: Double, work: @MainActor () -> Void, id: Int)] = []
            var cancelled = Set<Int>()
            var next = 0

            @MainActor func install(_ center: ToastCenter) {
                center.now = { [unowned self] in now }
                center.schedule = { [unowned self] delay, work in
                    next += 1
                    let id = next
                    pending.append((now + delay * 1000, work, id))
                    return ToastCenter.Cancel { [unowned self] in cancelled.insert(id) }
                }
            }

            @MainActor func advance(_ ms: Double) {
                now += ms
                let due = pending.filter { $0.due <= now && !cancelled.contains($0.id) }
                pending.removeAll { $0.due <= now }
                for timer in due { timer.work() }
            }
        }

        // T-f86ada36 T-6fd36956 T-b7394559 T-f7eafb7c F-817
        @Test func notificationsStackAtTheBottomRightNewestLowestWithTheirMark() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let overlay = try overlay(tab)
            overlay.toasts.push(.success, title: "Copied path", message: "note.txt")
            overlay.toasts.push(.info, title: "A window can have up to 100 tabs")
            overlay.layoutSubtreeIfNeeded()
            let shown = cards(overlay)
            #expect(shown.map(\.entry.title) == ["Copied path", "A window can have up to 100 tabs"])
            let metrics = DesignTokens.toast
            for card in shown {
                // 12 from the window's right edge, as wide as the text and no wider than 420.
                #expect(abs(card.frame.maxX - (overlay.bounds.width - metrics.rightInset)) < 0.5)
                #expect(card.frame.width <= metrics.maxWidth)
                #expect(card.hitTest(NSPoint(x: 5, y: 5)) == nil)
            }
            // Six apart, and the newest at the bottom, 10 above the path bar.
            #expect(abs(shown[1].frame.minY - shown[0].frame.maxY - metrics.stackGap) < 0.5)
            let bar = tab.content.contentShell.pathBarRow
            let barTop = overlay.convert(bar.bounds, from: bar).minY
            #expect(abs(shown[1].frame.maxY - (barTop - BottomStack.gapAbove)) < 0.5)
            // The mark: a disc for each kind, and the text one line.
            let icon = try #require(shown[0].subviews.compactMap { $0 as? ToastIconView }.first)
            #expect(icon.frame.size == NSSize(width: metrics.iconSize, height: metrics.iconSize))
            #expect(icon.kind == .success)
            #expect(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil)
            await harness.close()
        }

        // T-129550df T-f6990b56 F-817
        @Test func eachNotificationGoesAfterFourSecondsAndNoMoreThanThreeShow() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let overlay = try overlay(tab)
            let clock = Clock()
            clock.install(overlay.toasts)
            for number in 1...4 { overlay.toasts.push(.info, title: "Toast \(number)") }
            #expect(cards(overlay).map(\.entry.title) == ["Toast 2", "Toast 3", "Toast 4"])
            clock.advance(3_999)
            #expect(overlay.toasts.entries.count == 3)
            clock.advance(2)
            #expect(overlay.toasts.entries.isEmpty)
            #expect(cards(overlay).isEmpty)
            await harness.close()
        }

        // T-501968da F-817
        @Test func noNotificationComesWhenTheyAreTurnedOffAndThoseShowingGo() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let overlay = try overlay(tab)
            overlay.toasts.push(.info, title: "Showing")
            tab.updatePreferences(["notificationsEnabled": .bool(false)])
            tab.preferencesChanged(PreferencesChange(patch: ["notificationsEnabled": .bool(false)], senderID: nil))
            #expect(await waitUntil { overlay.toasts.entries.isEmpty })
            #expect(overlay.toasts.push(.info, title: "Not shown") == nil)
            #expect(cards(overlay).isEmpty)
            await harness.close()
        }

        // F-818: the 101st tab
        @Test func theTabLimitNoticeIsAnInfoToastInTheWindow() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            harness.windows.showNotice(.tabLimit, tab.window)
            let overlay = try overlay(tab)
            #expect(overlay.toasts.entries.map(\.title) == ["A window can have up to 100 tabs"])
            #expect(overlay.toasts.entries.first?.kind == .info)
            await harness.close()
        }

        // T-b7bbe121 T-f8116c96 F-799
        @Test func theProgressCardComesAfterTheDelayAndShowsWhatRunsAndStops() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let overlay = try overlay(tab)
            let model = overlay.progress
            model.delayMs = 40
            var stopped = 0
            model.onStop = { stopped += 1 }
            model.state = WriteOperationCardState(
                action: .moveTo, stage: .running, completedItemCount: 1, totalItemCount: 4, completedByteCount: 500,
                totalBytes: 1_000, currentSourcePath: "/a/report.pdf")
            // An operation over in a moment shows no card.
            #expect(model.isVisible == false)
            #expect(await waitUntil { model.isVisible })
            overlay.layoutSubtreeIfNeeded()
            let card = try #require(overlay.subviews.compactMap { $0 as? ProgressCardView }.first)
            #expect(!card.isHidden)
            let metrics = DesignTokens.progressCard
            #expect(abs(card.frame.width - metrics.width) < 0.5)
            #expect(abs(card.frame.maxX - (overlay.bounds.width - metrics.rightInset)) < 0.5)
            let bar = tab.content.contentShell.pathBarRow
            #expect(abs(card.frame.maxY - (overlay.convert(bar.bounds, from: bar).minY - BottomStack.gapAbove)) < 0.5)
            func text(_ id: String) -> String? {
                var found: String?
                func walk(_ view: NSView) {
                    if view.accessibilityIdentifier() == id, let field = view as? NSTextField { found = field.stringValue }
                    view.subviews.forEach(walk)
                }
                walk(card)
                return found
            }
            #expect(text("progressCard.title") == "Moving…")
            #expect(text("progressCard.percent") == "50%")
            #expect(text("progressCard.detailLabel") == "Current item:")
            #expect(text("progressCard.detailValue") == "report.pdf")
            #expect(text("progressCard.meta") == "1 of 4 items · 500 B of 1.0 KB")
            // A notification rests above the card.
            overlay.toasts.push(.info, title: "On top")
            overlay.layoutSubtreeIfNeeded()
            let toast = try #require(cards(overlay).first)
            #expect(abs(toast.frame.maxY - (card.frame.minY - BottomStack.gapBetween)) < 0.5)
            // Stop.
            let stop = try #require(card.subviews.compactMap { $0 as? SmallPushButton }.first)
            stop.perform()
            #expect(stopped == 1)
            model.state = nil
            #expect(card.isHidden)
            await harness.close()
        }

        @Test func anOperationOverBeforeTheDelayShowsNoCard() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let model = try overlay(tab).progress
            model.delayMs = 5_000
            model.state = WriteOperationCardState(action: .trash, stage: .starting)
            model.state = nil
            #expect(model.isVisible == false)
            #expect(model.text == nil)
            await harness.close()
        }

        // T-0db05884 F-686 F-145: Space previews the selected item, and Space again closes the panel
        @Test func spacePreviewsTheSelectedItemWithQuickLookAndSpaceAgainClosesIt() async throws {
            let harness = try ExplorerHarness()
            let tab = try await opened(harness)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.focusList()
            tab.content.select(paths: [note.path])
            #expect(await waitUntil { tab.focusedPane == .content && tab.content.selection.paths == [note.path] })
            let quickLook = QuickLookController.shared
            let system = quickLook.panel
            let fake = FakeQuickLookPanel()
            quickLook.panel = fake
            defer { quickLook.panel = system }
            func space() {
                guard let window = tab.window,
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                        isARepeat: false, keyCode: 49)
                else { return }
                window.sendEvent(event)
            }
            space()
            #expect(quickLook.url?.path == note.path)
            #expect(quickLook.isShowing)
            space()
            #expect(!quickLook.isShowing)
            // Only the one item is previewed.
            space()
            #expect(quickLook.numberOfPreviewItems(in: nil) == 1)
            #expect(fake.presented == 2)
            // The transition leaves from the item's row.
            let frame = quickLook.sourceFrame?(URL(fileURLWithPath: note.path))
            #expect(frame != nil && frame?.isEmpty == false)
            await harness.close()
        }
    }
}
