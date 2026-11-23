// Checks shortcut resolution against the shortcut-resolution golden
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct ShortcutGoldenTests {
    struct Assignment: Codable, Sendable {
        let id: String
        let shortcut: String
        let slot: Int
    }

    struct Event: Codable, Sendable {
        let key: String
        let code: String
        let metaKey: Bool
        let ctrlKey: Bool
        let altKey: Bool
        let shiftKey: Bool
    }

    struct Input: Codable, Sendable {
        let overrides: JSONNode
        let probes: [String]
        let assignments: [Assignment]
        let events: [Event]
    }

    struct Refusal: Codable, Equatable, Sendable {
        let reason: String
        let command: String?
    }

    struct Probe: Codable, Equatable, Sendable {
        let shortcut: String
        let normalized: String?
        let refusal: Refusal?
        let macOS: Bool
        let textEditing: Bool
        let withoutShift: String?
        let menuAccelerator: String?
    }

    struct AssignmentResult: Codable, Equatable, Sendable {
        let id: String
        let shortcut: String
        let slot: Int
        let status: String
        let refusal: Refusal?
        let command: String?
        let customized: Bool
        let assigned: [String: [String]]
        let removed: [String: [String]]
        let reset: [String: [String]]
        let takenFrom: [String]
        let menuShortcut: String?
    }

    struct Output: Codable, Equatable, Sendable {
        let bindings: [String: [String]]
        let commandByShortcut: [[String]]
        let sanitized: [String: [String]]
        let probes: [Probe]
        let assignments: [AssignmentResult]
        let events: [String?]
    }

    static func refusal(_ refusal: ShortcutCommands.Refusal?) -> Refusal? {
        guard let refusal else { return nil }
        if case .fixedCommand(let command) = refusal {
            return Refusal(reason: refusal.reason, command: command.rawValue)
        }
        return Refusal(reason: refusal.reason, command: nil)
    }

    static func named(_ bindings: ShortcutBindings) -> [String: [String]] {
        // Duplicate Tab is left out: the golden has no key for it.
        Dictionary(
            uniqueKeysWithValues: bindings.filter { $0.key != .duplicateTab }.map { ($0.key.rawValue, $0.value) })
    }

    static func run(_ input: Input) -> Output {
        let resolved = ShortcutCommands.resolve(input.overrides)
        let probes = input.probes.map { shortcut in
            Probe(
                shortcut: shortcut, normalized: Shortcuts.normalize(shortcut),
                refusal: refusal(ShortcutCommands.refusal(for: shortcut)),
                macOS: ShortcutCommands.isUsedByMacOSByDefault(shortcut),
                textEditing: Shortcuts.isTextEditingShortcut(shortcut), withoutShift: Shortcuts.withoutShift(shortcut),
                menuAccelerator: Shortcuts.menuAccelerator(shortcut))
        }
        let assignments = input.assignments.map { assignment -> AssignmentResult in
            let id = ShortcutCommandID(rawValue: assignment.id) ?? .newTab
            let check = ShortcutCommands.checkAssignment(resolved.bindings, id, assignment.shortcut)
            var status = "ok"
            var checkRefusal: Refusal?
            var command: String?
            switch check {
            case .ok: status = "ok"
            case .unchanged: status = "unchanged"
            case .refused(let reason):
                status = "refused"
                checkRefusal = refusal(reason)
            case .conflict(let other):
                status = "conflict"
                command = other.rawValue
            }
            let assigned = ShortcutCommands.assign(resolved.bindings, id, slot: assignment.slot, assignment.shortcut)
            let removed = ShortcutCommands.remove(resolved.bindings, id, slot: assignment.slot)
            let reset = ShortcutCommands.reset(resolved.bindings, id)
            return AssignmentResult(
                id: assignment.id, shortcut: assignment.shortcut, slot: assignment.slot, status: status,
                refusal: checkRefusal, command: command,
                customized: ShortcutCommands.isCustomized(resolved.bindings, id),
                assigned: ShortcutCommands.overrides(for: assigned), removed: ShortcutCommands.overrides(for: removed),
                reset: ShortcutCommands.overrides(for: reset.bindings), takenFrom: reset.takenFrom.map(\.rawValue),
                menuShortcut: Shortcuts.menuShortcut(resolved.bindings[id] ?? []))
        }
        let events = input.events.map { event in
            Shortcuts.fromKeyboardEvent(
                ShortcutKeyEvent(
                    key: event.key, code: event.code, metaKey: event.metaKey, ctrlKey: event.ctrlKey,
                    altKey: event.altKey, shiftKey: event.shiftKey))
        }
        return Output(
            bindings: named(resolved.bindings),
            commandByShortcut: resolved.shortcutOrder.map { [$0, resolved.commandByShortcut[$0]?.rawValue ?? ""] },
            sanitized: ShortcutCommands.sanitizeOverrides(input.overrides), probes: probes, assignments: assignments,
            events: events)
    }

    @Test func keysAreResolvedAsTheGoldenFileSays() throws {
        let cases: [GoldenCase<Input, Output>] = try GoldenChanges.load(suite: "shortcut-resolution")
        #expect(cases.count == 30)
        Golden.expectMatches(cases) { Self.run($0) }
    }

    // Over many saved sets of keys, made from every default key, a few others and some that make no sense, given to
    // commands that exist and one that doesn't: no command has more keys than it may, no key runs two commands, a key
    // press runs the command that has the key, and the keys saved for the result give the same result again.
    @Test func keysResolveByTheirRulesOverManySavedSets() {
        var random = SeededGenerator(seed: 0x5EED_0002)
        let keys =
            Array(Set(ShortcutCommands.all.flatMap(\.defaults))).sorted()
            + ["Cmd+K", "Cmd+Shift+K", "Ctrl+Alt+P", "F7", "Cmd+", "", "Hyper+X", "cmd+k"]
        let commands = ShortcutCommands.all.map(\.id.rawValue) + ["notACommand"]
        for _ in 0..<300 {
            var saved: [String: JSONNode] = [:]
            for _ in 0..<Int.random(in: 0...8, using: &random) {
                let command = commands.randomElement(using: &random)!
                let count = Int.random(in: 0...3, using: &random)
                saved[command] =
                    Int.random(in: 0..<10, using: &random) == 0
                    ? .string("Cmd+K")
                    : .array((0..<count).map { _ in .string(keys.randomElement(using: &random)!) })
            }
            let resolved = ShortcutCommands.resolve(JSONNode.object(saved))
            var holder: [String: ShortcutCommandID] = [:]
            for (command, shortcuts) in resolved.bindings {
                #expect(shortcuts.count <= ShortcutCommands.perCommand, "\(command): \(shortcuts)")
                for shortcut in shortcuts {
                    #expect(
                        holder[shortcut] == nil, "\(shortcut) is \(command)'s and \(holder[shortcut]?.rawValue ?? "")'s"
                    )
                    holder[shortcut] = command
                    if !ShortcutCommands.definition(command).fixed {
                        #expect(resolved.commandByShortcut[shortcut] == command, "\(shortcut) runs \(command)")
                    }
                }
            }
            for (shortcut, command) in resolved.commandByShortcut {
                #expect(resolved.bindings[command]?.contains(shortcut) == true, "\(shortcut) isn't \(command)'s")
            }
            let again = ShortcutCommands.resolve(ShortcutCommands.overrides(for: resolved.bindings))
            let differing = resolved.bindings.keys.filter { again.bindings[$0] != resolved.bindings[$0] }
                .map { "\($0.rawValue): \(resolved.bindings[$0] ?? []) then \(again.bindings[$0] ?? [])" }
            #expect(differing.isEmpty, "\(differing) from \(ShortcutCommands.overrides(for: resolved.bindings))")
        }
    }
}
