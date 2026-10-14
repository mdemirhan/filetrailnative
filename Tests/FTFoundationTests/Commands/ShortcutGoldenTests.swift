// Checks the port against goldens recorded from the reference: tools/parity/golden/shortcut-resolution.ts
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
        // Duplicate Tab is the port's own command (DEVIATIONS D-001): the reference has no key for it.
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

    @Test func keysAreResolvedLikeTheOriginalResolvesThem() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "shortcut-resolution")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
