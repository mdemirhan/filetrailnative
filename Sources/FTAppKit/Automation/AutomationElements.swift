// Port of the element lookup of tools/capture/electron/driver.ts (elements.json names); no TypeScript source.
#if DEBUG
    import AppKit

    /// The logical element names of `tools/capture/elements.json`, mapped to this app's
    /// `accessibilityIdentifier`s.
    struct AutomationElements: Equatable, Sendable {
        /// Logical name → accessibility identifier.
        var identifiers: [String: String]

        struct LoadError: Error, CustomStringConvertible {
            let description: String
        }

        static func parse(_ data: Data) throws -> AutomationElements {
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let elements = top["elements"] as? [String: Any]
            else { throw LoadError(description: "elements.json has no \"elements\" object") }
            var identifiers: [String: String] = [:]
            for (name, raw) in elements {
                guard let spec = raw as? [String: Any], let swift = spec["swift"] as? String else {
                    throw LoadError(description: "elements.json: \"\(name)\" has no \"swift\" identifier")
                }
                identifiers[name] = swift
            }
            return AutomationElements(identifiers: identifiers)
        }

        /// `file`, with the names each work package keeps in `elements.d/*.json` beside it, as `run.sh` merges them.
        static func load(_ file: URL) throws -> AutomationElements {
            var merged = try parse(Data(contentsOf: file))
            let folder = file.deletingLastPathComponent().appendingPathComponent("elements.d")
            let extras =
                (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for extra in extras.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
                let more = try parse(Data(contentsOf: extra))
                merged.identifiers.merge(more.identifiers) { first, _ in first }
            }
            return merged
        }

        /// `elements.json` next to the scenarios: the scenario's folder or one of the folders above it.
        static func locate(near scenario: URL) -> URL? {
            var folder = scenario.deletingLastPathComponent()
            for _ in 0..<4 {
                let candidate = folder.appendingPathComponent("elements.json")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                folder.deleteLastPathComponent()
            }
            return nil
        }
    }

    /// Finds the views a scenario names, in a window, its sheet and its child windows.
    @MainActor
    enum ElementFinder {
        struct Match {
            var view: NSView
            var frame: GeometryDump.Frame
        }

        /// The windows a step looks in: the window, the sheet on it, its child windows (popovers) and an
        /// app-modal panel.
        static func windows(around window: NSWindow) -> [NSWindow] {
            var found: [NSWindow] = [window]
            if let sheet = window.attachedSheet { found.append(sheet) }
            found += window.childWindows ?? []
            if let modal = NSApp.modalWindow { found.append(modal) }
            var seen = Set<ObjectIdentifier>()
            return found.filter { seen.insert(ObjectIdentifier($0)).inserted && $0.isVisible }
        }

        /// Every visible view with `identifier`, top to bottom then left to right, narrowed by `text`.
        /// With `clipped`, views scrolled out of their scroll view are included too.
        static func all(identifier: String, text: String?, in window: NSWindow, clipped: Bool = false) -> [Match] {
            var matches: [Match] = []
            for candidate in windows(around: window) {
                guard let root = candidate.contentView?.superview ?? candidate.contentView else { continue }
                AutomationTags.apply(in: candidate)
                let size = candidate.contentView?.bounds.size ?? .zero
                for view in Views.all(NSView.self, in: root) where view.accessibilityIdentifier() == identifier {
                    let frame = GeometryDump.frame(of: view, in: candidate)
                    guard frame.width > 0 || frame.height > 0 else { continue }
                    if !clipped {
                        // On screen: its center is in the window (a step acts at the center).
                        let x = frame.x + frame.width / 2
                        let y = frame.y + frame.height / 2
                        guard !view.visibleRect.isEmpty, x >= 0, y >= 0, x < size.width, y < size.height else {
                            continue
                        }
                    }
                    if let text, !shows(text, view) { continue }
                    matches.append(Match(view: view, frame: frame))
                }
            }
            return matches.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        }

        /// The view `ref` names, or why there is none. One scrolled out of its list is scrolled into view
        /// first, as a person would, and the matches on screen are counted again.
        static func find(
            _ ref: Scenario.ElementRef, elements: AutomationElements?, in window: NSWindow
        ) -> Result<Match, AutomationRunner.Failure> {
            guard let elements else { return .failure(.init("no elements.json")) }
            guard let identifier = elements.identifiers[ref.name] else {
                return .failure(.init("unknown element \"\(ref.name)\""))
            }
            let index = ref.index ?? 0
            var matches = all(identifier: identifier, text: ref.text, in: window)
            if !matches.indices.contains(index) {
                let hidden = all(identifier: identifier, text: ref.text, in: window, clipped: true)
                if hidden.indices.contains(index) {
                    let view = hidden[index].view
                    view.scrollToVisible(view.bounds)
                    view.window?.displayIfNeeded()
                    matches = all(identifier: identifier, text: ref.text, in: window)
                }
            }
            guard matches.indices.contains(index) else {
                return .failure(.init(matches.isEmpty ? "no \(ref) on screen" : "only \(matches.count) of \(ref)"))
            }
            return .success(matches[index])
        }

        /// Whether the view shows `text`: as its own text, a text field inside it, or (an icon button) as
        /// its accessibility label, as the original's `aria-label` names such buttons.
        static func shows(_ text: String, _ view: NSView) -> Bool {
            if GeometryDump.text(of: view)?.string == text { return true }
            if view.accessibilityLabel() == text { return true }
            return Views.first(NSTextField.self, in: view) { $0.stringValue == text } != nil
        }

        /// The text a view shows, for `expect {text}`: its own, or its text fields' joined by a space.
        static func text(of view: NSView) -> String {
            if let own = GeometryDump.text(of: view)?.string { return own }
            return Views.all(NSTextField.self, in: view).map(\.stringValue).filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
#endif
