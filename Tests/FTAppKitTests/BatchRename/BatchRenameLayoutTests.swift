// The Rename sheet's metrics (apps/desktop/src/renderer/styles.css 6696-7170), laid out on a window that is never shown
// and compared with BatchRenameSheetLayout, as the original's CSS places each part
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct BatchRenameLayoutTests {
        private typealias Layout = BatchRenameSheetLayout

        private func frame(_ view: NSView, in sheet: NSView) -> NSRect {
            view.convert(view.bounds, to: sheet)
        }

        // F-873 F-874 F-878 F-879: 680 wide and 60 below the window's top; the header, the centered mode control, the
        // grid's 112 / 1fr / 132 / 1fr columns, the preview's header and rows, and the footer.
        @Test func laysTheSheetOutAsTheStylesheetDoes() async throws {
            let fixture = await BatchRenameSheetFixture([
                BatchRenameSheetFixture.target("IMG_1.jpg"), BatchRenameSheetFixture.target("IMG_2.jpg"),
            ])
            let sheet = fixture.sheet
            let width = CGFloat(Layout.width)
            #expect(sheet.frame.width == width)
            #expect(sheet.frame.minX == (1200 - width) / 2)
            #expect(sheet.frame.minY == CGFloat(DialogLayout.sheetTop))
            let control = CGFloat(Layout.controlHeight)
            // Header: `padding: 20px 20px 14px`, the pull-down at least 120 wide on the right.
            let presets = frame(sheet.presetsPopUp, in: sheet)
            #expect(presets.maxX == width - CGFloat(Layout.Header.paddingHorizontal))
            #expect(presets.minY == CGFloat(Layout.Header.paddingTop))
            #expect(presets.height == control)
            #expect(presets.width >= CGFloat(Layout.Header.presetsMinWidth))
            #expect(frame(sheet.titleLabel, in: sheet).minX == CGFloat(Layout.Header.paddingHorizontal))
            #expect(sheet.titleLabel.font?.pointSize == CGFloat(Layout.Fonts.body))
            // Modes: centered, 28 tall (2 around 24 segments), 14 above the options.
            let headerHeight = CGFloat(Layout.Header.paddingTop + Layout.controlHeight + Layout.Header.paddingBottom)
            let modes = frame(sheet.modeControl, in: sheet)
            #expect(modes.minY == headerHeight)
            #expect(modes.height == control + CGFloat(2 * Layout.Modes.trackPadding))
            #expect(abs(modes.midX - width / 2) <= 0.5)
            for segment in sheet.modeControl.segments {
                #expect(segment.frame.height == control)
                #expect(
                    abs(
                        segment.frame.width - segment.label.exactWidth - CGFloat(2 * Layout.Modes.segmentPadding))
                        < 0.5)
            }
            // The grid: Find | field | Replace with | field.
            let optionsTop = modes.maxY + CGFloat(Layout.Modes.paddingBottom)
            let left = CGFloat(Layout.Options.paddingHorizontal)
            let columns = Layout.Grid.columns(width: Double(width) - 2 * Layout.Options.paddingHorizontal)
            let find = try #require(sheet.labels["Find"])
            #expect(frame(find, in: sheet) == NSRect(x: left, y: optionsTop, width: 112, height: control))
            #expect(find.alignment == .right || find.attributedStringValue.length > 0)
            #expect(
                frame(sheet.findField, in: sheet)
                    == NSRect(
                        x: left + CGFloat(columns[1].x), y: optionsTop, width: CGFloat(columns[1].width),
                        height: control))
            let second = try #require(sheet.labels["Replace with"])
            #expect(
                frame(second, in: sheet)
                    == NSRect(
                        x: left + CGFloat(columns[2].x + Layout.Grid.secondLabelMargin), y: optionsTop,
                        width: CGFloat(Layout.Grid.secondLabelWidth - Layout.Grid.secondLabelMargin), height: control))
            #expect(frame(sheet.replaceField, in: sheet).minX == left + CGFloat(columns[3].x))
            #expect(frame(sheet.replaceField, in: sheet).maxX == width - left)
            // The checkboxes' row, 8 below; the common grid 10 below the mode's.
            let checksTop = optionsTop + control + CGFloat(Layout.Grid.gap)
            let checkLine = batchRenameLine(Layout.Fonts.body)
            #expect(frame(sheet.matchCaseCheck, in: sheet).minY == checksTop)
            #expect(frame(sheet.matchCaseCheck, in: sheet).minX == left + CGFloat(columns[1].x))
            #expect(
                frame(sheet.regexCheck, in: sheet).minX
                    == frame(sheet.matchCaseCheck, in: sheet).maxX + CGFloat(Layout.Check.columnGap))
            let commonTop = checksTop + checkLine + CGFloat(Layout.Options.gap)
            #expect(frame(sheet.applyToPopUp, in: sheet).minY == commonTop)
            #expect(frame(sheet.onConflictPopUp, in: sheet).maxX == width - left)
            // The preview: 20 in, its header 22, rows 26.
            let previewTop = commonTop + control + CGFloat(Layout.Options.paddingBottom)
            let preview = frame(sheet.preview, in: sheet)
            #expect(preview.minX == CGFloat(Layout.Preview.marginHorizontal))
            #expect(preview.minY == previewTop)
            #expect(preview.width == width - 2 * CGFloat(Layout.Preview.marginHorizontal))
            #expect(sheet.preview.head.frame.height == CGFloat(Layout.Preview.headHeight))
            #expect(sheet.preview.rowHeights(width: preview.width) == [26, 26])
            #expect(preview.height == CGFloat(Layout.Preview.headHeight + 2 * Layout.Preview.rowMinHeight))
            let cell = try #require(fixture.cell(0))
            cell.frame = NSRect(x: 0, y: 0, width: preview.width, height: 26)
            cell.layoutSubtreeIfNeeded()
            let rowColumns = Layout.Preview.columns(width: Double(preview.width))
            #expect(cell.glyph.frame == NSRect(x: 12, y: 5, width: 16, height: 16))
            #expect(cell.oldLabel.frame.minX == CGFloat(rowColumns[1].x))
            #expect(cell.arrow.frame.size == NSSize(width: 12, height: 12))
            #expect(cell.arrow.frame.minX == CGFloat(rowColumns[2].x))
            #expect(cell.newColumn.frame.minX == CGFloat(rowColumns[3].x))
            #expect(abs(cell.newColumn.frame.maxX - (preview.width - CGFloat(Layout.Preview.paddingHorizontal))) < 0.5)
            #expect(abs(CGFloat(rowColumns[3].width) / CGFloat(rowColumns[1].width) - 1.25) < 0.001)
            // The footer: a 1 pt line, 12 above the buttons and 16 under them; Rename on the right, 8 from Cancel.
            let footerTop = preview.maxY
            let rename = frame(sheet.renameButton, in: sheet)
            let cancel = frame(sheet.cancelButton, in: sheet)
            #expect(rename.minY == footerTop + CGFloat(Layout.Footer.border + Layout.Footer.paddingTop))
            #expect(rename.maxX == width - CGFloat(Layout.Footer.paddingHorizontal))
            #expect(cancel.maxX == rename.minX - CGFloat(Layout.Footer.gap))
            #expect(sheet.frame.height == footerTop + CGFloat(Layout.Footer.height))
            #expect(sheet.summaryLabel.font?.pointSize == CGFloat(Layout.Fonts.summary))
            fixture.close()
        }

        // F-873: naming a preset puts a 180 wide field, Cancel and Save where the pull-down was.
        @Test func namingAPresetShowsTheFieldAndItsButtonsInTheHeader() async throws {
            let fixture = await BatchRenameSheetFixture([BatchRenameSheetFixture.target("a.jpg")])
            fixture.pick(fixture.sheet.presetsPopUp, "Save as Preset\u{2026}")
            let sheet = fixture.sheet
            let width = sheet.bounds.width
            let save = frame(sheet.presetSaveButton, in: sheet)
            let cancel = frame(sheet.presetCancelButton, in: sheet)
            let field = frame(sheet.presetNameField, in: sheet)
            #expect(save.maxX == width - CGFloat(Layout.Header.paddingHorizontal))
            #expect(cancel.maxX == save.minX - CGFloat(Layout.Header.presetSaveGap))
            #expect(field.maxX == cancel.minX - CGFloat(Layout.Header.presetSaveGap))
            #expect(field.width == CGFloat(Layout.Header.presetFieldWidth))
            #expect(field.minY == CGFloat(Layout.Header.paddingTop))
            fixture.close()
        }

        // F-876: Format by a custom date pattern: the pattern field, the tokens 20 tall under it, and the example.
        @Test func laysTheDatePatternAndItsTokensOut() async throws {
            let fixture = await BatchRenameSheetFixture([BatchRenameSheetFixture.target("a.jpg")]) {
                $0.mode = .format
                $0.nameFormat = .date
                $0.dateFormat = .custom
            }
            let sheet = fixture.sheet
            let pattern = frame(sheet.patternField, in: sheet)
            let token = frame(sheet.tokenButtons[0], in: sheet)
            #expect(token.height == CGFloat(Layout.Tokens.height))
            #expect(token.minY == pattern.maxY + CGFloat(Layout.Tokens.patternGap))
            #expect(
                frame(sheet.tokenButtons[1], in: sheet).minX == token.maxX + CGFloat(Layout.Tokens.gap))
            #expect(frame(sheet.insertNote, in: sheet).minX == pattern.minX)
            #expect(frame(sheet.exampleNote, in: sheet).minY > token.maxY)
            #expect(sheet.tokenButtons[0].font?.pointSize == CGFloat(Layout.Fonts.small))
            fixture.close()
        }
    }
}
