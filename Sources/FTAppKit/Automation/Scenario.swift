// Port of the capture scenario format shared with tools/capture/electron/driver.ts; no TypeScript source.
#if DEBUG
    import Foundation

    /// One UI state to capture, as written in `tools/capture/scenarios/*.json`. The same file drives the
    /// original app (through Playwright) and this one (through `--automation`).
    struct Scenario: Equatable, Sendable {
        var name: String
        /// The folder relative paths in `open` steps start from: absolute, `~/…`, or relative to the
        /// fixtures folder (`FILETRAIL_FIXTURES`, by default `~/Library/Caches/filetrail-port/fixtures`).
        var root: String?
        var steps: [Step]

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
                case .geometry: "geometry"
                }
            }
        }

        enum PrefValue: Equatable, Sendable {
            case string(String)
            case number(Double)
            case bool(Bool)

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
            func string(_ key: String) throws -> String {
                guard let value = step[key] as? String else {
                    throw ParseError(description: "step \(index) (\(kind)): missing \"\(key)\"")
                }
                return value
            }
            func number(_ key: String) throws -> Double {
                guard let value = step[key] as? NSNumber, !isBool(value) else {
                    throw ParseError(description: "step \(index) (\(kind)): missing number \"\(key)\"")
                }
                return value.doubleValue
            }
            switch kind {
            case "window":
                return .window(width: try number("width"), height: try number("height"))
            case "prefs":
                guard let values = step["prefs"] as? [String: Any] else {
                    throw ParseError(description: "step \(index) (prefs): missing \"prefs\"")
                }
                var prefs: [String: PrefValue] = [:]
                for (key, value) in values {
                    if let text = value as? String {
                        prefs[key] = .string(text)
                    } else if let number = value as? NSNumber {
                        prefs[key] = isBool(number) ? .bool(number.boolValue) : .number(number.doubleValue)
                    } else {
                        throw ParseError(description: "step \(index) (prefs): \"\(key)\" is not a plain value")
                    }
                }
                return .prefs(prefs)
            case "open":
                return .open(path: try string("path"))
            case "select":
                guard let names = step["names"] as? [String] else {
                    throw ParseError(description: "step \(index) (select): missing \"names\"")
                }
                return .select(names: names)
            case "key":
                let modifiers = step["modifiers"] as? [String] ?? []
                return .key(key: try string("key"), modifiers: modifiers)
            case "type":
                return .type(text: try string("text"))
            case "command":
                return .command(id: try string("id"))
            case "wait":
                return .wait(milliseconds: Int(try number("ms")))
            case "snapshot":
                return .snapshot(name: try string("name"))
            case "geometry":
                return .geometry(name: try string("name"), allViews: step["allViews"] as? Bool ?? false)
            default:
                throw ParseError(description: "step \(index): unknown step \"\(kind)\"")
            }
        }

        private static func isBool(_ number: NSNumber) -> Bool {
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
            let fixtures = expand(environment["FILETRAIL_FIXTURES"] ?? "~/Library/Caches/filetrail-port/fixtures")
            var base = expand(root ?? "")
            if !base.hasPrefix("/") { base = (fixtures as NSString).appendingPathComponent(base) }
            let target = expand(path)
            let full = target.hasPrefix("/") ? target : (base as NSString).appendingPathComponent(target)
            return URL(fileURLWithPath: (full as NSString).standardizingPath, isDirectory: true)
        }
    }
#endif
