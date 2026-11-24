import WebKit

/// The app's script in the page Quick Look shows a document in. It finds, in the page and in the frames in it (where
/// Quick Look shows a spreadsheet's sheet, from an origin of its own the page can't reach into), and steps the pages or
/// slides of a document Quick Look shows as one picture after another (Keynote, Pages).
///
/// The script is put in every frame the page loads (a user script of the web view's), and a frame answers the page by
/// messages; a frame loaded before it was put there is loaded again, once, the first time it is looked in.
@MainActor
enum QuickLookPageScript {
    /// The name the page tells the app the page or slide shown by, as it scrolls.
    static let pagesMessage = "fileTrailPages"

    /// Puts the script in the frames the page loads from now on, once per web view.
    static func install(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == engine }) else { return }
        controller.addUserScript(
            WKUserScript(source: engine, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
    }

    /// Runs one request in the page: `action` (find, step, stop, pages, goToPage) and what it takes.
    static func call(_ webView: WKWebView, _ arguments: [String: Any]) async throws -> [String: Any]? {
        install(in: webView)
        let result = try await webView.callAsyncJavaScript(
            engine + "\n" + request, arguments: arguments, contentWorld: .page)
        return result as? [String: Any]
    }

    /// Finding and the pages, set up once in each frame.
    static let engine = """
        (() => {
          if (window.__fileTrail) return;
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
          const mark = () => {
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
          };
          const find = (query, colors) => {
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
                const text = character.charCodeAt(0) < 128 ? character.toLowerCase() : fold(character);
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
            mark();
            return ranges.length;
          };
          const show = (shown) => {
            index = shown >= 0 && shown < ranges.length ? shown : -1;
            mark();
          };
          const stop = () => {
            ranges = [];
            index = -1;
            mark();
          };
          // A frame answers the page it is in.
          if (window !== window.top) {
            addEventListener('message', (event) => {
              const request = event.data && event.data.fileTrailFind;
              if (!request || event.source !== window.parent) return;
              let count = 0;
              if (request.action === 'find') {
                count = find(request.query, request.colors);
              } else if (request.action === 'show') {
                show(request.index);
              } else {
                stop();
              }
              window.parent.postMessage({ fileTrailFound: { id: request.id, count } }, '*');
            });
          }
          // A document Quick Look shows as one picture after another: each child of the page holds a picture and no
          // text. The page shown is the last one whose top is above a third of the way down.
          const pageElements = () => {
            const children = Array.from(document.body ? document.body.children : [])
              .filter((child) => !/^(SCRIPT|STYLE|LINK|META)$/.test(child.tagName));
            const pictures = children.length && children.every(
              (child) => (child.tagName === 'IMG' || child.querySelector('img')) && !child.innerText.trim());
            return pictures ? children : [];
          };
          const currentPage = (pages) => {
            let current = 0;
            pages.forEach((page, number) => {
              if (page.getBoundingClientRect().top <= innerHeight / 3) current = number;
            });
            return current;
          };
          let watching = false;
          const watchPages = () => {
            const pages = pageElements();
            const handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.fileTrailPages;
            if (pages.length && handler && !watching) {
              watching = true;
              let last = -1, queued = false;
              addEventListener('scroll', () => {
                if (queued) return;
                queued = true;
                requestAnimationFrame(() => {
                  queued = false;
                  const now = currentPage(pageElements());
                  if (now !== last) {
                    last = now;
                    handler.postMessage(now);
                  }
                });
              }, { passive: true });
            }
            return { count: pages.length, current: pages.length ? currentPage(pages) : 0 };
          };
          const goToPage = (number) => {
            const page = pageElements()[number];
            if (!page) return false;
            window.scrollBy({ top: page.getBoundingClientRect().top, behavior: 'instant' });
            return true;
          };
          window.__fileTrail = { find, show, stop, watchPages, goToPage, parts: [], index: -1, asked: 0 };
        })();
        """

    /// One request in the page, the body of an async function with `action` and what it takes as its arguments.
    static let request = """
        const page = window.__fileTrail;
        const frames = () => Array.from(document.querySelectorAll('iframe'))
          .filter((frame) => frame.contentWindow && frame.getClientRects().length > 0);
        const ask = (frame, message, wait) => new Promise((done) => {
          if (!frame.contentWindow) {
            done(null);
            return;
          }
          const id = ++page.asked;
          const answer = (event) => {
            const found = event.data && event.data.fileTrailFound;
            if (!found || found.id !== id) return;
            removeEventListener('message', answer);
            done(found);
          };
          addEventListener('message', answer);
          frame.contentWindow.postMessage({ fileTrailFind: Object.assign({}, message, { id }) }, '*');
          setTimeout(() => {
            removeEventListener('message', answer);
            done(null);
          }, wait);
        });
        // A frame loaded before the script was put in every frame has none: it is loaded again.
        const reload = (frame) => new Promise((done) => {
          if (!frame.src) {
            done();
            return;
          }
          frame.addEventListener('load', () => done(), { once: true });
          frame.src = frame.src;
          setTimeout(done, 3000);
        });
        const show = async () => {
          let first = 0;
          for (const part of page.parts) {
            const here = page.index >= first && page.index < first + part.count ? page.index - first : -1;
            if (part.frame) {
              await ask(part.frame, { action: 'show', index: here }, 1000);
              if (here >= 0) part.frame.scrollIntoView({ block: 'nearest', inline: 'nearest' });
            } else {
              page.show(here);
            }
            first += part.count;
          }
        };
        const total = () => page.parts.reduce((sum, part) => sum + part.count, 0);
        switch (action) {
          case 'find': {
            if (document.readyState !== 'complete') {
              await Promise.race([
                new Promise((done) => addEventListener('load', done, { once: true })),
                new Promise((done) => setTimeout(done, 3000)),
              ]);
            }
            page.parts = [{ frame: null, count: page.find(query, colors) }];
            for (const frame of frames()) {
              let found = await ask(frame, { action: 'find', query, colors }, 1000);
              if (!found) {
                await reload(frame);
                found = await ask(frame, { action: 'find', query, colors }, 1500);
              }
              page.parts.push({ frame, count: found ? found.count : 0 });
            }
            page.index = total() ? 0 : -1;
            await show();
            return { count: total(), index: page.index };
          }
          case 'step': {
            const count = total();
            if (count) page.index = page.index < 0 ? 0 : (page.index + (forward ? 1 : -1) + count) % count;
            await show();
            return { count, index: page.index };
          }
          case 'pages':
            return page.watchPages();
          case 'goToPage':
            return { done: page.goToPage(number) };
          default: {
            page.stop();
            for (const part of page.parts) {
              if (part.frame) ask(part.frame, { action: 'stop' }, 500);
            }
            page.parts = [];
            page.index = -1;
            return { count: 0, index: -1 };
          }
        }
        """
}
