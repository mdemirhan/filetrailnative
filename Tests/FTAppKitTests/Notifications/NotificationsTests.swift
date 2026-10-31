// Ports the UI cases of components/ToastViewport.test.tsx, CopyPasteProgressCard.test.tsx and
// App.notifications.test.tsx on an explorer window that is never shown
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct NotificationsTests {
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

        // T-f86ada36 T-6fd36956 T-b7394559 T-f7eafb7c F-817
        // B-VIEW-106 B-VIEW-196 B-VIEW-197 B-VIEW-199 T-2709df93
        @Test func notificationsStackAtTheBottomRightNewestLowestWithTheirMark() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            let overlay = try overlay(tab)
            overlay.toasts.push(.success, title: "Copied path", message: "note.txt")
            overlay.toasts.push(.info, title: "A window can have up to 25 tabs")
            overlay.layoutSubtreeIfNeeded()
            let shown = cards(overlay)
            #expect(shown.map(\.entry.title) == ["Copied path", "A window can have up to 25 tabs"])
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

        // T-501968da F-817
        // F-817 (each goes after four seconds: ToastTimersTests; no more than three show: FTFoundation's ToastsTests; the
        // cards follow the entries here and in the stack test)
        // B-CLIP-131 B-VIEW-200 T-574c64da
        @Test func noNotificationComesWhenTheyAreTurnedOffAndThoseShowingGo() async throws {
            let harness = try ExplorerHarness.windowless()
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
        // F-817 F-818 T-31b584e6
        @Test func theTabLimitNoticeIsAnInfoToastInTheWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await opened(harness)
            harness.windows.showNotice(.tabLimit, tab.window)
            let overlay = try overlay(tab)
            #expect(overlay.toasts.entries.map(\.title) == ["A window can have up to 25 tabs"])
            #expect(overlay.toasts.entries.first?.kind == .info)
            await harness.close()
        }

        // T-b7bbe121 T-f8116c96 F-799
        // B-CLIP-111 B-CLIP-113 B-INFO-191 B-INFO-192 T-49de7117 T-596b528f
        @Test func theProgressCardComesAfterTheDelayAndShowsWhatRunsAndStops() async throws {
            let harness = try ExplorerHarness.windowless()
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
                    if view.accessibilityIdentifier() == id, let field = view as? NSTextField {
                        found = field.stringValue
                    }
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

        // T-596b528f
        @Test func anOperationOverBeforeTheDelayShowsNoCard() {
            let model = ProgressCardModel()
            var changes = 0
            model.onChange = { changes += 1 }
            model.delayMs = 5_000
            model.state = WriteOperationCardState(action: .trash, stage: .starting)
            model.state = nil
            #expect(model.isVisible == false)
            #expect(model.text == nil)
            #expect(changes == 0)
        }
    }
}
