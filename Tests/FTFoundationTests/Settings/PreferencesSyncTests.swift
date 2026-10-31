// Port of apps/desktop/src/renderer/hooks/usePreferencesSync.test.tsx: a manual clock stands for the fake timers
import Testing

@testable import FTFoundation

@MainActor
struct PreferencesSyncTests {
    /// Timers that run when the test moves time on.
    @MainActor
    final class Clock {
        private var now = 0.0
        private var timers: [(id: Int, at: Double, work: @MainActor () -> Void)] = []
        private var nextID = 0

        func schedule(_ milliseconds: Double, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            nextID += 1
            let id = nextID
            timers.append((id, now + milliseconds, work))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }

        func advance(_ milliseconds: Double) {
            now += milliseconds
            let due = timers.filter { $0.at <= now }
            timers.removeAll { $0.at <= now }
            for timer in due { timer.work() }
        }
    }

    @MainActor
    final class Writes {
        var patches: [PreferencesPatch] = []
        var refuseNext = false

        func write(_ patch: PreferencesPatch) -> Bool {
            patches.append(patch)
            if refuseNext {
                refuseNext = false
                return false
            }
            return true
        }
    }

    private func make() -> (PreferencesSync, Clock, Writes) {
        let clock = Clock()
        let writes = Writes()
        let sync = PreferencesSync(write: { writes.write($0) }, schedule: { clock.schedule($0, $1) })
        return (sync, clock, writes)
    }

    // T-447f9f1a F-891 B-DLG-169
    @Test func diffsOnlyKeysWhoseValuesChanged() {
        let favorites = JSONNode.array([.object(["path": .string("/Users/demo"), "icon": .string("home")])])
        #expect(
            PreferencesSync.diff(
                ["theme": .string("auto"), "accent": .string("#d4845a"), "favorites": favorites],
                ["theme": .string("dark"), "accent": .string("#d4845a"), "favorites": favorites])
                == ["theme": .string("dark")])
    }

    // T-868a1763 F-891 B-DLG-169
    // B-TREE-046
    @Test func writesWhatIsWaitingAtOnceWhenTheWindowCloses() {
        let (sync, clock, writes) = make()
        sync.changed(["lastVisitedPath": .string("/Users/demo")])
        sync.markSynced(["lastVisitedPath": .string("/Users/demo")])
        sync.changed(["lastVisitedPath": .string("/Users/demo/Sub")])
        sync.flushPending()
        #expect(writes.patches == [["lastVisitedPath": .string("/Users/demo/Sub")]])
        // Nothing is left to write when the wait would have ended.
        clock.advance(300)
        #expect(writes.patches.count == 1)
    }

    // T-5725a0d1 F-891 B-DLG-169 B-DLG-171 B-DLG-173
    // B-TREE-046
    @Test func writesOnlyChangedKeysAfterTheDebounceAndDoesNotEchoRemoteChanges() {
        let (sync, clock, writes) = make()
        sync.markSynced(["theme": .string("auto"), "accent": .string("#d4845a")])
        sync.changed(["theme": .string("auto"), "accent": .string("#d4845a")])
        #expect(!sync.isPending)
        sync.changed(["theme": .string("dark"), "accent": .string("#d4845a")])
        clock.advance(299)
        #expect(writes.patches.isEmpty)
        clock.advance(1)
        #expect(writes.patches == [["theme": .string("dark")]])

        // A change made in the Settings window is applied here and not written back; window keys are not taken.
        let applied = sync.remote(["accent": .string("#4a9eff"), "openTabs": .array([])])
        #expect(applied == ["accent": .string("#4a9eff")])
        sync.changed(["theme": .string("dark"), "accent": .string("#4a9eff")])
        clock.advance(300)
        #expect(writes.patches.count == 1)
    }

    // T-190d650a F-891 B-DLG-170
    @Test func sendsAValueAgainWithTheNextChangeWhenItsWriteWasRefused() {
        let (sync, clock, writes) = make()
        sync.markSynced(["theme": .string("auto"), "accent": .string("#d4845a")])
        writes.refuseNext = true
        sync.changed(["theme": .string("dark"), "accent": .string("#d4845a")])
        clock.advance(300)
        #expect(writes.patches.count == 1)

        // The theme was not saved, so it goes out again with the accent that changes next.
        sync.changed(["theme": .string("dark"), "accent": .string("#007aff")])
        clock.advance(300)
        #expect(writes.patches.count == 2)
        #expect(writes.patches.last == ["theme": .string("dark"), "accent": .string("#007aff")])
    }
}
