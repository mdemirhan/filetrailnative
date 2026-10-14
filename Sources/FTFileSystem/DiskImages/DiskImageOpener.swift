// Port of apps/desktop/src/main/diskImages.ts (createDiskImageOpener)
import Foundation

public struct HdiutilResult: Sendable, Equatable {
    public var ok: Bool
    public var stdout: String
    public var stderr: String

    public init(ok: Bool, stdout: String, stderr: String) {
        self.ok = ok
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct DiskImageOpenResponse: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case opened, handedOff, busy, failed
    }

    public var status: Status
    public var volumePath: String?
    public var reason: String?

    public init(status: Status, volumePath: String? = nil, reason: String? = nil) {
        self.status = status
        self.volumePath = volumePath
        self.reason = reason
    }
}

/// Opening a disk image: File Trail mounts it itself, with hdiutil, so that no Finder window opens on the disk
/// (as one does when macOS's DiskImageMounter mounts it), and the window opens the disk in a tab instead. An
/// image that asks for something first, a password or agreeing to a licence, is handed to DiskImageMounter,
/// which asks in its own windows: hdiutil would ask in a Terminal it doesn't have.
public actor DiskImageOpener {
    /// Runs hdiutil with nothing to read from: a question it asks on the command line (a licence to agree to)
    /// is answered with "no" instead of waiting.
    public typealias RunHdiutil = @Sendable ([String]) async -> HdiutilResult
    /// Opens the image with DiskImageMounter, as Finder would. It is named, not left to macOS's choice of app:
    /// File Trail may be the one chosen for disk images.
    public typealias OpenWithDiskImageMounter = @Sendable (String) async throws -> Void

    private let runHdiutil: RunHdiutil
    private let openWithDiskImageMounter: OpenWithDiskImageMounter
    private let onMounted: @Sendable () -> Void
    private let logError: @Sendable (String) -> Void
    /// Images being mounted now: opening one again meanwhile (a second double-click) does nothing, rather than
    /// opening its disk twice.
    private var opening: Set<String> = []

    /// - Parameter onMounted: a disk was mounted: the list of disks is read again, so it shows at once.
    public init(
        runHdiutil: @escaping RunHdiutil = HdiutilProcess.run,
        openWithDiskImageMounter: @escaping OpenWithDiskImageMounter = HdiutilProcess.openWithDiskImageMounter,
        onMounted: @escaping @Sendable () -> Void,
        logError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.runHdiutil = runHdiutil
        self.openWithDiskImageMounter = openWithDiskImageMounter
        self.onMounted = onMounted
        self.logError = logError
    }

    public func open(_ imagePath: String) async -> DiskImageOpenResponse {
        if opening.contains(imagePath) {
            return DiskImageOpenResponse(status: .busy)
        }
        opening.insert(imagePath)
        defer { opening.remove(imagePath) }
        return await mount(imagePath)
    }

    private func handOff(_ imagePath: String) async -> DiskImageOpenResponse {
        do {
            try await openWithDiskImageMounter(imagePath)
            return DiskImageOpenResponse(status: .handedOff)
        } catch {
            logError("opening a disk image with DiskImageMounter failed: \(imagePath): \(error)")
            return DiskImageOpenResponse(status: .failed)
        }
    }

    private func mount(_ imagePath: String) async -> DiskImageOpenResponse {
        // A password is asked for before hdiutil reads anything else of the image, in a window of its own that
        // File Trail can't tell apart from a stuck mount: it is checked first, and only this check never asks.
        let encrypted = await runHdiutil(["isencrypted", "-plist", imagePath])
        if encrypted.ok, HdiutilOutput.boolean(in: encrypted.stdout, key: "encrypted") == true {
            return await handOff(imagePath)
        }
        let info = await runHdiutil(["imageinfo", "-plist", imagePath])
        if info.ok, HdiutilOutput.boolean(in: info.stdout, key: "Software License Agreement") == true {
            return await handOff(imagePath)
        }
        // An image already mounted is attached again in a moment, which tells where its disk is.
        let attached = await runHdiutil(["attach", "-plist", "-noautoopen", imagePath])
        guard attached.ok else {
            let failure = HdiutilOutput.attachFailure(stderr: attached.stderr)
            // Something it would have asked, which the checks above didn't foresee.
            if failure.canceled {
                return await handOff(imagePath)
            }
            logError("mounting a disk image failed: \(imagePath): \(attached.stderr)")
            return DiskImageOpenResponse(status: .failed, reason: failure.reason)
        }
        onMounted()
        // An image with several volumes opens the first by name, as the sidebar lists them; the others are
        // there under Locations.
        let mountPoints = HdiutilOutput.strings(in: attached.stdout, key: "mount-point")
        guard let volumePath = Self.firstByName(mountPoints) else {
            return DiskImageOpenResponse(status: .failed, reason: "no mountable file systems")
        }
        return DiskImageOpenResponse(status: .opened, volumePath: volumePath)
    }

    static func firstByName(_ paths: [String]) -> String? {
        naturallySorted(paths) { path in
            path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        }.first
    }
}
