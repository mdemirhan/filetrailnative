// Port of the element lookup of tools/capture/electron/driver.ts (elements.json names); no TypeScript source.
#if DEBUG
    import AppKit

    /// The logical element names of `tools/capture/elements.json`, mapped to this app's
    /// `accessibilityIdentifier`s.
    struct AutomationElements: Equatable, Sendable {
        /// Logical name → accessibility identifier.
        var identifiers: [String: String]
        /// The names whose text the original reads from `aria-label` (`textAttribute`): their accessibility label.
        var labelled: Set<String> = []

        struct LoadError: Error, CustomStringConvertible {
            let description: String
        }

        static func parse(_ data: Data) throws -> AutomationElements {
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let elements = top["elements"] as? [String: Any]
            else { throw LoadError(description: "elements.json has no \"elements\" object") }
            var identifiers: [String: String] = [:]
            var labelled: Set<String> = []
            for (name, raw) in elements {
                guard let spec = raw as? [String: Any], let swift = spec["swift"] as? String else {
                    throw LoadError(description: "elements.json: \"\(name)\" has no \"swift\" identifier")
                }
                identifiers[name] = swift
                let electron = spec["electron"] as? [String: Any]
                if electron?["textAttribute"] as? String == "aria-label" { labelled.insert(name) }
            }
            return AutomationElements(identifiers: identifiers, labelled: labelled)
        }

        static func load(_ file: URL) throws -> AutomationElements {
            try parse(Data(contentsOf: file))
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

        /// The views a window shows: its frame view, which holds the content, the title bar with the toolbar's items
        /// (NSToolbar) and the top layer the app's menus are drawn in (`WindowOverlayView`); and the toolbar's item
        /// views wherever the system put them (a full-screen window's toolbar is a window of its own).
        static func roots(of window: NSWindow) -> [NSView] {
            guard let frameView = window.contentView?.superview ?? window.contentView else { return [] }
            var roots = [frameView]
            for item in window.toolbar?.items ?? [] {
                guard let view = item.view, view.window != nil, !view.isDescendant(of: frameView) else { continue }
                roots.append(view)
            }
            return roots
        }

        /// Every visible view with `identifier`, top to bottom then left to right, narrowed by `text`.
        /// With `clipped`, views scrolled out of their scroll view are included too.
        static func all(identifier: String, text: String?, in window: NSWindow, clipped: Bool = false) -> [Match] {
            var matches: [Match] = []
            for candidate in windows(around: window) {
                AutomationTags.apply(in: candidate)
                let size = candidate.contentView?.bounds.size ?? .zero
                let views = roots(of: candidate).flatMap { Views.all(NSView.self, in: $0) }
                for view in views
                where view.accessibilityIdentifier() == identifier && !AutomationTags.mirrorsItsItem(view) {
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

        /// The text of the element `name` for `expect {text}`, as the original's driver reads it: the accessibility
        /// label where it reads `aria-label`, otherwise what the view shows.
        static func text(of view: NSView, named name: String, elements: AutomationElements) -> String {
            elements.labelled.contains(name) ? (view.accessibilityLabel() ?? "") : text(of: view)
        }

        /// The text a view shows, for `expect {text}`: its own, or its text fields' joined by a space.
        static func text(of view: NSView) -> String {
            if let own = GeometryDump.text(of: view)?.string { return own }
            return Views.all(NSTextField.self, in: view).map(\.stringValue).filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
#endif
