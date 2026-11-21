// What an earlier launch saved under another spelling of a path, taken over in the state files: each written once
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct SavedSpellingsStateTests {
    typealias Kit = StateTestKit
    typealias Saved = SavedPathsStateTests

    // What is saved under the old spelling goes to the listing's: each file is written once with it, holds the old
    // spelling no more, and a second take-over finds nothing and writes nothing.
    @Test func takingASpellingOverWritesEachFileOnceAndNotAgain() throws {
        try Kit.withFolder { folder in
            Saved.save(under: Saved.decomposed, in: folder)
            let files = RecordingFileSystem()
            let timer = ManualTimer()
            let store = Kit.store(Kit.statePath(folder), fileSystem: files, timer: timer)
            let (old, path) = (DiskPath(Saved.decomposed), DiskPath(Saved.composed))
            func takeOver() {
                store.folderVisitsRespelled(from: Saved.decomposed, to: Saved.composed)
                store.destinationsRespelled(from: Saved.decomposed, to: Saved.composed)
                store.updateFolderViews { $0.respell(from: Saved.decomposed, to: Saved.composed) }
                let preferences = store.preferences()
                let favorites = SavedSpellings.favorites(preferences.favorites, from: old, to: path)
                let workspaces = SavedSpellings.workspaces(preferences.workspaces, from: old, to: path)
                guard favorites != nil || workspaces != nil else { return }
                store.update {
                    if let favorites { $0.favorites = favorites }
                    if let workspaces { $0.workspaces = workspaces }
                }
            }

            takeOver()
            store.flush()

            #expect(files.written.sorted() == Saved.fileNames.sorted())
            let texts = try Saved.texts(folder)
            // The tabs a window had open are the window's to save, as it opens them: they are still as they were.
            #expect(Saved.holds(texts[0], Saved.decomposed))
            #expect(texts.allSatisfy { Saved.holds($0, Saved.composed) })
            #expect(texts.dropFirst().allSatisfy { !Saved.holds($0, Saved.decomposed) })

            takeOver()
            #expect(timer.pendingDelays == [])
            store.flush()
            #expect(files.written.count == Saved.fileNames.count)
            #expect(try Saved.texts(folder) == texts)

            // Read again, each is its folder's as the listing spells it, once.
            let reloaded = Kit.store(Kit.statePath(folder))
            func bytes(_ paths: [String?]) -> [[UInt8]?] { paths.map { $0.map { Array($0.utf8) } } }
            #expect(bytes(reloaded.preferences().favorites.map(\.path)) == bytes(["/Applications", Saved.composed]))
            #expect(
                bytes(reloaded.preferences().workspaces[0].session.openTabs.map(\.path))
                    == bytes([Saved.composed, "/Users/demo/Documents"]))
            #expect(reloaded.folderViews().own(Saved.decomposed) == nil)
            #expect(reloaded.folderViews().own(Saved.composed)?.subfolders == true)
            #expect(bytes(reloaded.destinations().map(\.path)) == bytes([Saved.composed]))
            #expect(bytes(reloaded.folders().map(\.path)) == bytes([Saved.composed, "/Users/demo/Documents"]))
            // The folders' views are in the order they were in: only the path's bytes changed.
            #expect(
                bytes(reloaded.folderViews().all.map(\.path))
                    == bytes([
                        "/Users/demo/Pictures", "/Users/demo/Zebra", "/Users/demo/apple", Saved.composed,
                        Saved.decomposed + "/2019",
                    ]))
        }
    }
}
