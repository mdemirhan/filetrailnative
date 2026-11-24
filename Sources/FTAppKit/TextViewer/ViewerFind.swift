import AppKit
import WebKit

/// What the find bar over a file that isn't text finds in: a PDF's pages, or the page Quick Look shows a document in.
/// Both look without regard to case or accents, mark every match, and show the first as it is found.
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

/// Finds in the page Quick Look shows a Word document, a spreadsheet or a web archive in, by a script of the app's own
/// run in the page. Every match is marked with the page's highlights, which leave its text and layout as they are, the
/// one shown more strongly, and brought into view. Text that is hidden (another sheet of a spreadsheet) isn't looked in,
/// and a match may run across a change of style in a paragraph but not from one paragraph to the next. Quick Look's
/// web view is its own: without one, nothing is found.
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
        run(["action": "find", "query": text, "colors": Self.colors])
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
        Task {
            _ = try? await webView.callAsyncJavaScript(Self.script, arguments: ["action": "stop"], contentWorld: .page)
        }
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
            let result = try? await webView.callAsyncJavaScript(Self.script, arguments: arguments, contentWorld: .page)
            guard let self, number == self.generation else { return }
            let answer = result as? [String: Any]
            self.matchCount = (answer?["count"] as? NSNumber)?.intValue ?? 0
            let index = (answer?["index"] as? NSNumber)?.intValue ?? -1
            self.matchIndex = index >= 0 ? index : nil
            self.isFinding = false
            self.onFindChange()
        }
    }

    /// The marks' colors, as CSS: every match in the system's find color, lightly, and the one shown in it fully.
    private static var colors: [String] {
        let color = NSColor.findHighlightColor.usingColorSpace(.sRGB) ?? .systemYellow
        func css(_ alpha: CGFloat) -> String {
            "rgba(\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), "
                + "\(Int(color.blueComponent * 255)), \(alpha))"
        }
        return [css(0.4), css(1)]
    }

    /// The script, the body of an async function with `action` and the rest of the request as its arguments. It sets
    /// up the find once per page and waits for a page still loading, up to three seconds.
    static let script = """
        if (!window.__fileTrailFind) {
          const fold = (s) => s.normalize('NFD').replace(/\\p{M}+/gu, '').toLowerCase();
          const blocks = 'p,li,td,th,tr,div,h1,h2,h3,h4,h5,h6,dt,dd,pre,blockquote,section,article,table,body';
          let ranges = [];
          let index = -1;
          const style = (colors) => {
            let sheet = document.getElementById('__fileTrailFindStyle');
            if (!sheet) {
              sheet = document.createElement('style');
              sheet.id = '__fileTrailFindStyle';
              (document.head || document.documentElement).appendChild(sheet);
            }
            sheet.textContent = `::highlight(file-trail-find) { background-color: ${colors[0]}; }
              ::highlight(file-trail-find-shown) { background-color: ${colors[1]}; }`;
          };
          const visible = (node) => {
            const element = node.parentElement;
            if (!element || element.closest('script,style,noscript,template')) return false;
            return element.getClientRects().length > 0;
          };
          // The match shown, in the scrolling parts of the page around it and then the page itself.
          const reveal = (range) => {
            for (let element = range.startContainer.parentElement; element && element !== document.body
                 && element !== document.documentElement; element = element.parentElement) {
              const scrolls = getComputedStyle(element);
              if (!/(auto|scroll)/.test(scrolls.overflowX + scrolls.overflowY)) continue;
              const shown = range.getBoundingClientRect(), box = element.getBoundingClientRect();
              if (shown.top < box.top || shown.bottom > box.bottom) {
                element.scrollTop += shown.top - box.top - element.clientHeight / 3;
              }
              if (shown.left < box.left || shown.right > box.right) {
                element.scrollLeft += shown.left - box.left - element.clientWidth / 3;
              }
            }
            const shown = range.getBoundingClientRect();
            const height = window.visualViewport ? visualViewport.height : innerHeight;
            const width = window.visualViewport ? visualViewport.width : innerWidth;
            if (shown.top < 0 || shown.bottom > height) {
              window.scrollBy({ top: shown.top - height / 3, behavior: 'instant' });
            }
            if (shown.left < 0 || shown.right > width) {
              window.scrollBy({ left: shown.left - width / 3, behavior: 'instant' });
            }
          };
          const answer = () => {
            if (ranges.length) {
              CSS.highlights.set('file-trail-find', new Highlight(...ranges));
            } else {
              CSS.highlights.delete('file-trail-find');
            }
            if (index >= 0) {
              const shown = new Highlight(ranges[index]);
              shown.priority = 1;
              CSS.highlights.set('file-trail-find-shown', shown);
              reveal(ranges[index]);
            } else {
              CSS.highlights.delete('file-trail-find-shown');
            }
            return { count: ranges.length, index };
          };
          window.__fileTrailFind = {
            find(query, colors) {
              style(colors);
              ranges = [];
              index = -1;
              const needle = fold(query);
              const nodes = [], folded = [], node = [], start = [], end = [];
              const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
              let block;
              for (let each = walker.nextNode(); each; each = walker.nextNode()) {
                if (!each.data || !visible(each)) continue;
                const its = each.parentElement.closest(blocks);
                if (nodes.length && its !== block) {
                  folded.push('\\n');
                  node.push(-1); start.push(0); end.push(0);
                }
                block = its;
                const number = nodes.push(each) - 1;
                let offset = 0;
                for (const character of each.data) {
                  const code = character.charCodeAt(0);
                  const text = code < 128 ? character.toLowerCase() : fold(character);
                  for (let unit = 0; unit < text.length; unit++) {
                    node.push(number); start.push(offset); end.push(offset + character.length);
                  }
                  folded.push(text);
                  offset += character.length;
                }
              }
              const text = folded.join('');
              for (let at = needle ? text.indexOf(needle) : -1; at >= 0; at = text.indexOf(needle, at + needle.length)) {
                const last = at + needle.length - 1;
                if (node[at] < 0 || node[last] < 0) continue;
                const range = document.createRange();
                range.setStart(nodes[node[at]], start[at]);
                range.setEnd(nodes[node[last]], end[last]);
                ranges.push(range);
              }
              index = ranges.length ? 0 : -1;
              return answer();
            },
            step(forward) {
              if (!ranges.length) return answer();
              index = index < 0 ? 0 : (index + (forward ? 1 : -1) + ranges.length) % ranges.length;
              return answer();
            },
            stop() {
              ranges = [];
              index = -1;
              return answer();
            },
          };
        }
        if (document.readyState !== 'complete') {
          await Promise.race([
            new Promise((done) => addEventListener('load', done, { once: true })),
            new Promise((done) => setTimeout(done, 3000)),
          ]);
        }
        const find = window.__fileTrailFind;
        switch (action) {
          case 'find': return find.find(query, colors);
          case 'step': return find.step(forward);
          default: return find.stop();
        }
        """
}
