import Foundation
import Testing

@testable import FTFileSystem

private let deprecated = "hdiutil: WARNING: 'hdiutil attach ...' is deprecated.\n"

private func plist(_ body: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict>\n\(body)\n</dict>\n</plist>\n"
}

/// What `hdiutil attach -plist` prints for an APFS image: the partition map and container without a mount
/// point, the volume with one.
private func attachOutput(_ mountPoints: String...) -> String {
    let volumes = mountPoints.map { mountPoint in
        """

        \t\t<dict>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>/dev/disk6s1</string>
        \t\t\t<key>mount-point</key>
        \t\t\t<string>\(mountPoint)</string>
        \t\t\t<key>potentially-mountable</key>
        \t\t\t<true/>
        \t\t\t<key>volume-kind</key>
        \t\t\t<string>apfs</string>
        \t\t</dict>
        """
    }.joined()
    return plist(
        """
        \t<key>system-entities</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>content-hint</key>
        \t\t\t<string>GUID_partition_scheme</string>
        \t\t\t<key>dev-entry</key>
        \t\t\t<string>/dev/disk5</string>
        \t\t\t<key>potentially-mountable</key>
        \t\t\t<false/>
        \t\t</dict>\(volumes)
        \t</array>
        """)
}

private func ok(_ stdout: String) -> HdiutilResult { HdiutilResult(ok: true, stdout: stdout, stderr: deprecated) }
private func failed(_ stderr: String) -> HdiutilResult {
    HdiutilResult(ok: false, stdout: "", stderr: deprecated + stderr)
}

/// A flag the attach waits on, to hold a mount half done.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var handedOff: [String] = []
    private var mounted = 0
    private var attaches = 0

    func call(_ args: [String]) { lock.withLock { recorded.append(args) } }
    func handOff(_ path: String) { lock.withLock { handedOff.append(path) } }
    func didMount() { lock.withLock { mounted += 1 } }
    func attachCount() -> Int {
        lock.withLock {
            attaches += 1
            return attaches
        }
    }

    var calls: [[String]] { lock.withLock { recorded } }
    var firstWords: [String] { calls.compactMap(\.first) }
    var handOffs: [String] { lock.withLock { handedOff } }
    var mountedCount: Int { lock.withLock { mounted } }
}

private struct Answers {
    var encrypted = false
    var licence = false
    var attach: @Sendable (Int) async -> HdiutilResult
}

private func setUp(_ answers: Answers) -> (opener: DiskImageOpener, recorder: Recorder) {
    let recorder = Recorder()
    let opener = DiskImageOpener(
        runHdiutil: { args in
            recorder.call(args)
            switch args[0] {
            case "isencrypted":
                return ok(plist("<key>encrypted</key>\n<\(answers.encrypted ? "true" : "false")/>"))
            case "imageinfo":
                return ok(plist("<key>Software License Agreement</key>\n<\(answers.licence ? "true" : "false")/>"))
            default:
                return await answers.attach(recorder.attachCount())
            }
        },
        openWithDiskImageMounter: { path in recorder.handOff(path) },
        onMounted: { recorder.didMount() })
    return (opener, recorder)
}

@Suite struct DiskImageOpenerTests {
    // T-4b359f14
    @Test func mountsTheImageWithoutAFinderWindowAndSaysWhereItsDiskIs() async {
        let (opener, recorder) = setUp(Answers { _ in ok(attachOutput("/Volumes/Install")) })
        let response = await opener.open("/Users/demo/Install.dmg")
        #expect(response == DiskImageOpenResponse(status: .opened, volumePath: "/Volumes/Install", reason: nil))
        #expect(recorder.calls.last == ["attach", "-plist", "-noautoopen", "/Users/demo/Install.dmg"])
        #expect(recorder.mountedCount == 1)
    }

    // T-101d805d
    @Test func opensTheFirstVolumeByNameWhenTheImageHasSeveral() async {
        let (opener, _) = setUp(
            Answers { _ in ok(attachOutput("/Volumes/Tools 10", "/Volumes/Tools 9", "/Volumes/apps")) })
        #expect(await opener.open("/Users/demo/Bundle.dmg").volumePath == "/Volumes/apps")
    }

    // T-4919f6f3
    @Test func handsAnImageThatAsksForAPasswordToDiskImageMounterWithoutMountingIt() async {
        let (opener, recorder) = setUp(
            Answers(encrypted: true) { _ in ok(attachOutput("/Volumes/Secret")) })
        let response = await opener.open("/Users/demo/Secret.dmg")
        #expect(response == DiskImageOpenResponse(status: .handedOff, volumePath: nil, reason: nil))
        #expect(recorder.handOffs == ["/Users/demo/Secret.dmg"])
        // Only the check that never asks for the password ran.
        #expect(recorder.firstWords == ["isencrypted"])
    }

    // T-fe7b25ff
    @Test func handsAnImageWithALicenceToAgreeToToDiskImageMounter() async {
        let (opener, recorder) = setUp(
            Answers(licence: true) { _ in ok(attachOutput("/Volumes/Licensed")) })
        #expect(await opener.open("/Users/demo/Licensed.dmg").status == .handedOff)
        #expect(recorder.handOffs.count == 1)
        #expect(recorder.firstWords == ["isencrypted", "imageinfo"])
    }

    // T-177794c7
    @Test func handsItOverWhenHdiutilGivesUpOnAQuestionTheChecksDidntForesee() async {
        let (opener, recorder) = setUp(Answers { _ in failed("hdiutil: attach canceled\n") })
        #expect(await opener.open("/Users/demo/Odd.dmg").status == .handedOff)
        #expect(recorder.handOffs.count == 1)
        #expect(recorder.mountedCount == 0)
    }

    // T-bf6ef132
    @Test func saysWhyAnImageCouldntBeMounted() async {
        let (opener, recorder) = setUp(
            Answers { _ in failed("hdiutil: attach failed - no mountable file systems\n") })
        let response = await opener.open("/Users/demo/Broken.dmg")
        #expect(
            response
                == DiskImageOpenResponse(status: .failed, volumePath: nil, reason: "no mountable file systems"))
        #expect(recorder.handOffs.isEmpty)
    }

    @Test func anImageWithNoMountPointFails() async {
        let (opener, _) = setUp(Answers { _ in ok(attachOutput()) })
        #expect(
            await opener.open("/Users/demo/Empty.dmg")
                == DiskImageOpenResponse(status: .failed, volumePath: nil, reason: "no mountable file systems"))
    }

    // T-b3942d55
    @Test func doesNothingForAnImageOpenedAgainWhileItIsBeingMounted() async throws {
        let gate = Gate()
        let (opener, recorder) = setUp(
            Answers { attempt in
                // The first attach waits until it is let go; later ones answer at once.
                if attempt == 1 { await gate.wait() }
                return ok(attachOutput("/Volumes/Install"))
            })

        let first = Task { await opener.open("/Users/demo/Install.dmg") }
        while !(await gate.isWaiting) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await opener.open("/Users/demo/Install.dmg").status == .busy)
        #expect(recorder.firstWords.filter { $0 == "attach" }.count == 1)
        await gate.open()
        #expect(await first.value.status == .opened)
        // Once mounted it can be opened again: its disk opens once more.
        #expect(await opener.open("/Users/demo/Install.dmg").status == .opened)
    }
}
