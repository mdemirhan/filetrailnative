// The users `owner:` can name: the people of this Mac for the list under the field, read once, and the user each
// word names, asked of the system once a word. A Mac joined to a company's directory can take seconds to answer
// either, and both are asked for as the search is typed.
import Darwin
import Foundation
import OpenDirectory
import os

public enum SearchOwners {
    /// The people who sign in to this Mac, by name: the accounts this Mac keeps itself, never a directory's on the
    /// network, read once for as long as the app runs (about 30 ms). An account made since shows after the next
    /// launch; its name can be typed meanwhile.
    public static let people: [(name: String, id: uid_t)] = readPeople()

    private static func readPeople() -> [(name: String, id: uid_t)] {
        guard let node = try? ODNode(session: ODSession.default(), name: "/Local/Default"),
            let query = try? ODQuery(
                node: node, forRecordTypes: kODRecordTypeUsers, attribute: nil, matchType: ODMatchType(kODMatchAny),
                queryValues: nil, returnAttributes: [kODAttributeTypeUniqueID], maximumResults: 0),
            let records = try? query.resultsAllowingPartial(false) as? [ODRecord]
        else { return [] }
        var found: [(name: String, id: uid_t)] = []
        for record in records {
            guard let name = record.recordName,
                let numbers = try? record.values(forAttribute: kODAttributeTypeUniqueID) as? [String],
                let id = numbers.first.flatMap({ uid_t($0) })
            else { continue }
            // The system's own accounts start with an underscore, or are below 500.
            if id >= 500, !name.hasPrefix("_") { found.append((name, id)) }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// The names asked of the system so far, each with the user it names or none.
    private static let asked = OSAllocatedUnfairLock<[String: uid_t?]>(initialState: [:])

    /// The user `name` names, as the system tells it (a directory's users too), asked once: a search is read again
    /// at every key typed, its `owner:` word with it.
    static func id(named name: String) -> uid_t? {
        if let known = asked.withLock({ $0[name] }) { return known }
        let found = getpwnam(name).map { $0.pointee.pw_uid }
        asked.withLock {
            // Each start of a name typed is one: what was typed long ago is of no use.
            if $0.count >= 256 { $0.removeAll() }
            $0[name] = .some(found)
        }
        return found
    }
}
