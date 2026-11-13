import Foundation
import Testing
import os

@testable import FTFileSystem

private let deprecated = "hdiutil: WARNING: 'hdiutil attach ...' is deprecated.\n"

private func plist(_ body: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\(body)\n</dict>\n</plist>\n"
}

private func attachOutput(_ mountPoints: String...) -> String {
    let entries = mountPoints.map { "<dict><key>mount-point</key>\n<string>\($0)</string></dict>" }.joined()
    return plist(
        "<key>system-entities</key>\n<array>\n<dict><key>dev-entry</key><string>/dev/disk5</string></dict>\(entries)</array>"
    )
}

@Suite struct HdiutilOutputTests {
    @Test func readsEveryValueOfAKeyWithXMLEscapesUndone() {
        #expect(
            HdiutilOutput.strings(in: attachOutput("/Volumes/Tom &amp; Jerry", "/Volumes/A&#38;B"), key: "mount-point")
                == ["/Volumes/Tom & Jerry", "/Volumes/A&B"])
        #expect(HdiutilOutput.strings(in: attachOutput(), key: "mount-point") == [])
    }

    @Test func readsABooleanOrNilWhenTheKeyIsntThere() {
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key>\n\t<true/>"), key: "encrypted") == true)
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key><false/>"), key: "encrypted") == false)
        #expect(HdiutilOutput.boolean(in: plist(""), key: "encrypted") == nil)
        // Only a boolean counts.
        #expect(HdiutilOutput.boolean(in: plist("<key>encrypted</key><integer>1</integer>"), key: "encrypted") == nil)
    }

    @Test func outputThatIsNotAPlistReadsAsNothing() {
        #expect(HdiutilOutput.strings(in: "hdiutil: nope", key: "mount-point") == [])
        #expect(HdiutilOutput.boolean(in: "", key: "encrypted") == nil)
    }

    @Test func readsWhyAnAttachFailedPastTheDeprecationWarning() {
        let image = HdiutilOutput.attachFailure(
            stderr: "\(deprecated)hdiutil: attach failed - image not recognized\n")
        #expect(image.canceled == false)
        #expect(image.reason == "image not recognized")
        let canceled = HdiutilOutput.attachFailure(stderr: "\(deprecated)hdiutil: attach canceled\n")
        #expect(canceled.canceled == true)
        #expect(canceled.reason == nil)
        let empty = HdiutilOutput.attachFailure(stderr: "")
        #expect(empty.canceled == false)
        #expect(empty.reason == nil)
    }
}

@Suite struct DiskImageNamesTests {
    @Test func namesTheImageAndGivesHdiutilsReasonAsASentence() {
        let notice = DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: "no mountable file systems")
        #expect(notice.title == "The disk image \u{201C}Broken.dmg\u{201D} couldn\u{2019}t be opened.")
        #expect(notice.message == "No mountable file systems.")
    }

    @Test func saysAnUnexpectedErrorOccurredWithoutAReason() {
        #expect(
            DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: nil).message
                == "An unexpected error occurred.")
        #expect(
            DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: "  . ").message
                == "An unexpected error occurred.")
        #expect(DiskImageNames.describeFailure(path: "/Users/demo/Broken.dmg", reason: " busy. ").message == "Busy.")
    }

    @Test func knowsDiskImagesByTheExtensionsDiskImageMounterOpensInAnyCase() {
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/Install.dmg"))
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/Backup.SPARSEBUNDLE"))
        #expect(DiskImageNames.isDiskImagePath("/Users/demo/ubuntu.iso"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/notes.txt"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/.dmg"))
        #expect(!DiskImageNames.isDiskImagePath("/Users/demo/dmg"))
        #expect(DiskImageNames.extensions.count == 12)
    }
}

/// Opened once by the test; whoever waits on it before or after goes on then.
private final class AsyncGate: Sendable {
    private let state = OSAllocatedUnfairLock<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>(
        initialState: (false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let goNow = state.withLock { state in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if goNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor @Suite struct OpenFileEntryPointTests {
    // The app's open-file handling: what `describe` says of each, queued until windows exist.
    @Test func takesWhatItIsToldAndWaitsForTheWindows() async {
        var opened: [String] = []
        let entry = OpenFileEntryPoint(
            describe: { $0 == "/a/gone" ? nil : OpenRequest(path: $0, kind: .diskImage) },
            open: { opened.append($0.path) })
        #expect(
            await entry.open(["/a/gone", "/a/Install.dmg"]).value == [
                OpenRequest(path: "/a/Install.dmg", kind: .diskImage)
            ])
        #expect(opened.isEmpty)
        entry.startupWindowsOpened()
        #expect(opened == ["/a/Install.dmg"])
        _ = await entry.open(["/a/c.iso"]).value
        #expect(opened == ["/a/Install.dmg", "/a/c.iso"])
    }

    // An item on a disk that doesn't answer holds the items given after it only for a while: they open, and it opens
    // once its disk answers.
    @Test(.timeLimit(.minutes(1))) func anItemWhoseDiskDoesntAnswerHoldsUpTheItemsAfterItOnlyForAWhile() async {
        let slowAnswers = DispatchSemaphore(value: 0)
        let waited = AsyncGate()
        var opened: [String] = []
        let entry = OpenFileEntryPoint(
            describe: { path in
                if path == "/slow/a.txt" { slowAnswers.wait() }
                return OpenRequest(path: path, kind: .reveal)
            }, open: { opened.append($0.path) }, waitedLongEnough: { await waited.wait() })
        entry.startupWindowsOpened()
        let slow = entry.open(["/slow/a.txt"])
        let fast = entry.open(["/fast/b.txt"])
        waited.open()
        #expect(await fast.value.map(\.path) == ["/fast/b.txt"])
        #expect(opened == ["/fast/b.txt"])
        slowAnswers.signal()
        #expect(await slow.value.map(\.path) == ["/slow/a.txt"])
        #expect(opened == ["/fast/b.txt", "/slow/a.txt"])
    }

    // An item on a disk slow to answer holds up neither the main thread nor the items given before it; the items given
    // after it wait for it, so they open in the order given.
    @Test func anItemSlowToLookAtHoldsUpOnlyTheItemsAfterIt() async {
        let slowAnswers = DispatchSemaphore(value: 0)
        let fastLooked = DispatchSemaphore(value: 0)
        var opened: [String] = []
        let entry = OpenFileEntryPoint(
            describe: { path in
                if path == "/slow/a.txt" { slowAnswers.wait() }
                defer { if path == "/fast/b.txt" { fastLooked.signal() } }
                return OpenRequest(path: path, kind: .reveal)
            }, open: { opened.append($0.path) })
        entry.startupWindowsOpened()
        _ = await entry.open(["/before/c.txt"]).value
        let slow = entry.open(["/slow/a.txt"])
        let fast = entry.open(["/fast/b.txt"])
        await withCheckedContinuation { looked in
            DispatchQueue.global().async {
                fastLooked.wait()
                looked.resume()
            }
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(opened == ["/before/c.txt"])

        slowAnswers.signal()
        #expect(await fast.value.map(\.path) == ["/fast/b.txt"])
        #expect(await slow.value.map(\.path) == ["/slow/a.txt"])
        #expect(opened == ["/before/c.txt", "/slow/a.txt", "/fast/b.txt"])
    }
}
