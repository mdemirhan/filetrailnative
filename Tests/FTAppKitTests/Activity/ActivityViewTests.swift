import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct ActivityViewTests {
    static let items = [
        ActivityItem(
            id: "op", kind: .fileOperation, title: "Copying…", detail: "25%", progress: 0.25, isWaiting: false),
        ActivityItem(
            id: "job", kind: .folderSize, title: "Library", detail: "Waiting to calculate its size", progress: nil,
            isWaiting: true),
    ]

    // A row for each, a bar only where how far is known, and Stop for the row's own item.
    @Test func listsEachWithItsBarAndStop() throws {
        let view = ActivityView(items: Self.items)
        var stopped: [String] = []
        view.onStop = { stopped.append($0.id) }
        view.frame = NSRect(origin: .zero, size: view.listSize)
        view.layoutSubtreeIfNeeded()
        let rows = view.subviews.compactMap { $0 as? ActivityRow }
        #expect(rows.map(\.item.id) == ["op", "job"])
        let bars = rows.map { $0.subviews.compactMap { $0 as? NSProgressIndicator }.first }
        #expect(bars.map { $0?.isHidden } == [false, true])
        #expect(bars.first??.doubleValue == 0.25)
        #expect(rows.map(\.stop.toolTip) == ["Stop", "Stop Waiting"])
        rows[1].stop.sendAction(rows[1].stop.action, to: rows[1].stop.target)
        #expect(stopped == ["job"])
        #expect(view.listSize.height > 2 * ActivityView.rowHeight)

        view.update([Self.items[1]])
        #expect(view.subviews.compactMap { $0 as? ActivityRow }.count == 1)
    }

    // The list is told what runs several times a second: a row whose item is still listed stays the view it was,
    // so a press on its Stop under way is not lost with it, and shows what changed.
    @Test func keepsARowWhileItsItemIsListedAndShowsWhatChanged() throws {
        let view = ActivityView(items: Self.items)
        var stopped: [ActivityItem] = []
        view.onStop = { stopped.append($0) }
        let before = view.subviews.compactMap { $0 as? ActivityRow }
        var moved = Self.items
        moved[0].detail = "50%"
        moved[0].progress = 0.5
        moved[1].detail = "Calculating size"
        moved[1].isWaiting = false
        view.update(moved)
        let after = view.subviews.compactMap { $0 as? ActivityRow }
        #expect(after.count == 2 && after[0] === before[0] && after[1] === before[1])
        #expect(after[0].subviews.compactMap { $0 as? NSProgressIndicator }.first?.doubleValue == 0.5)
        #expect(after.map(\.stop.toolTip) == ["Stop", "Stop"])
        #expect(after[1].accessibilityLabel() == "Library, Calculating size")
        // Stop hands over the item as it is now.
        after[1].stop.sendAction(after[1].stop.action, to: after[1].stop.target)
        #expect(stopped == [moved[1]])
    }

    // When a row ends, the ones under it move up under the pointer: for a moment Stop is not taken, so a press aimed
    // at the row that went doesn't stop the next one. A row added at the end moves none.
    @Test func stopIsNotTakenJustAfterARowCameToAnotherPlace() throws {
        let third = ActivityItem(
            id: "job-2", kind: .folderSize, title: "Movies", detail: "Waiting to calculate its size", progress: nil,
            isWaiting: true)
        var time = 100.0
        let view = ActivityView(items: Self.items)
        view.now = { time }
        var stopped: [String] = []
        view.onStop = { stopped.append($0.id) }
        func pressStop(_ index: Int) {
            let row = view.subviews.compactMap { $0 as? ActivityRow }[index]
            row.stop.sendAction(row.stop.action, to: row.stop.target)
        }

        view.update(Self.items + [third])
        pressStop(2)
        #expect(stopped == ["job-2"])

        // The file operation ended: the two sizes moved up a row.
        view.update([Self.items[1], third])
        pressStop(0)
        #expect(stopped == ["job-2"])
        time += ActivityView.settleInterval
        pressStop(0)
        #expect(stopped == ["job-2", "job"])
    }

    // The title's ring: as far round as a file operation has gone, spinning while that isn't known, a pill with the count
    // when others are listed, and gone once nothing runs, with a check when a file operation completed.
    @Test func theTitlesRingShowsHowFarAlongAndHowManyMore() {
        let ring = TitleActivityView()
        ring.reducesMotion = { true }
        var widthChanges = 0
        ring.onWidthChange = { widthChanges += 1 }
        #expect(!ring.isShown && ring.isHidden && ring.preferredWidth == 0)
        #expect(!ring.isAccessibilityElement())

        ring.show(ActivityIndicator(progress: 0.4, isWaiting: false, moreCount: 0))
        ring.frame = NSRect(x: 0, y: 0, width: ring.preferredWidth, height: TitleActivityView.height)
        ring.layout()
        #expect(ring.isShown && !ring.isHidden && ring.alphaValue == 1)
        #expect(ring.preferredWidth == TitleActivityView.ringSize + 2 * TitleActivityView.inset)
        #expect(abs((ring.ringFill ?? 0) - 0.4) < 0.0001 && !ring.spins)
        #expect(ring.countField.isHidden && !ring.pillShown)
        #expect(widthChanges == 1)

        let alone = ring.ringFrame
        ring.show(ActivityIndicator(progress: nil, isWaiting: false, moreCount: 2))
        ring.frame = NSRect(x: 0, y: 0, width: ring.preferredWidth, height: TitleActivityView.height)
        ring.layout()
        #expect(ring.spins && ring.ringFill == nil)
        #expect(!ring.countField.isHidden && ring.countField.stringValue == "+2")
        // Nothing is drawn behind the ring and its count at rest, with one thing running or several.
        #expect(!ring.pillShown)
        #expect(ring.preferredWidth > TitleActivityView.ringSize + 2 * TitleActivityView.inset)
        // The ring keeps its place at the right end as the count comes.
        #expect(ring.ringFrame.maxX == ring.bounds.maxX - TitleActivityView.inset && ring.ringFrame.size == alone.size)
        #expect(widthChanges == 2)

        // A press opens the list.
        var clicks = 0
        ring.onClick = { clicks += 1 }
        #expect(ring.accessibilityPerformPress())
        #expect(clicks == 1)

        ring.show(nil, endedWell: true)
        #expect(ring.showsCheck && ring.isShown && ring.ringFill == nil && !ring.spins)
        ring.show(nil, endedWell: true)
        #expect(ring.showsCheck)

        let quiet = TitleActivityView()
        quiet.reducesMotion = { true }
        quiet.show(ActivityIndicator(progress: nil, isWaiting: true, moreCount: 0))
        quiet.show(nil)
        #expect(!quiet.isShown && quiet.isHidden && !quiet.showsCheck)
    }

    // The title gives the ring the end of its room and cuts its name short before it; a press on the ring is the
    // ring's, and one on the name drags the window.
    @Test func theTitleMakesRoomForTheRing() {
        let title = ToolbarTitleView(frame: NSRect(x: 0, y: 0, width: 300, height: ToolbarTitleView.height))
        title.activity.reducesMotion = { true }
        title.field.stringValue = "Documents"
        title.layout()
        let wide = title.field.frame.width
        #expect(title.activity.frame.width == 0)
        title.activity.show(ActivityIndicator(progress: 0.5, isWaiting: false, moreCount: 1))
        title.layout()
        let ring = title.activity.frame
        #expect(abs(ring.width - title.activity.preferredWidth) < 0.01)
        #expect(abs(ring.maxX - (300 - DesignTokens.toolbar.titlePaddingTrailing)) < 0.01)
        #expect(title.field.frame.maxX <= ring.minX - ToolbarTitleView.activityGap + 0.5)
        #expect(title.field.frame.width < wide)
        #expect(title.hitTest(NSPoint(x: ring.midX, y: ring.midY)) === title.activity)
        #expect(title.hitTest(NSPoint(x: 20, y: title.bounds.midY)) === title)
        title.activity.show(nil)
        title.layout()
        #expect(title.activity.frame.width == 0 && title.field.frame.width == wide)
    }
}
