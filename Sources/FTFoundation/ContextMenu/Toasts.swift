// Port of apps/desktop/src/renderer/lib/toasts.ts
import Foundation

/// Notifications carry information only: something finished ("success") or something worth knowing happened ("info").
/// They go away by themselves and can be turned off, so nothing the user must see may depend on them. An action that
/// failed, or only partly worked, is reported in a modal dialog instead, which is why there is no error kind; a
/// command with nothing to act on is greyed out, so there is no warning kind either.
public enum ToastKind: String, Sendable, Equatable {
    case success, info
}

public struct ToastEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ToastKind
    public var title: String
    public var message: String?
    public var durationMs: Double
    /// When it goes, in milliseconds since the reference date.
    public var expiresAt: Double
}

public enum Toasts {
    /// How long a notification stays: long enough to read a line and a name.
    public static let durationMs = 4000.0
    /// How many show at once.
    public static let maxVisible = 3

    /// `createToastEntry`. An empty message is none.
    public static func entry(
        id: String, kind: ToastKind, title: String, message: String? = nil, now: Double
    ) -> ToastEntry {
        ToastEntry(
            id: id, kind: kind, title: title, message: (message?.isEmpty ?? true) ? nil : message,
            durationMs: durationMs, expiresAt: now + durationMs)
    }

    /// `enqueueToast`: the newest `maxVisible` stay.
    public static func enqueue(_ current: [ToastEntry], _ next: ToastEntry, maxVisible: Int = maxVisible)
        -> [ToastEntry]
    {
        Array((current + [next]).suffix(maxVisible))
    }
}

/// How the bottom right of the window is stacked (`lib/bottomStack.ts`): a running operation's card rests above the
/// path bar and the Info Row, and notifications above the card when there is one.
public enum BottomStack {
    /// The gap above a bar.
    public static let gapAbove = 10.0
    /// The gap between the card and the notifications above it.
    public static let gapBetween = 8.0
    /// Where nothing is at the bottom of the window (search results, Help).
    public static let edgeOffset = 12.0

    /// `offsetAboveBars`: `barTops` are the tops of the bars on screen, measured from the window's top, in a window
    /// `windowHeight` tall.
    public static func offsetAboveBars(windowHeight: Double, barTops: [Double]) -> Double {
        guard let top = barTops.min() else { return edgeOffset }
        return max(edgeOffset, (windowHeight - top + gapAbove).rounded())
    }

    /// `offsetAboveBarsAndCard`.
    public static func offsetAboveBarsAndCard(
        windowHeight: Double, barTops: [Double], cardHeight: Double?
    ) -> Double {
        let bars = offsetAboveBars(windowHeight: windowHeight, barTops: barTops)
        guard let cardHeight else { return bars }
        return bars + cardHeight + gapBetween
    }
}

/// How long an operation runs before its progress card shows (`lib/progressCardDelay.ts`), and the other delays before
/// something shows (ui.md §9).
public enum ShowDelays {
    public static let progressCardMs = 500.0
    public static let loadingFolderMs = 400.0
    public static let loadingTreeMs = 400.0
    public static let pathBarMenuMs = 300.0
    public static let spinnerMs = 300.0
    public static let searchStopMs = 400.0
}
