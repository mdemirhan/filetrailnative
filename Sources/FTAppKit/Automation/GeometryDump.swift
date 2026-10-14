// Port of the geometry dump format shared with tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import AppKit

    /// The frames and text styles of named views, as `tools/capture` compares them with the original's
    /// DOM. Views are named by their `accessibilityIdentifier`.
    struct GeometryDump: Codable, Equatable, Sendable {
        static let format = "filetrail-geometry/1"

        var format = GeometryDump.format
        var side: String
        var name: String
        var window: Size
        var elements: [Element]

        struct Size: Codable, Equatable, Sendable {
            var width: Double
            var height: Double
        }

        /// In window content coordinates: points, origin at the top left.
        struct Frame: Codable, Equatable, Sendable {
            var x: Double
            var y: Double
            var width: Double
            var height: Double
        }

        struct Text: Codable, Equatable, Sendable {
            var string: String
            var fontSize: Double?
            /// CSS weight (100…900), so it compares with `getComputedStyle().fontWeight`.
            var fontWeight: Int?
            /// `#rrggbb`, or `#rrggbbaa` when not opaque, in sRGB.
            var color: String?
        }

        struct Element: Codable, Equatable, Sendable {
            var id: String
            var frame: Frame
            var text: Text?
            /// Only in a dump of every view (`allViews`), for finding views to name.
            var viewClass: String?
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }

        // MARK: Formatting

        /// The CSS weight nearest an AppKit weight trait (-1…1).
        static func cssWeight(_ trait: Double) -> Int {
            let table: [(Double, Int)] = [
                (NSFont.Weight.ultraLight.rawValue, 100), (NSFont.Weight.thin.rawValue, 200),
                (NSFont.Weight.light.rawValue, 300), (NSFont.Weight.regular.rawValue, 400),
                (NSFont.Weight.medium.rawValue, 500), (NSFont.Weight.semibold.rawValue, 600),
                (NSFont.Weight.bold.rawValue, 700), (NSFont.Weight.heavy.rawValue, 800),
                (NSFont.Weight.black.rawValue, 900),
            ]
            return table.min { abs($0.0 - trait) < abs($1.0 - trait) }?.1 ?? 400
        }

        static func hex(red: Double, green: Double, blue: Double, alpha: Double) -> String {
            func byte(_ value: Double) -> String {
                String(format: "%02x", Int((min(1, max(0, value)) * 255).rounded()))
            }
            let rgb = "#" + byte(red) + byte(green) + byte(blue)
            return alpha >= 0.999 ? rgb : rgb + byte(alpha)
        }

        static func round(_ value: Double) -> Double {
            (value * 100).rounded() / 100
        }
    }

    @MainActor
    extension GeometryDump {
        /// Every visible view with an identifier in `window`, title bar and toolbar included; with
        /// `allViews`, every visible view.
        init(window: NSWindow, name: String, allViews: Bool = false) {
            let content = window.contentView
            let size = content?.bounds.size ?? .zero
            var elements: [Element] = []
            if let root = content?.superview ?? content {
                Self.collect(root, in: window, allViews: allViews, into: &elements)
            }
            self.init(
                side: "swift", name: name, window: Size(width: size.width, height: size.height), elements: elements)
        }

        private static func collect(_ view: NSView, in window: NSWindow, allViews: Bool, into elements: inout [Element])
        {
            guard !view.isHidden else { return }
            let id = view.accessibilityIdentifier()
            if !id.isEmpty || allViews {
                let frame = frame(of: view, in: window)
                // Scrolled out of the window: not on screen to compare (the original's dump skips these too).
                let size = window.contentView?.bounds.size ?? .zero
                let onScreen =
                    frame.y + frame.height > 0 && frame.y < size.height && frame.x + frame.width > 0
                    && frame.x < size.width
                if onScreen || allViews {
                    var element = Element(id: id, frame: frame, text: text(of: view))
                    if allViews { element.viewClass = String(describing: type(of: view)) }
                    elements.append(element)
                }
            }
            for child in view.subviews { collect(child, in: window, allViews: allViews, into: &elements) }
        }

        static func frame(of view: NSView, in window: NSWindow) -> Frame {
            let inWindow = view.convert(view.bounds, to: nil)
            let height = window.contentView?.bounds.height ?? window.frame.height
            let origin = window.contentView.map { $0.convert(inWindow, from: nil) } ?? inWindow
            let y = (window.contentView?.isFlipped ?? false) ? origin.minY : height - origin.maxY
            return Frame(x: round(origin.minX), y: round(y), width: round(origin.width), height: round(origin.height))
        }

        static func text(of view: NSView) -> Text? {
            // A view drawn around a text field (a menu row, a button with a label) shows that field's text.
            if let source = view as? TextStyleSource, let field = source.styleTextField, field !== view {
                return text(of: field)
            }
            if let field = view as? NSTextField {
                let string = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
                return Text(
                    string: string, fontSize: field.font.map { Double($0.pointSize) },
                    fontWeight: field.font.map(weight(of:)), color: field.textColor.flatMap { hex($0, in: view) })
            }
            if let cell = view as? NSTableCellView, let field = cell.textField {
                return text(of: field)
            }
            if let button = view as? NSButton, !button.title.isEmpty {
                return Text(
                    string: button.title, fontSize: button.font.map { Double($0.pointSize) },
                    fontWeight: button.font.map(weight(of:)), color: nil)
            }
            return nil
        }

        static func weight(of font: NSFont) -> Int {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return cssWeight((traits?[.weight] as? Double) ?? 0)
        }

        /// The color as drawn in the view's appearance (system colors change with light and dark).
        static func hex(_ color: NSColor, in view: NSView) -> String? {
            var result: String?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                if let rgb = color.usingColorSpace(.sRGB) {
                    result = hex(
                        red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent,
                        alpha: rgb.alphaComponent)
                }
            }
            return result
        }
    }
#endif
