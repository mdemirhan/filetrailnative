import Foundation

/// What the permissions popover knows of one item: its mode, its flags, whose it is, and whether it is a folder.
public struct PermissionsItem: Equatable, Sendable {
    public var path: String
    /// The nine bits of the mode (and the three above them, kept as they are).
    public var mode: Int
    public var locked: Bool
    public var hidden: Bool
    public var isFolder: Bool
    public var owner: String
    public var group: String
    /// Whether the one running the app owns it, and so may change it without a password.
    public var isYours: Bool

    public init(
        path: String, mode: Int, locked: Bool, hidden: Bool, isFolder: Bool, owner: String, group: String,
        isYours: Bool
    ) {
        self.path = path
        self.mode = mode
        self.locked = locked
        self.hidden = hidden
        self.isFolder = isFolder
        self.owner = owner
        self.group = group
        self.isYours = isYours
    }
}

/// A box of the popover: on every item, on none, or on some.
public enum PermissionsState: Equatable, Sendable {
    case on, off, mixed
}

/// One change the popover makes. Only what is changed changes: a box clicked sets or clears that bit on every item
/// and leaves each item's other bits as they were; a mode typed sets the nine bits of every item.
public enum PermissionsChange: Equatable, Sendable {
    /// `who`: 0 owner, 1 group, 2 everyone; `what`: 0 read, 1 write, 2 run or open.
    case bit(who: Int, what: Int, on: Bool)
    case mode(Int)
    case locked(Bool)
    case hidden(Bool)

    /// The mode `change` leaves an item with `mode`.
    public func applied(to mode: Int) -> Int {
        switch self {
        case .bit(let who, let what, let on):
            let mask = 1 << ((2 - who) * 3 + (2 - what))
            return on ? mode | mask : mode & ~mask
        case .mode(let value): return (mode & ~0o777) | (value & 0o777)
        case .locked, .hidden: return mode
        }
    }
}

/// What the permissions popover shows of its items, and what is typed in its Mode field.
public struct PermissionsChecklist: Equatable, Sendable {
    public var items: [PermissionsItem]

    public init(items: [PermissionsItem]) { self.items = items }

    /// Every item is yours: anyone else's needs a password, which the app doesn't ask for.
    public var canChange: Bool { !items.isEmpty && items.allSatisfy(\.isYours) }

    /// The third column's name: Open when every item is a folder, Run when none is, else Run or Open.
    public var thirdColumn: String {
        if items.allSatisfy(\.isFolder) { return "Open" }
        if !items.contains(where: \.isFolder) { return "Run" }
        return "Run/Open"
    }

    public func state(who: Int, what: Int) -> PermissionsState {
        let mask = 1 << ((2 - who) * 3 + (2 - what))
        let count = items.filter { $0.mode & mask != 0 }.count
        return count == 0 ? .off : count == items.count ? .on : .mixed
    }

    public var lockedState: PermissionsState { Self.state(items.map(\.locked)) }
    public var hiddenState: PermissionsState { Self.state(items.map(\.hidden)) }

    private static func state(_ values: [Bool]) -> PermissionsState {
        let count = values.filter { $0 }.count
        return count == 0 ? .off : count == values.count ? .on : .mixed
    }

    /// "644", or "Mixed" while the items differ.
    public var modeText: String {
        let modes = Set(items.map { $0.mode & 0o777 })
        guard modes.count == 1, let mode = modes.first else { return "Mixed" }
        return PermissionText.mode(mode)
    }

    /// "rw-r--r--", with "?" for a bit some of the items have.
    public var letters: String {
        (0..<3).map { who in
            zip(["r", "w", "x"], 0..<3).map { letter, what in
                switch state(who: who, what: what) {
                case .on: letter
                case .off: "-"
                case .mixed: "?"
                }
            }.joined()
        }.joined()
    }

    /// The owner or the group they all share; how many there are where they differ.
    public var owner: String { Self.shared(items.map(\.owner), many: "owners") }
    public var group: String { Self.shared(items.map(\.group), many: "groups") }

    private static func shared(_ names: [String], many: String) -> String {
        let distinct = Array(Set(names))
        return distinct.count == 1 ? distinct[0] : "\(distinct.count) \(many)"
    }

    /// What is typed in the Mode field, as three octal digits ("644", "0644") or nine letters ("rw-r--r--"); nil for
    /// anything else.
    public static func parseMode(_ text: String) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.count == 9, typed.allSatisfy({ "rwx-".contains($0) }) {
            var mode = 0
            for (index, character) in typed.enumerated() {
                let expected: Character = ["r", "w", "x"][index % 3]
                if character == expected {
                    mode |= 1 << (8 - index)
                } else if character != "-" {
                    return nil
                }
            }
            return mode
        }
        let digits = typed.hasPrefix("0") && typed.count == 4 ? String(typed.dropFirst()) : typed
        guard digits.count == 3, digits.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
        return Int(digits, radix: 8)
    }

    /// Whether `change` would take away your own Open of a folder of yours: you couldn't open it until it is given
    /// back, so it asks first.
    public func locksYouOut(_ change: PermissionsChange) -> Bool {
        items.contains { item in
            item.isFolder && item.isYours && item.mode & 0o100 != 0 && change.applied(to: item.mode) & 0o100 == 0
        }
    }

    /// The items as `change` leaves them, before they are read again.
    public func applying(_ change: PermissionsChange) -> PermissionsChecklist {
        var next = self
        for index in next.items.indices {
            switch change {
            case .bit, .mode: next.items[index].mode = change.applied(to: next.items[index].mode)
            case .locked(let on): next.items[index].locked = on
            case .hidden(let on): next.items[index].hidden = on
            }
        }
        return next
    }
}
