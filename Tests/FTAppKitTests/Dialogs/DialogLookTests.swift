// Ports by feature what the wave-3-end checkpoint compared of the Go To box (GoToFolderDialog.tsx, the
// .go-to-folder-* and .clear-button rules of styles.css) and of the scrim (.modal-scrim), on a real tab whose window
// is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct DialogLookTests {
        private func open() async throws -> (ExplorerHarness, MainWindowController) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.updatePreferences(["favorites": .array([])])
            let store = harness.store
            MainWindowController.visitStore = { store }
            MainWindowController.dialogTimers = ManualTimers()
            return (harness, tab)
        }

        private func close(_ harness: ExplorerHarness) async {
            MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store }
            MainWindowController.dialogTimers = TaskTimerScheduler()
            await harness.close()
        }

        private func openBox(_ tab: MainWindowController) throws -> GoToFolderBox {
            tab.perform(.openLocationSheet)
            let box = try #require(tab.goToBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return box
        }

        // The system tab bar lies over the content under the band: a sheet starts under it, or the bar hides its top.
        @Test func aSheetStartsUnderTheTabBar() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            tab.perform(.newTab)
            let group = try #require(tab.group)
            #expect(await waitUntil { group.tabs.count == 2 })
            // The tabs of a window that is never shown are not put in a native group: put them in one, unshown.
            window.addTabbedWindow(try #require(group.tabs.last?.window), ordered: .above)
            harness.layout(tab)
            let box = try openBox(tab)
            let scrim = try #require(tab.dialogs.first)
            let top = WindowChrome.panesTop(window)
            #expect(top > 52)
            let panel = scrim.convert(box.bounds, from: box)
            #expect(abs(panel.minY - (DialogLayout.sheetTop + top - 52)) < 0.5, "\(panel)")
            #expect(panel.minY >= top)
            await close(harness)
        }

        // The drops of `--elevation-dialog` go down from the panel: below it the scrim is darker than above it, at the same
        // distance (17: they went up under the sheets). F-848
        @Test func thePanelsShadowFallsBelowIt() async throws {
            let (harness, tab) = try await open()
            let box = try openBox(tab)
            let scrim = try #require(DialogScrim.front(in: tab.window))
            #expect(box.layer?.shadowOpacity == 0)
            // As `tools/capture` takes the window: the whole frame view. The scrim alone, captured apart from the flipped
            // `WorkspaceView` it stands in, shows its context's shadow the other way, as no window does.
            let frameView = try #require(tab.window?.contentView?.superview)
            let whole = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: whole)
            let scale = CGFloat(whole.pixelsWide) / frameView.bounds.width
            let panel = scrim.convert(box.frame, to: frameView)
            func gray(_ y: CGFloat) -> CGFloat {
                let row = Int((frameView.bounds.height - y) * scale)
                return whole.colorAt(x: Int(panel.midX * scale), y: row)?.usingColorSpace(.sRGB)?.redComponent ?? 0
            }
            // The frame view's y goes up: 12 under the panel it is much darker than farther down.
            #expect(gray(panel.minY - 12) < gray(panel.minY - 240) - 0.06)
            await close(harness)
        }

        // The toolbar's items dim as the dialog comes up and light again as it goes, with no other change to tell them.
        // F-848 B-DLG-064
        @Test func theToolbarDimsUnderADialogAtOnce() async throws {
            let (harness, tab) = try await open()
            let switcher = try #require(tab.explorerToolbar.viewSwitch)
            #expect(switcher.isEnabled)
            _ = try openBox(tab)
            #expect(!switcher.isEnabled)
            tab.goToBox?.onClose()
            #expect(switcher.isEnabled)
            await close(harness)
        }

        // `openLocationSheet` and `openMoveDialog` leave no pane focused: the list's selection is grey under the box (232).
        // Under an alert too: its button takes the focus, the pane's blur sets no pane focused (234), and Cancel gives
        // the keyboard and the accent back. F-861 B-DLG-056
        @Test func theListLosesItsFocusedLookUnderTheBoxAndUnderAnAlert() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            tab.perform(.viewAsDetails)
            let list = try #require(tab.content.pane as? ListViewController)
            tab.content.focusList()
            #expect(list.hasKeyboard)
            let box = try openBox(tab)
            #expect(!list.hasKeyboard)
            box.onClose()
            #expect(list.hasKeyboard)
            let scrim = InWindowAlerts.present(
                AlertContent(
                    title: "T", message: nil, buttons: [AlertButton(title: "OK", variant: .plain) {}], stacked: nil,
                    accessory: nil, onEscape: {}), in: window)
            #expect(!list.hasKeyboard)
            scrim.dismiss()
            #expect(window.firstResponder === list.focusView)
            #expect(list.hasKeyboard)
            await close(harness)
        }

        // B-NAV-223: a dialog opened from a text field gives the keyboard back to it, with the same text selected; when
        // the field has gone, to a pane; and only once no dialog is up.
        @Test func aDialogOpenedFromATextFieldGivesTheKeyboardBack() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            func alert() -> DialogScrim {
                InWindowAlerts.present(
                    AlertContent(
                        title: "T", message: nil, buttons: [AlertButton(title: "OK", variant: .plain) {}], stacked: nil,
                        accessory: nil, onEscape: {}), in: window)
            }
            tab.perform(.viewAsDetails)
            tab.content.focusList()
            tab.perform(.focusFileSearch)
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.perform(.focusFileSearch)
            let editor = try #require(field.currentEditor())
            editor.selectedRange = NSRange(location: 1, length: 2)
            let first = alert()
            let second = alert()
            second.dismiss()
            #expect(!field.isActive)
            first.dismiss()
            #expect(field.isActive)
            #expect(field.currentEditor()?.selectedRange == NSRange(location: 1, length: 2))

            // The path editor ends when the dialog takes the keyboard, and hides.
            let bar = tab.content.contentShell.pathBarRow
            bar.beginEditing()
            #expect(bar.isEditing)
            let over = alert()
            #expect(!bar.isEditing)
            over.dismiss()
            #expect(window.firstResponder === tab.content.focusView)
            await close(harness)
        }

        private static func first<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
            if let found = root as? T { return found }
            for child in root.subviews { if let found = first(type, in: child) { return found } }
            return nil
        }

        // A row's name is shown whole while it fits in 55% of the row, the location taking the rest; the name, the
        // location, the field's text and the label start where the original's do (a cell draws its text 2 in).
        // F-848 F-849 B-DLG-027
        @Test func rowsShowTheNameWholeAndTextStartsWhereTheOriginalsDoes() async throws {
            let (harness, tab) = try await open()
            for name in ["Alpha", "Beta", "Gamma"] {
                harness.store.recordFolderVisit(harness.folder.appending(name).path, kind: .stay)
            }
            let box = try openBox(tab)
            DialogKeys.type("a", into: box)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(box.rowViews.count == 3)
            for row in box.rowViews {
                row.layoutSubtreeIfNeeded()
                let natural = ceil(row.nameLabel.attributedStringValue.size().width)
                // padding 10, the glyph 14, the gap 8; the cell's 2 on each side.
                #expect(row.nameLabel.frame.minX == 30)
                #expect(row.nameLabel.frame.width == natural + 4)
                #expect(row.pathLabel.frame.minX == 32 + natural + 8 - 2)
                #expect(row.pathLabel.frame.maxX == row.bounds.width - 10 + 2)
            }
            // The field's text starts 8 + 14 + 8 into the shell; the label 10 into the section.
            #expect(box.field.frame.minX == 28)
            #expect(abs(box.listLabel.frame.minX - (6 + 10 - 2)) < 0.01)
            // The ✕ is a grey disc with the cross in the panel's color.
            #expect(!box.shell.clearButton.isHidden)
            #expect(box.shell.clearButton.crossColor == AppearanceModel.shared.theme.palette.bgElevated)
            #expect(box.shell.clearButton.discAlpha == 0.28)
            await close(harness)
        }

        // The empty list's words are in the secondary color, drawn flattened onto the panel as the original's
        // translucent color shows; the field itself says the color meant.
        // F-852 B-DLG-012
        @Test func theEmptyStateIsInTheSecondaryColor() async throws {
            let (harness, tab) = try await open()
            let box = try openBox(tab)
            DialogKeys.type("qqqq", into: box)
            #expect(box.emptyLabel.stringValue.hasPrefix("No folder you have opened has that name."))
            let palette = AppearanceModel.shared.theme.palette
            #expect(box.emptyLabel.textColor == NSColor(palette.textSecondary))
            let drawn = box.emptyLabel.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            #expect((drawn as? NSColor) == NSColor(palette.textSecondary.flattened(over: palette.bgElevated)))
            #expect(box.emptyLabel.alignment == .center)
            await close(harness)
        }

        // The scrim covers the toolbar band too: a veil laid into the title bar under the window's buttons, over the
        // content column, which takes the band's presses; it goes with the dialog. The sidebar gets a little more.
        // F-843 B-DLG-001
        @Test func theScrimCoversTheToolbarBandUnderTheWindowsButtons() async throws {
            let (harness, tab) = try await open()
            let window = try #require(tab.window)
            let box = try openBox(tab)
            let scrim = try #require(tab.dialogs.first)
            let veil = try #require(scrim.titlebarVeil)
            let closeButton = try #require(window.standardWindowButton(.closeButton))
            let titlebar = try #require(closeButton.superview)
            #expect(veil.superview === titlebar)
            let order = titlebar.subviews
            let veilIndex = try #require(order.firstIndex { $0 === veil })
            let closeIndex = try #require(order.firstIndex { $0 === closeButton })
            #expect(veilIndex < closeIndex)
            let workspace = try #require(window.contentView as? WorkspaceView)
            let band = workspace.contentColumn.band
            let bandX = titlebar.convert(band.convert(band.bounds, to: nil), from: nil).minX
            #expect(veil.frame.minX == bandX)
            #expect(veil.frame.maxX == titlebar.bounds.maxX)
            #expect(veil.frame.height == titlebar.bounds.height)
            #expect(veil.hitTest(NSPoint(x: veil.frame.midX, y: veil.frame.midY)) === veil)
            // The extra stops where the sidebar does, at the content's edge (233).
            #expect(scrim.sidebarRect?.minX == 0)
            #expect(scrim.sidebarRect?.maxX == bandX)
            scrim.onScrimPress?()
            #expect(veil.superview == nil)
            withExtendedLifetime(box) {}
            await close(harness)
        }

        // The band stays the window's drag region under a dialog (`.window-toolbar` drags; the scrim sets no
        // `no-drag`): a press on its empty room drags the window and never reaches the scrim, so the Go To box stays.
        // Only a press on one of the band's no-drag items (a toolbar button) is a press on the scrim, which closes it.
        // F-843 B-DLG-001
        @Test func aPressOnTheEmptyBandDragsTheWindowAndAButtonInItIsTheScrims() async throws {
            let (harness, tab) = try await open()
            harness.layout(tab)
            let window = try #require(tab.window)
            _ = try openBox(tab)
            let scrim = try #require(tab.dialogs.first)
            let workspace = tab.workspace
            // The band's empty room, above its items.
            let empty = workspace.convert(NSPoint(x: 600, y: 3), to: nil)
            #expect(scrim.titlebarPress(at: empty) == .dragWindow)
            #expect(!WindowEventRouting.intercept(Self.press(at: empty, in: window), in: window))
            #expect(tab.goToBox != nil)
            // The Back button.
            let back = try #require(tab.explorerToolbar.button(.back))
            let onBack = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
            #expect(scrim.titlebarPress(at: onBack) == .scrim)
            #expect(WindowEventRouting.intercept(Self.press(at: onBack, in: window), in: window))
            #expect(tab.goToBox == nil)
            await close(harness)
        }

        // A control of the system's in the band belongs to no item's view: the » button and a folded search's magnifier,
        // stood in for here by a button of the same kind. It is covered as the items are; the title still drags.
        // F-843 B-DLG-001
        @Test func theSystemsOwnControlsInTheBandAreTheScrims() async throws {
            let (harness, tab) = try await open()
            harness.layout(tab)
            let window = try #require(tab.window)
            _ = try openBox(tab)
            let scrim = try #require(tab.dialogs.first)
            let titlebar = try #require(window.standardWindowButton(.closeButton)?.superview)
            let location = tab.workspace.convert(NSPoint(x: 600, y: 3), to: nil)
            #expect(scrim.titlebarPress(at: location) == .dragWindow)
            let inTitlebar = titlebar.convert(location, from: nil)
            let indicator = NSButton(
                frame: NSRect(x: inTitlebar.x - 4, y: inTitlebar.y - 4, width: 8, height: 8))
            titlebar.addSubview(indicator)
            #expect(scrim.titlebarPress(at: location) == .scrim)
            indicator.isHidden = true
            #expect(scrim.titlebarPress(at: location) == .dragWindow)
            indicator.isHidden = false
            let title = try #require(tab.explorerToolbar.titleView)
            let onTitle = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
            #expect(scrim.titlebarPress(at: onTitle) == .dragWindow)
            #expect(WindowEventRouting.intercept(Self.press(at: location, in: window), in: window))
            #expect(tab.goToBox == nil)
            indicator.removeFromSuperview()
            await close(harness)
        }

        private static func press(at location: NSPoint, in window: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
    }
}
