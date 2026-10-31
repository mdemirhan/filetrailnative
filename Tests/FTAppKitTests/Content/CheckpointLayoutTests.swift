// Checkpoint resume-2026-10-19 (143, 148): the labels sized to the original's text width draw their whole text, and the
// list's rows keep the gutter before the Info panel, on an explorer window that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct CheckpointLayoutTests {
        func allViews(in root: NSView?) -> [NSView] {
            guard let root, !root.isHidden else { return [] }
            return [root] + root.subviews.flatMap { allViews(in: $0) }
        }

        /// The text boxes that are as wide as their text: each must draw all of it.
        func fullWidthLabels(in tab: MainWindowController) -> [(TextBoxCell, NSRect, String)] {
            allViews(in: tab.window?.contentView).compactMap { view in
                guard let field = view as? NSTextField, let cell = field.cell as? TextBoxCell,
                    !field.stringValue.isEmpty, let font = field.font
                else { return nil }
                guard field.frame.width >= textExtent(field.stringValue, font) - 0.5 else { return nil }
                return (cell, field.frame, field.stringValue)
            }
        }

        // F-697 F-748: the status text, the Info panel's name, subtitle and Open button, and the tree's labels are
        // laid out at the text's width and draw it all.
        @Test func labelsAtTheirTextsWidthAreNotCut() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            let root = tab.window?.contentView?.superview
            #expect(
                await waitUntil {
                    root.map { findViews("infoPanel.name", in: $0).map(fieldText) } == ["note.txt"]
                })
            harness.layout(tab)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            let ids = ["statusBar", "infoPanel.name", "infoPanel.subtitle", "infoPanel.open.label"]
            for id in ids {
                let views = root.map { findViews(id, in: $0) } ?? []
                #expect(!views.isEmpty, "\(id)")
                for view in views {
                    let field = try #require(view as? NSTextField, "\(id)")
                    let cell = try #require(field.cell as? TextBoxCell, "\(id)")
                    let font = try #require(field.font)
                    #expect(!field.stringValue.isEmpty, "\(id)")
                    #expect(
                        !cell.truncates(in: field.frame.size), "\(id): \(field.stringValue) in \(field.frame.width)")
                    // The frame is still the original's: the text's own width.
                    #expect(abs(field.frame.width - textExtent(field.stringValue, font)) < 1, "\(id)")
                }
            }
            let labels = fullWidthLabels(in: tab)
            #expect(labels.contains { $0.2 == "note.txt" })
            // The sidebar's rows (the tree's labels among them) are text boxes too.
            #expect(labels.contains { $0.0.controlView is SidebarLabelField })
            for (cell, frame, text) in labels {
                #expect(!cell.truncates(in: frame.size), "\(text) in \(frame.width)")
            }
            await harness.close()
        }

        // F-697: `.get-info-name` wraps a long name onto up to 2 lines (-webkit-line-clamp: 2, word-break: break-word)
        // before its ellipsis; the frame is two lines tall and the name drawn whole.
        @Test func aLongInfoPanelNameWrapsOntoTwoLines() async throws {
            let harness = try ExplorerHarness.windowless()
            let long = "Quarterly planning notes for the design team review.pdf"
            try "x".write(to: harness.folder.appending(long), atomically: true, encoding: .utf8)
            let tab = try await harness.open()
            tab.perform(.toggleInfoPanel)
            harness.layout(tab)
            let item = try #require(tab.content.entries.first { $0.name == long })
            tab.content.select(paths: [item.path])
            let root = tab.window?.contentView?.superview
            #expect(await waitUntil { root.map { findViews("infoPanel.name", in: $0).map(fieldText) } == [long] })
            harness.layout(tab)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            let field = try #require(root.flatMap { findViews("infoPanel.name", in: $0).first } as? NSTextField)
            let cell = try #require(field.cell as? TextBoxCell)
            let line = (field.font?.pointSize ?? 15) * 1.3
            #expect(abs(field.frame.height - 2 * line) < 0.5, "\(field.frame)")
            #expect(!cell.truncates(in: field.frame.size), "\(field.frame)")
            await harness.close()
        }

        // F-765: with the Info panel open the rows stop where the header does, 10 pt before the pane's edge, and follow
        // the pane back when it closes.
        @Test func rowsKeepTheGutterBeforeTheInfoPanel() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !listViews("list.row", in: tab.window?.contentView).isEmpty }
            harness.layout(tab)
            func gutters() -> [Double] {
                let pane = tab.content.contentShell.convert(tab.content.contentShell.bounds, to: nil)
                return listViews("list.row", in: tab.window?.contentView).map { bar in
                    pane.maxX - bar.convert(bar.bounds, to: nil).maxX
                }
            }
            #expect(!gutters().isEmpty)
            #expect(gutters().allSatisfy { $0 == 10 })
            for _ in 0..<2 {
                tab.perform(.toggleInfoPanel)
                harness.layout(tab)
                try? await Task.sleep(for: .milliseconds(400))
                harness.layout(tab)
                #expect(!gutters().isEmpty)
                let after = gutters()
                #expect(after.allSatisfy { $0 == 10 }, "\(after)")
            }
            await harness.close()
        }
    }
}
