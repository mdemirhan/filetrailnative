// Port of apps/desktop/src/renderer/hooks/useEjectVolume.test.ts
import FTFileSystem
import Foundation
import Testing

@testable import FTAppKit

@MainActor
private final class RecordingPresenter: EjectPresenter {
    var which: [(name: String, others: [String])] = []
    var busy: [EjectNotice] = []
    var notices: [EjectNotice] = []
    var whichAnswer: ((EjectWhichVolumesAnswer) -> Void)?
    var busyAnswer: ((EjectBusyAnswer) -> Void)?

    func askWhichVolumes(name: String, otherNames: [String], answer: @escaping (EjectWhichVolumesAnswer) -> Void) {
        which.append((name, otherNames))
        whichAnswer = answer
    }

    func askBusy(_ notice: EjectNotice, answer: @escaping (EjectBusyAnswer) -> Void) {
        busy.append(notice)
        busyAnswer = answer
    }

    func show(_ notice: EjectNotice) { notices.append(notice) }
}

@MainActor
private final class Harness {
    let presenter = RecordingPresenter()
    let coordinator: EjectCoordinator
    var requests: [EjectRequest] = []
    var responses: [EjectResponse]

    init(volumes: [Volume], responses: [EjectResponse] = []) {
        self.responses = responses
        var box: Harness?
        coordinator = EjectCoordinator(
            volumes: { volumes },
            eject: { request in
                await MainActor.run {
                    box?.requests.append(request)
                    return box?.responses.isEmpty == false
                        ? box!.responses.removeFirst() : EjectResponse(status: .ejected)
                }
            })
        box = self
        coordinator.presenter = presenter
    }
}

private func volume(_ name: String, _ disk: String) -> Volume {
    Volume(
        path: "/Volumes/\(name)", name: name, isLocal: true, isReadOnly: false, fileSystem: "hfs", canEject: true,
        disk: disk)
}

struct EjectCoordinatorTests {
    // T-ada36497 F-731 B-TREE-165 B-TREE-172
    @Test @MainActor func ejectsADiskOfItsOwnWithItsWholeDiskAtOnce() async {
        let harness = Harness(volumes: [volume("USB", "disk4")])
        harness.coordinator.requestEject(path: "/Volumes/USB")
        await settleTasks()
        #expect(harness.requests == [EjectRequest(path: "/Volumes/USB", wholeDisk: true, force: false)])
        #expect(harness.presenter.which.isEmpty)
        #expect(harness.coordinator.ejectingPaths.isEmpty)
    }

    // T-21da80a1 B-TREE-167
    @Test @MainActor func doesNothingForAPathThatIsNotAListedVolume() async {
        let harness = Harness(volumes: [volume("USB", "disk4")])
        harness.coordinator.requestEject(path: "/Volumes/Missing")
        await settleTasks()
        #expect(harness.requests.isEmpty)
    }

    // T-6663df6c B-TREE-170 B-TREE-171
    @Test @MainActor func asksAboutTheOtherVolumesOfTheDiskThenEjectsAllOrOnlyThisOne() async {
        let harness = Harness(volumes: [volume("Photos", "disk7"), volume("Video", "disk7")])
        harness.coordinator.requestEject(path: "/Volumes/Photos")
        #expect(harness.requests.isEmpty)
        #expect(harness.presenter.which.count == 1)
        #expect(harness.presenter.which.first?.name == "Photos")
        #expect(harness.presenter.which.first?.others == ["Video"])

        harness.coordinator.answerWhichVolumes(path: "/Volumes/Photos", .one)
        await settleTasks()
        harness.coordinator.answerWhichVolumes(path: "/Volumes/Photos", .all)
        await settleTasks()
        harness.coordinator.answerWhichVolumes(path: "/Volumes/Photos", .cancel)
        await settleTasks()
        #expect(
            harness.requests == [
                EjectRequest(path: "/Volumes/Photos", wholeDisk: false, force: false),
                EjectRequest(path: "/Volumes/Photos", wholeDisk: true, force: false),
            ])
    }

    // T-80c34c9d B-TREE-173 B-TREE-174
    @Test @MainActor func asksAboutADiskInUseAndGoesOnFromTheVolumeInUseWhenForced() async {
        let harness = Harness(
            volumes: [volume("Photos", "disk7"), volume("Video", "disk7")],
            responses: [EjectResponse(status: .busy, failedPath: "/Volumes/Video", code: "EBUSY")])
        harness.coordinator.answerWhichVolumes(path: "/Volumes/Photos", .all)
        await settleTasks()
        #expect(harness.presenter.busy.count == 1)
        #expect(
            harness.presenter.busy.first?.title
                == "The disk \u{201C}Video\u{201D} wasn\u{2019}t ejected because one or more programs may be using it.")

        // Photos is unmounted already: Force Eject carries on from Video.
        harness.presenter.busyAnswer?(.force)
        await settleTasks()
        #expect(harness.requests.last == EjectRequest(path: "/Volumes/Video", wholeDisk: true, force: true))
        harness.presenter.busyAnswer?(.cancel)
        await settleTasks()
        #expect(harness.requests.count == 2)
    }

    // T-3a1e6407 B-TREE-176
    @Test @MainActor func tellsOfAnyOtherFailureInANotice() async {
        let harness = Harness(
            volumes: [volume("USB", "disk4")],
            responses: [EjectResponse(status: .failed, failedPath: "/dev/disk4", code: "EIO")])
        harness.coordinator.requestEject(path: "/Volumes/USB")
        await settleTasks()
        #expect(harness.presenter.notices.count == 1)
        #expect(harness.presenter.notices.first?.title == "The disk \u{201C}USB\u{201D} couldn\u{2019}t be ejected.")
        #expect(harness.presenter.notices.first?.message == "An unexpected error occurred (EIO).")
    }

    // T-ada36497 B-TREE-172
    // B-TREE-166
    @Test @MainActor func ignoresARequestForADiskAlreadyBeingEjectedAndReleasesIt() async {
        let gate = Gate()
        var count = 0
        let coordinator = EjectCoordinator(
            volumes: { [volume("USB", "disk4")] },
            eject: { _ in
                await MainActor.run { count += 1 }
                await gate.wait()
                return EjectResponse(status: .failed, failedPath: "/dev/disk4", code: "EIO")
            })
        let first = Task { await coordinator.run(path: "/Volumes/USB", wholeDisk: true, force: false) }
        await settleTasks()
        #expect(coordinator.ejectingPaths == ["/Volumes/USB"])
        await coordinator.run(path: "/Volumes/USB", wholeDisk: true, force: false)
        #expect(count == 1)
        await gate.open()
        await first.value
        #expect(coordinator.ejectingPaths.isEmpty)
    }
}

private actor Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

@MainActor
private func settleTasks() async {
    for _ in 0..<40 { await Task.yield() }
}
