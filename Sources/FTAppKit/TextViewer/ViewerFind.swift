import AppKit
import WebKit

/// What the find bar over a file finds in, where the system's find bar over the text doesn't: a PDF's pages, the page
/// Quick Look shows a document in, the text it shows one in, or Markdown's Preview. Each looks without regard to case or
/// accents, marks every match, and shows the first as it is found.
@MainActor
protocol ViewerFinding: AnyObject {
    var matchCount: Int { get }
    /// The match shown, from 0.
    var matchIndex: Int? { get }
    /// Still looking: no count to give yet.
    var isFinding: Bool { get }
    /// The matches or the one shown changed.
    var onFindChange: () -> Void { get set }
    /// Looks for `text`; empty stops.
    func find(_ text: String)
    /// The next match, or the one before; it goes round at the ends. Beeps with none.
    func stepMatch(forward: Bool)
    /// The marks go.
    func stopFinding()
}

extension ViewerPDFView: ViewerFinding {
    var matchCount: Int { matches.count }
}

/// The marks' colors: every match in the system's find color, lightly, and the one shown in it fully.
enum FindColors {
    static var all: NSColor { NSColor.findHighlightColor.withAlphaComponent(0.4) }
    static var shown: NSColor { NSColor.findHighlightColor }

    /// As CSS, for a page.
    static var css: [String] {
        let color = NSColor.findHighlightColor.usingColorSpace(.sRGB) ?? .systemYellow
        func css(_ alpha: CGFloat) -> String {
            "rgba(\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), "
                + "\(Int(color.blueComponent * 255)), \(alpha))"
        }
        return [css(0.4), css(1)]
    }
}

/// Finds in a text view the viewer shows but doesn't edit: Markdown's Preview, or the text Quick Look shows an
/// OpenDocument text, an RTF or an RTFD file in. The marks are drawn over the text, never put in it.
@MainActor
final class TextViewFind: ViewerFinding {
    private let textView: () -> NSTextView?
    private var ranges: [NSRange] = []
    private(set) var matchIndex: Int?
    var matchCount: Int { ranges.count }
    let isFinding = false
    var onFindChange: () -> Void = {}
    /// The view the marks are in, to take them out of even once another is shown.
    private weak var marked: NSTextView?

    init(textView: @escaping () -> NSTextView?) {
        self.textView = textView
    }

    func find(_ text: String) {
        stopFinding()
        guard !text.isEmpty, let view = textView() else {
            onFindChange()
            return
        }
        let string = view.string as NSString
        var rest = NSRange(location: 0, length: string.length)
        while rest.length > 0 {
            let found = string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            rest = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
        marked = view
        matchIndex = ranges.isEmpty ? nil : 0
        mark()
        onFindChange()
    }

    func stepMatch(forward: Bool) {
        guard !ranges.isEmpty else {
            NSSound.beep()
            return
        }
        matchIndex = matchIndex.map { ($0 + (forward ? 1 : -1) + ranges.count) % ranges.count } ?? 0
        mark()
        onFindChange()
    }

    func stopFinding() {
        if let marked { paint(marked, ranges, nil) }
        marked = nil
        ranges = []
        matchIndex = nil
    }

    private func mark() {
        guard let view = marked else { return }
        let shown = matchIndex.map { ranges[$0] }
        paint(view, ranges, FindColors.all)
        if let shown {
            paint(view, [shown], FindColors.shown)
            view.scrollRangeToVisible(shown)
            view.showFindIndicator(for: shown)
        }
    }

    /// Draws `color` behind `ranges`, or takes it away (nil). A view of the newer text system is never asked for its
    /// layout manager, which would turn it into one of the older.
    private func paint(_ view: NSTextView, _ ranges: [NSRange], _ color: NSColor?) {
        if let layout = view.textLayoutManager, let content = layout.textContentManager {
            for range in ranges {
                guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                    let end = content.location(start, offsetBy: range.length),
                    let textRange = NSTextRange(location: start, end: end)
                else { continue }
                if let color {
                    layout.setRenderingAttributes([.backgroundColor: color], for: textRange)
                } else {
                    layout.removeRenderingAttribute(.backgroundColor, for: textRange)
                }
            }
        } else if let layout = view.layoutManager {
            for range in ranges {
                if let color {
                    layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                } else {
                    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                }
            }
        }
    }
}

/// Finds in the page Quick Look shows a Word document, a spreadsheet or a web archive in, by the app's script in the
/// page (`QuickLookPageScript`), and in the frames in it, where Quick Look shows a spreadsheet's sheet. Every match is
/// marked with the page's highlights, which leave its text and layout as they are, the one shown more strongly, and
/// brought into view. Text the page hides isn't looked in, and a match may run across a change of style in a paragraph
/// but not from one paragraph to the next. Quick Look's web view is its own: without one, nothing is found.
@MainActor
final class WebPageFind: ViewerFinding {
    private let webView: () -> WKWebView?
    private(set) var matchCount = 0
    private(set) var matchIndex: Int?
    private(set) var isFinding = false
    var onFindChange: () -> Void = {}
    /// Each request's number: the answer to one asked before the last is left alone.
    private var generation = 0

    init(webView: @escaping () -> WKWebView?) {
        self.webView = webView
    }

    func find(_ text: String) {
        stopFinding()
        guard !text.isEmpty else {
            onFindChange()
            return
        }
        run(["action": "find", "query": text, "colors": FindColors.css])
    }

    func stepMatch(forward: Bool) {
        guard matchCount > 0 else {
            NSSound.beep()
            return
        }
        run(["action": "step", "forward": forward])
    }

    func stopFinding() {
        generation += 1
        matchCount = 0
        matchIndex = nil
        isFinding = false
        guard let webView = webView() else { return }
        Task { _ = try? await QuickLookPageScript.call(webView, ["action": "stop"]) }
    }

    private func run(_ arguments: [String: Any]) {
        generation += 1
        let number = generation
        guard let webView = webView() else {
            isFinding = false
            onFindChange()
            return
        }
        isFinding = true
        onFindChange()
        Task { [weak self] in
            let answer = try? await QuickLookPageScript.call(webView, arguments)
            guard let self, number == self.generation else { return }
            self.matchCount = (answer?["count"] as? NSNumber)?.intValue ?? 0
            let index = (answer?["index"] as? NSNumber)?.intValue ?? -1
            self.matchIndex = index >= 0 ? index : nil
            self.isFinding = false
            self.onFindChange()
        }
    }
}
