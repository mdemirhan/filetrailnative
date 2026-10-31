// Ports apps/desktop/src/renderer/AboutWindowApp.test.tsx and the About window's size and behavior (main.ts, B-DLG-259)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// Every view below `root` with this accessibility identifier, top to bottom.
@MainActor
func views(_ identifier: String, in root: NSView) -> [NSView] {
    var found: [NSView] = []
    func walk(_ view: NSView) {
        if view.accessibilityIdentifier() == identifier { found.append(view) }
        for child in view.subviews { walk(child) }
    }
    walk(root)
    return found.sorted { $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY }
}

/// Where a view is in `root`.
@MainActor
func rect(_ view: NSView, in root: NSView) -> NSRect { view.convert(view.bounds, to: root) }

/// The texts of the views with this identifier.
@MainActor
func texts(_ identifier: String, in root: NSView) -> [String] {
    views(identifier, in: root).compactMap { ($0 as? NSTextField)?.stringValue }
}

@MainActor
@Suite struct AboutWindowTests {
    private let info = AboutInfo(
        version: "0.1.0", commit: "df11088", macosVersion: "27.0", architecture: "Apple silicon", fdVersion: "10.5.0")

    @MainActor
    final class Recorder {
        var copied: [String] = []
        var opened: [URL] = []
        var acknowledgements = 0
        var copyWorks = true
    }

    private func make(_ info: AboutInfo?, _ recorder: Recorder, _ scheduler: HandScheduler = HandScheduler())
        -> AboutWindowController
    {
        _ = NSApplication.shared
        let actions = AboutActions(
            copyText: { text in
                recorder.copied.append(text)
                return recorder.copyWorks
            }, openURL: { recorder.opened.append($0) }, openAcknowledgements: { recorder.acknowledgements += 1 },
            scheduler: scheduler)
        let controller = AboutWindowController(info: info, actions: actions)
        controller.aboutView.layoutSubtreeIfNeeded()
        return controller
    }

    // T-50f842b6 F-669 F-670 B-DLG-260
    @Test func showsTheAppItsIconAndTheVersionsABugReportNeeds() {
        let controller = make(info, Recorder())
        let view = controller.aboutView
        #expect(texts("about.title", in: view) == ["File Trail"])
        #expect(texts("about.tagline", in: view) == ["A file browser that stays out of your way."])
        #expect(views("about.icon", in: view).count == 1)
        #expect(texts("about.row.label", in: view) == ["Version", "macOS", "Search"])
        #expect(texts("about.row.value", in: view) == ["0.1.0 (df11088)", "27.0, Apple silicon", "fd 10.5.0"])
        #expect(texts("about.copyright", in: view) == ["© 2026 Mustafa Demirhan"])
        #expect(
            views("about.button", in: view).compactMap { ($0 as? NSButton)?.title } == [
                "Copy Details", "GitHub", "Report an Issue",
            ])
        #expect(controller.window?.title == "About File Trail")
    }

    // B-DLG-260 the version without a commit; B-DLG-262 the rows stay empty when the info cannot be read
    @Test func showsTheVersionAloneWithoutACommitAndNoRowsWithoutInfo() {
        var plain = info
        plain.commit = nil
        #expect(texts("about.row.value", in: make(plain, Recorder()).aboutView).first == "0.1.0")
        let empty = make(nil, Recorder())
        #expect(texts("about.row.value", in: empty.aboutView).isEmpty)
        #expect(texts("about.title", in: empty.aboutView) == ["File Trail"])
        #expect(!empty.aboutView.copyButton.isEnabled)
    }

    // T-18937749 F-670 B-DLG-261
    @Test func copiesTheDetailsAndSaysSoFor1500Milliseconds() {
        let recorder = Recorder()
        let scheduler = HandScheduler()
        let view = make(info, recorder, scheduler).aboutView
        #expect(view.copyButton.title == "Copy Details")

        view.copyButton.perform()
        #expect(recorder.copied == ["File Trail 0.1.0 (df11088)\nmacOS 27.0, Apple silicon\nfd 10.5.0"])
        #expect(view.copyButton.title == "Copied")
        scheduler.advance(1499)
        #expect(view.copyButton.title == "Copied")
        scheduler.advance(1)
        #expect(view.copyButton.title == "Copy Details")
    }

    // B-DLG-261 a copy that fails changes nothing; a second copy starts the note again
    @Test func aFailedCopyChangesNothingAndASecondCopyRestartsTheNote() {
        let recorder = Recorder()
        let scheduler = HandScheduler()
        let view = make(info, recorder, scheduler).aboutView
        recorder.copyWorks = false
        view.copyButton.perform()
        #expect(view.copyButton.title == "Copy Details")
        #expect(!view.copied)

        recorder.copyWorks = true
        view.copyButton.perform()
        scheduler.advance(1000)
        view.copyButton.perform()
        scheduler.advance(1000)
        #expect(view.copyButton.title == "Copied")
        scheduler.advance(500)
        #expect(view.copyButton.title == "Copy Details")
    }

    // T-57cd1b43 F-670 B-DLG-262
    @Test func linksToTheProjectAndOpensAcknowledgements() {
        let recorder = Recorder()
        let view = make(info, recorder).aboutView
        view.gitHubButton.perform()
        view.issuesButton.perform()
        #expect(
            recorder.opened.map(\.absoluteString) == [
                "https://github.com/mdemirhan/filetrailnative", "https://github.com/mdemirhan/filetrailnative/issues",
            ])
        view.acknowledgementsLink.perform()
        #expect(recorder.acknowledgements == 1)
    }

    // T-0ec7feeb F-670 B-DLG-263
    @Test func closesWithEscape() {
        let controller = make(info, Recorder())
        var closed = 0
        controller.onClose = { closed += 1 }
        #expect((controller.window as? PageWindow)?.closesOnEscape == true)
        controller.window?.cancelOperation(nil)
        #expect(closed == 1)
    }

    // F-635 B-DLG-259: 460 by 356, not resizable or minimizable, not full-screenable
    @Test func isAFixedWindowOf460By356() {
        let controller = make(info, Recorder())
        let window = controller.window
        #expect(window?.contentRect(forFrameRect: window?.frame ?? .zero).size == NSSize(width: 460, height: 356))
        #expect(window?.styleMask.contains(.resizable) == false)
        #expect(window?.styleMask.contains(.miniaturizable) == false)
        #expect(window?.collectionBehavior.contains(.fullScreenNone) == true)
        #expect(window?.standardWindowButton(.zoomButton)?.isEnabled == false)
        #expect(window?.standardWindowButton(.miniaturizeButton)?.isEnabled == false)
        // F-636 the window's background is the page window's, not transparent.
        #expect(window?.backgroundColor == NSColor(AppearanceModel.shared.theme.pageWindowBackground))
    }

    // F-669 the layout, from the stylesheet (ui.md 7.2): the 72 point icon, the rows of 31 under a hairline, the buttons
    @Test func laysTheWindowOutAsTheStylesheetDoes() {
        let view = make(info, Recorder()).aboutView
        let icon = views("about.icon", in: view).first?.frame
        #expect(icon == NSRect(x: 28, y: 42, width: 72, height: 72))
        let labels = views("about.row.label", in: view).map(\.frame)
        // 40 for the title strip, 2 + 72 + 18 for the header, a hairline, then rows of 8 + 14 + 8 + 1.
        #expect(labels.map(\.minY) == [141, 172, 203])
        let buttons = views("about.button", in: view).map(\.frame)
        #expect(buttons.map(\.minY) == [242, 242, 242])
        #expect(buttons.map(\.height) == [24, 24, 24])
        #expect(abs((buttons.first?.minX ?? 0) - 28) < 0.01)
        let link = views("about.link", in: view).first?.frame
        #expect(link?.minX == 28)
        #expect(link?.maxY == 338)
    }
}
