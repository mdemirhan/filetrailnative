// Port of the capture scenario format shared with tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import Foundation

    /// One UI state or flow to capture, as written in `tools/capture/scenarios/**/*.json`. The same file
    /// drives the original app (through Playwright) and this one (through `--automation`).
    struct Scenario: Equatable, Sendable {
        var name: String
        /// The folder relative paths in `open` and `fs` steps start from: absolute, `~/…`, or relative to
        /// the fixtures folder (`FILETRAIL_FIXTURES`, by default `~/Library/Caches/filetrail-dev/fixtures`).
        /// `FILETRAIL_SCENARIO_ROOT` replaces it: run.sh points it at a scratch copy for scenarios that
        /// change files.
        var root: String?
        /// The frozen clock (local ISO time); `fs` steps date what they make with it.
        var now: String?
        /// The feature rows (`F-…`) and behavior rules (`B-…`) the scenario proves, and its tiers.
        var features: [String] = []
        var behaviors: [String] = []
        var tiers: [String] = []
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

        enum Edge: String, Equatable, Sendable {
            case top, bottom
        }

        /// A change to the fixture made from outside the app, as another app would make it.
        enum FileOp: Equatable, Sendable {
            /// A file (with `contents`) or, with `directory`, a folder.
            case create(path: String, contents: String, directory: Bool)
            case write(path: String, contents: String, append: Bool)
            case rename(path: String, to: String)
            case delete(path: String)
            /// `mode` in octal, as `chmod` takes it.
            case chmod(path: String, mode: String)
            /// The Finder's Locked flag (`uchg`).
            case lock(path: String, locked: Bool)
            /// Dates the item to the scenario's clock (a folder a write just changed shows today's real time).
            case touch(path: String)

            var name: String {
                switch self {
                case .create: "create"
                case .write: "write"
                case .rename: "rename"
                case .delete: "delete"
                case .chmod: "chmod"
                case .lock: "lock"
                case .touch: "touch"
                }
            }
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
            case geometry(name: String, allViews: Bool)
            /// `holdMilliseconds` keeps the button down that long (a press and hold).
            case click(ElementRef, button: MouseButton, count: Int, modifiers: [String], holdMilliseconds: Int)
            /// Sets a pop-up button to the item with this title, as choosing it does.
            case pick(ElementRef, option: String)
            case menu(path: [String])
            case contextMenu(ElementRef, choose: [String])
            /// `toEdge` drops in the top or bottom quarter of the target (before or after it in a list).
            case drag(from: ElementRef, to: ElementRef, modifiers: [String], toEdge: Edge?)
            /// A drag of these files from another app. `hold` stops short of the drop: the target must offer to take
            /// them. `refused`: the target must turn them down.
            case dragFiles(files: [String], to: ElementRef, hold: Bool, refused: Bool)
            /// Roots the folder tree here, as Use as Tree Root does.
            case rootTree(path: String)
            /// The window as the screen shows it, shadow included, for the README (`WindowShot`).
            case windowShot(name: String)
            /// `windowShot` in the middle of a marquee, between two points measured from the window's top left.
            case marqueeShot(start: NSPoint, end: NSPoint, name: String)
            case expectSheet(name: String)
            case sheetButton(label: String)
            case newWindow
            case newTab
            case selectTab(index: Int)
            case selectWindow(index: Int?, title: String?)
            case fs(FileOp)
            case expect(ElementRef, text: String?, visible: Bool?, count: Int?)

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
                case .geometry: "geometry"
                case .click: "click"
                case .pick: "pick"
                case .menu: "menu"
                case .contextMenu: "contextMenu"
                case .drag: "drag"
                case .dragFiles: "dragFiles"
                case .expectSheet: "expectSheet"
                case .sheetButton: "sheetButton"
                case .newWindow: "newWindow"
                case .newTab: "newTab"
                case .selectTab: "selectTab"
                case .selectWindow: "selectWindow"
                case .fs: "fs"
                case .expect: "expect"
                }
            }
        }

        /// A preference value: the original's preferences include lists and objects (favorites, columns).
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
            func strings(_ key: String) throws -> [String] {
                guard let value = top[key] else { return [] }
                guard let list = value as? [String] else { throw ParseError(description: "\"\(key)\" is not a list") }
                return list
            }
            return Scenario(
                name: name, root: top["root"] as? String, now: top["now"] as? String,
                features: try strings("features"), behaviors: try strings("behaviors"), tiers: try strings("tier"),
                steps: steps)
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
            func element(_ key: String, siblings: Bool) throws -> ElementRef {
                switch step[key] {
                case let name as String:
                    guard siblings else { return ElementRef(name) }
                    return ElementRef(name, index: try optionalInt("index"), text: step["text"] as? String)
                case let object as [String: Any]:
                    guard let name = (object["name"] ?? object["element"]) as? String else {
                        throw fail("\"\(key)\" has no \"name\"")
                    }
                    let position = object["index"] as? NSNumber
                    return ElementRef(name, index: position.map(\.intValue), text: object["text"] as? String)
                default:
                    throw fail("missing element \"\(key)\"")
                }
            }
            func edge() throws -> Edge? {
                guard let value = step["toEdge"] else { return nil }
                guard let name = value as? String, let edge = Edge(rawValue: name) else {
                    throw fail("\"toEdge\" must be \"top\" or \"bottom\"")
                }
                return edge
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
            case "geometry":
                return .geometry(name: try string("name"), allViews: step["allViews"] as? Bool ?? false)
            case "click":
                let buttonName = step["button"] as? String ?? "left"
                guard let button = MouseButton(rawValue: buttonName) else { throw fail("unknown button \(buttonName)") }
                let count = try optionalInt("count") ?? 1
                guard (1...3).contains(count) else { throw fail("\"count\" must be 1 to 3") }
                let hold = try optionalInt("holdMs") ?? 0
                guard hold >= 0, hold <= 5000 else { throw fail("\"holdMs\" must be 0 to 5000") }
                return .click(
                    try element("element", siblings: true), button: button, count: count, modifiers: try modifiers(),
                    holdMilliseconds: hold)
            case "pick":
                return .pick(try element("element", siblings: true), option: try string("option"))
            case "menu":
                guard let path = step["path"] as? [String], !path.isEmpty else { throw fail("missing \"path\"") }
                return .menu(path: path)
            case "contextMenu":
                let choose: [String]
                switch step["choose"] {
                case nil: choose = []
                case let label as String: choose = [label]
                case let labels as [String]: choose = labels
                default: throw fail("\"choose\" is not a label or a list of labels")
                }
                return .contextMenu(try element("element", siblings: true), choose: choose)
            case "drag":
                return .drag(
                    from: try element("from", siblings: false), to: try element("to", siblings: false),
                    modifiers: try modifiers(), toEdge: try edge())
            case "dragFiles":
                guard let files = step["files"] as? [String], !files.isEmpty else {
                    throw fail("missing \"files\"")
                }
                let hold = step["hold"] as? Bool ?? false
                let refused = step["refused"] as? Bool ?? false
                if hold, refused { throw fail("\"hold\" and \"refused\" don't go together") }
                return .dragFiles(files: files, to: try element("to", siblings: false), hold: hold, refused: refused)
            case "expectSheet":
                return .expectSheet(name: try string("name"))
            case "sheetButton":
                return .sheetButton(label: try string("label"))
            case "newWindow":
                return .newWindow
            case "newTab":
                return .newTab
            case "selectTab":
                return .selectTab(index: Int(try number("index")))
            case "selectWindow":
                let position = try optionalInt("index")
                let title = step["title"] as? String
                guard position != nil || title != nil else { throw fail("needs \"index\" or \"title\"") }
                return .selectWindow(index: position, title: title)
            case "fs":
                return .fs(try parseFileOp(step, fail: fail))
            case "expect":
                let visible = step["visible"] as? Bool
                let count = try optionalInt("count")
                let text = step["text"] as? String
                guard visible != nil || count != nil || text != nil else {
                    throw fail("needs \"text\", \"visible\" or \"count\"")
                }
                return .expect(try element("element", siblings: false), text: text, visible: visible, count: count)
            default:
                throw ParseError(description: "step \(index): unknown step \"\(kind)\"")
            }
        }

        private static func parseFileOp(_ step: [String: Any], fail: (String) -> ParseError) throws -> FileOp {
            guard let op = step["op"] as? String else { throw fail("missing \"op\"") }
            guard let path = step["path"] as? String, !path.isEmpty else { throw fail("missing \"path\"") }
            let contents = step["contents"] as? String ?? ""
            switch op {
            case "create":
                return .create(path: path, contents: contents, directory: step["directory"] as? Bool ?? false)
            case "write":
                return .write(path: path, contents: contents, append: step["append"] as? Bool ?? false)
            case "rename":
                guard let target = step["to"] as? String, !target.isEmpty else { throw fail("missing \"to\"") }
                return .rename(path: path, to: target)
            case "delete":
                return .delete(path: path)
            case "chmod":
                guard let mode = step["mode"] as? String, Int(mode, radix: 8) != nil else {
                    throw fail("\"mode\" must be an octal string such as \"644\"")
                }
                return .chmod(path: path, mode: mode)
            case "lock":
                return .lock(path: path, locked: step["locked"] as? Bool ?? true)
            case "touch":
                return .touch(path: path)
            default:
                throw fail("unknown op \"\(op)\"")
            }
        }

        fileprivate static func isBool(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        /// Resolves a path from an `open` or `fs` step.
        func resolve(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            func expand(_ text: String) -> String {
                if text == "~" { return home }
                if text.hasPrefix("~/") { return home + text.dropFirst() }
                return text
            }
            let fixtures = expand(environment["FILETRAIL_FIXTURES"] ?? "~/Library/Caches/filetrail-dev/fixtures")
            var base = expand(environment["FILETRAIL_SCENARIO_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? root ?? "")
            if !base.hasPrefix("/") { base = (fixtures as NSString).appendingPathComponent(base) }
            let target = expand(path)
            let full = target.hasPrefix("/") ? target : (base as NSString).appendingPathComponent(target)
            return URL(fileURLWithPath: (full as NSString).standardizingPath, isDirectory: true)
        }

        /// The scenario's clock as a date, read as local time.
        var nowDate: Date? {
            guard let now else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: now) { return date }
            }
            return ISO8601DateFormatter().date(from: now)
        }
    }
#endif
