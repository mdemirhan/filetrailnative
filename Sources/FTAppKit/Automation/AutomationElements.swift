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
        static func all(identifier: String, text: String?, in window: NSWindow) -> [Match] {
            var matches: [Match] = []
            for candidate in windows(around: window) {
                guard let root = candidate.contentView?.superview ?? candidate.contentView else { continue }
                AutomationTags.apply(in: candidate)
                let size = candidate.contentView?.bounds.size ?? .zero
                for view in Views.all(NSView.self, in: root) where view.accessibilityIdentifier() == identifier {
                    let frame = GeometryDump.frame(of: view, in: candidate)
                    guard frame.width > 0 || frame.height > 0,
                        frame.y + frame.height > 0, frame.y < size.height, frame.x + frame.width > 0,
                        frame.x < size.width
                    else { continue }
                    if let text, !shows(text, view) { continue }
                    matches.append(Match(view: view, frame: frame))
                }
            }
            return matches.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        }

        /// The view `ref` names, or why there is none.
        static func find(
            _ ref: Scenario.ElementRef, elements: AutomationElements?, in window: NSWindow
        ) -> Result<Match, AutomationRunner.Failure> {
            guard let elements else { return .failure(.init("no elements.json")) }
            guard let identifier = elements.identifiers[ref.name] else {
                return .failure(.init("unknown element \"\(ref.name)\""))
            }
            let matches = all(identifier: identifier, text: ref.text, in: window)
            let index = ref.index ?? 0
            guard matches.indices.contains(index) else {
                return .failure(.init(matches.isEmpty ? "no \(ref) on screen" : "only \(matches.count) of \(ref)"))
            }
            return .success(matches[index])
        }

        /// Whether the view shows `text`: as its own text or a text field inside it.
        static func shows(_ text: String, _ view: NSView) -> Bool {
            if GeometryDump.text(of: view)?.string == text { return true }
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
