import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct AcknowledgementsWindowTests {
    private let components = [
        Acknowledgement(
            id: "fd", name: "fd", version: "10.5.0", license: "MIT or Apache 2.0", url: "https://github.com/sharkdp/fd",
            text: "MIT License\n\nCopyright (c) the fd developers"),
        Acknowledgement(
            id: "react", name: "React", version: nil, license: "MIT", url: "https://www.example.org/react",
            text: String(repeating: "A long license line that wraps and wraps. ", count: 400)),
    ]

    private func make(
        _ load: @escaping () throws -> [Acknowledgement], opened: Opened = Opened()
    ) -> AcknowledgementsWindowController {
        _ = NSApplication.shared
        let controller = AcknowledgementsWindowController(load: load, openURL: { opened.urls.append($0) })
        controller.listView.layoutSubtreeIfNeeded()
        return controller
    }

    @MainActor
    final class Opened {
        var urls: [URL] = []
    }

    struct Unreadable: Error {}

    @Test func listsEachComponentWithItsVersionLicenseSiteAndLicenseText() throws {
        let opened = Opened()
        let controller = make({ self.components }, opened: opened)
        let view = controller.listView
        #expect(
            texts("acknowledgements.intro", in: view) == [
                "File Trail is built with the open-source software below. Each one is used under its own license."
            ])
        #expect(view.entries.count == 2)
        #expect(texts("acknowledgements.name", in: view) == ["fd 10.5.0", "React"])
        #expect(texts("acknowledgements.license", in: view) == ["MIT or Apache 2.0", "MIT"])
        // Closed, an entry shows no site and no text.
        #expect(views("acknowledgements.link", in: view).isEmpty)
        #expect(views("acknowledgements.text", in: view).isEmpty)

        // Opened: the site, without its scheme, and the license text in a box of at most 300.
        view.entries[0].toggle()
        view.layoutSubtreeIfNeeded()
        #expect(view.entries[0].isOpen)
        #expect(
            (views("acknowledgements.link", in: view).first as? NSTextField)?.stringValue == "github.com/sharkdp/fd")
        #expect(texts("acknowledgements.licenseText", in: view) == ["MIT License\n\nCopyright (c) the fd developers"])
        view.entries[0].link.perform()
        #expect(opened.urls.map(\.absoluteString) == ["https://github.com/sharkdp/fd"])

        // A long license is held to 300 and scrolls; the site of www.example.org drops the scheme and the www.
        view.entries[1].toggle()
        view.layoutSubtreeIfNeeded()
        let boxes = views("acknowledgements.text", in: view)
        #expect(boxes.count == 2)
        #expect(boxes.last?.frame.height == 300)
        #expect((views("acknowledgements.link", in: view).last as? NSTextField)?.stringValue == "example.org/react")

        // Opening again closes it.
        view.entries[0].toggle()
        view.layoutSubtreeIfNeeded()
        #expect(!view.entries[0].isOpen)
        #expect(views("acknowledgements.text", in: view).count == 1)
    }

    @Test func saysSoWhenTheLicensesCanNotBeRead() {
        let controller = make { throw Unreadable() }
        let view = controller.listView
        #expect(view.entries.isEmpty)
        #expect(
            texts("acknowledgements.intro", in: view).last == "Couldn’t load the licenses.")
    }

    // The window lists what the repository ships: fd
    @Test func listsWhatTheBundleShips() {
        let controller = make({ try Acknowledgements.read() })
        #expect(controller.listView.entries.map(\.component.id) == ["fd"])
    }

    // 620 by 640, at least 460 by 360; Escape closes it
    @Test func isAWindowOf620By640ThatEscapeCloses() {
        let controller = make({ self.components })
        let window = controller.window
        #expect(window?.title == "Acknowledgements")
        #expect(window?.contentRect(forFrameRect: window?.frame ?? .zero).size == NSSize(width: 620, height: 640))
        #expect(window?.contentMinSize == NSSize(width: 460, height: 360))
        #expect(window?.styleMask.contains(.resizable) == true)
        #expect(window?.collectionBehavior.contains(.fullScreenNone) == true)
        var closed = 0
        controller.onClose = { closed += 1 }
        window?.cancelOperation(nil)
        #expect(closed == 1)
    }

    // The layout: a title strip of 40, then the intro 16 below it, and entries of 31 under a hairline
    @Test func laysTheWindowOutAsTheStylesheetDoes() {
        let view = make({ self.components }).listView
        #expect(views("acknowledgements.title", in: view).first?.frame == NSRect(x: 0, y: 0, width: 620, height: 40))
        #expect(views("acknowledgements.intro", in: view).first.map { rect($0, in: view).minY } == 56)
        let rows = views("acknowledgements.row", in: view)
        #expect(rows.map { $0.frame.height } == [31, 31])
        #expect(rows.first.map { rect($0, in: view).minY } == 84)
        // The second entry starts after the first and its hairline.
        #expect(view.entries[1].frame.minY - view.entries[0].frame.minY == 32)
    }

    // A click on a component's name or its license lands on the summary line, which opens and closes the entry.
    @Test func aClickOnTheNameOrLicenseOpensAndClosesTheEntry() throws {
        let controller = make({ self.components })
        let window = try #require(controller.window)
        let entry = controller.listView.entries[0]
        for (id, open) in [("acknowledgements.name", true), ("acknowledgements.license", false)] {
            let label = try #require(views(id, in: entry).first)
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: entry.superview)
            let hit = try #require(entry.hitTest(point))
            try #require(hit.accessibilityIdentifier() == "acknowledgements.row")
            hit.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: .zero, in: window)))
            #expect(entry.isOpen == open)
        }
    }
}
