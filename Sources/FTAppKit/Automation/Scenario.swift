#if DEBUG
    import Foundation

    /// One UI state or flow to capture, as written in a scenario's JSON file. The app plays it through
    /// `--automation`.
    struct Scenario: Equatable, Sendable {
        var name: String
        /// The folder relative paths in `open` steps start from: absolute, `~/…`, or relative to the fixtures
        /// folder (`$FILETRAIL_DEV_CACHE/fixtures`, by default `~/Library/Caches/filetrail-dev/fixtures`).
        var root: String?
        var steps: [Step]

        /// A logical element of `tools/capture/elements.json`, narrowed to one of several by its text or
        /// its place (top to bottom, then left to right).
        struct ElementRef: Equatable, Sendable, CustomStringConvertible {
            var name: String
            var index: Int?
            var text: String?

            init(_ name: String, index: Int? = nil, text: String? = nil) {
                self.name = name
                self.index = index
                self.text = text
            }

            var description: String {
                var parts = [name]
                if let text { parts.append("“\(text)”") }
                if let index { parts.append("#\(index)") }
                return parts.joined(separator: " ")
            }
        }

        enum MouseButton: String, Equatable, Sendable {
            case left, right
        }

        enum Step: Equatable, Sendable {
            case window(width: Double, height: Double)
            case prefs([String: PrefValue])
            case open(path: String)
            case select(names: [String])
            case key(key: String, modifiers: [String])
            case type(text: String)
            case command(id: String)
            case wait(milliseconds: Int)
            case snapshot(name: String)
            /// `holdMilliseconds` keeps the button down that long (a press and hold).
            case click(ElementRef, button: MouseButton, count: Int, modifiers: [String], holdMilliseconds: Int)
            case menu(path: [String])
            /// Roots the folder tree here, as Use as Tree Root does.
            case rootTree(path: String)
            /// The window as the screen shows it, shadow included, for the README (`WindowShot`).
            case windowShot(name: String)
            /// `windowShot` in the middle of a marquee, between two points measured from the window's top left.
            case marqueeShot(start: NSPoint, end: NSPoint, name: String)
            case expectSheet(name: String)
            case newTab
            case selectTab(index: Int)
            case selectWindow(index: Int?, title: String?)

            /// The step's name as written in the file.
            var kind: String {
                switch self {
                case .window: "window"
                case .prefs: "prefs"
                case .open: "open"
                case .select: "select"
                case .key: "key"
                case .type: "type"
                case .command: "command"
                case .wait: "wait"
                case .snapshot: "snapshot"
                case .rootTree: "rootTree"
                case .windowShot: "windowShot"
                case .marqueeShot: "marqueeShot"
                case .click: "click"
                case .menu: "menu"
                case .expectSheet: "expectSheet"
                case .newTab: "newTab"
                case .selectTab: "selectTab"
                case .selectWindow: "selectWindow"
                }
            }
        }

        /// A preference value: the preferences include lists and objects (favorites, columns).
        indirect enum PrefValue: Equatable, Sendable {
            case string(String)
            case number(Double)
            case bool(Bool)
            case null
            case array([PrefValue])
            case object([String: PrefValue])

            var string: String? {
                if case .string(let value) = self { return value }
                return nil
            }

            var number: Double? {
                if case .number(let value) = self { return value }
                return nil
            }

            var bool: Bool? {
                if case .bool(let value) = self { return value }
                return nil
            }

            init?(json: Any) {
                switch json {
                case let text as String: self = .string(text)
                case let number as NSNumber:
                    self = Scenario.isBool(number) ? .bool(number.boolValue) : .number(number.doubleValue)
                case is NSNull: self = .null
                case let list as [Any]:
                    var values: [PrefValue] = []
                    for element in list {
                        guard let value = PrefValue(json: element) else { return nil }
                        values.append(value)
                    }
                    self = .array(values)
                case let object as [String: Any]:
                    var values: [String: PrefValue] = [:]
                    for (key, element) in object {
                        guard let value = PrefValue(json: element) else { return nil }
                        values[key] = value
                    }
                    self = .object(values)
                default: return nil
                }
            }
        }

        struct ParseError: Error, Equatable, CustomStringConvertible {
            let description: String
        }

        /// Reads a scenario file. Unknown top-level keys (`description`, `setup`, …) are ignored; an
        /// unknown step or a step missing a value is an error, so that a typo doesn't pass silently.
        static func parse(_ data: Data) throws -> Scenario {
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw ParseError(description: "not JSON: \(error.localizedDescription)")
            }
            guard let top = object as? [String: Any] else { throw ParseError(description: "not a JSON object") }
            guard let name = top["name"] as? String, !name.isEmpty else {
                throw ParseError(description: "missing \"name\"")
            }
            guard let rawSteps = top["steps"] as? [Any] else { throw ParseError(description: "missing \"steps\"") }
            let steps = try rawSteps.enumerated().map { index, raw in
                guard let step = raw as? [String: Any] else {
                    throw ParseError(description: "step \(index + 1): not an object")
                }
                return try parseStep(step, index: index + 1)
            }
            return Scenario(name: name, root: top["root"] as? String, steps: steps)
        }

        private static func parseStep(_ step: [String: Any], index: Int) throws -> Step {
            guard let kind = step["step"] as? String else {
                throw ParseError(description: "step \(index): missing \"step\"")
            }
            func fail(_ message: String) -> ParseError {
                ParseError(description: "step \(index) (\(kind)): \(message)")
            }
            func string(_ key: String) throws -> String {
                guard let value = step[key] as? String else { throw fail("missing \"\(key)\"") }
                return value
            }
            func number(_ key: String) throws -> Double {
                guard let value = step[key] as? NSNumber, !isBool(value) else {
                    throw fail("missing number \"\(key)\"")
                }
                return value.doubleValue
            }
            func optionalInt(_ key: String) throws -> Int? {
                guard step[key] != nil else { return nil }
                return Int(try number(key))
            }
            func element() throws -> ElementRef {
                switch step["element"] {
                case let name as String:
                    return ElementRef(name, index: try optionalInt("index"), text: step["text"] as? String)
                case let object as [String: Any]:
                    guard let name = (object["name"] ?? object["element"]) as? String else {
                        throw fail("\"element\" has no \"name\"")
                    }
                    let position = object["index"] as? NSNumber
                    return ElementRef(name, index: position.map(\.intValue), text: object["text"] as? String)
                default:
                    throw fail("missing element \"element\"")
                }
            }
            func modifiers() throws -> [String] {
                guard let value = step["modifiers"] else { return [] }
                guard let list = value as? [String] else { throw fail("\"modifiers\" is not a list") }
                return list
            }
            switch kind {
            case "window":
                return .window(width: try number("width"), height: try number("height"))
            case "prefs":
                guard let values = step["prefs"] as? [String: Any] else { throw fail("missing \"prefs\"") }
                var prefs: [String: PrefValue] = [:]
                for (key, value) in values {
                    guard let parsed = PrefValue(json: value) else { throw fail("\"\(key)\" is not a JSON value") }
                    prefs[key] = parsed
                }
                return .prefs(prefs)
            case "open":
                return .open(path: try string("path"))
            case "select":
                guard let names = step["names"] as? [String] else { throw fail("missing \"names\"") }
                return .select(names: names)
            case "key":
                return .key(key: try string("key"), modifiers: try modifiers())
            case "type":
                return .type(text: try string("text"))
            case "command":
                return .command(id: try string("id"))
            case "wait":
                return .wait(milliseconds: Int(try number("ms")))
            case "snapshot":
                return .snapshot(name: try string("name"))
            case "rootTree":
                return .rootTree(path: try string("path"))
            case "windowShot":
                return .windowShot(name: try string("name"))
            case "marqueeShot":
                guard let start = step["start"] as? [Double], let end = step["end"] as? [Double], start.count == 2,
                    end.count == 2
                else { throw fail("\"start\" and \"end\" are [x, y]") }
                return .marqueeShot(
                    start: NSPoint(x: start[0], y: start[1]), end: NSPoint(x: end[0], y: end[1]),
                    name: try string("name"))
            case "click":
                let buttonName = step["button"] as? String ?? "left"
                guard let button = MouseButton(rawValue: buttonName) else { throw fail("unknown button \(buttonName)") }
                let count = try optionalInt("count") ?? 1
                guard (1...3).contains(count) else { throw fail("\"count\" must be 1 to 3") }
                let hold = try optionalInt("holdMs") ?? 0
                guard hold >= 0, hold <= 5000 else { throw fail("\"holdMs\" must be 0 to 5000") }
                return .click(
                    try element(), button: button, count: count, modifiers: try modifiers(),
                    holdMilliseconds: hold)
            case "menu":
                guard let path = step["path"] as? [String], !path.isEmpty else { throw fail("missing \"path\"") }
                return .menu(path: path)
            case "expectSheet":
                return .expectSheet(name: try string("name"))
            case "newTab":
                return .newTab
            case "selectTab":
                return .selectTab(index: Int(try number("index")))
            case "selectWindow":
                let position = try optionalInt("index")
                let title = step["title"] as? String
                guard position != nil || title != nil else { throw fail("needs \"index\" or \"title\"") }
                return .selectWindow(index: position, title: title)
            default:
                throw ParseError(description: "step \(index): unknown step \"\(kind)\"")
            }
        }

        fileprivate static func isBool(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        /// Resolves a path from an `open` step.
        func resolve(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            func expand(_ text: String) -> String {
                if text == "~" { return home }
                if text.hasPrefix("~/") { return home + text.dropFirst() }
                return text
            }
            let cache = expand(environment["FILETRAIL_DEV_CACHE"] ?? "~/Library/Caches/filetrail-dev")
            let fixtures = (cache as NSString).appendingPathComponent("fixtures")
            var base = expand(root ?? "")
            if !base.hasPrefix("/") { base = (fixtures as NSString).appendingPathComponent(base) }
            let target = expand(path)
            let full = target.hasPrefix("/") ? target : (base as NSString).appendingPathComponent(target)
            return URL(fileURLWithPath: (full as NSString).standardizingPath, isDirectory: true)
        }
    }
#endif
