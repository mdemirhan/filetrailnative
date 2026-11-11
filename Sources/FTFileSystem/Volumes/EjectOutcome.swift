import Foundation

public struct EjectRequest: Sendable, Equatable {
    public var path: String
    public var wholeDisk: Bool
    public var force: Bool

    public init(path: String, wholeDisk: Bool, force: Bool) {
        self.path = path
        self.wholeDisk = wholeDisk
        self.force = force
    }
}

/// How an eject went: `busy` names the volume in use (with `wholeDisk`, it may be another on the same disk);
/// `failed` carries the errno and Disk Arbitration's own sentence when there was one.
public struct EjectResponse: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case ejected, busy, failed
    }

    public var status: Status
    public var failedPath: String?
    public var errnum: Int32?
    public var reason: String?

    public init(status: Status, failedPath: String? = nil, errnum: Int32? = nil, reason: String? = nil) {
        self.status = status
        self.failedPath = failedPath
        self.errnum = errnum
        self.reason = reason
    }
}

public enum EjectOutcome {
    /// Ejects a disk with `eject` and says how it went. A volume already gone counts as ejected: it may have
    /// been ejected elsewhere while the button was pressed.
    public static func ejectVolume(
        _ request: EjectRequest,
        using eject: (String, _ force: Bool, _ wholeDisk: Bool) async throws -> Void = {
            try await VolumeEjector.eject(path: $0, force: $1, wholeDisk: $2)
        }
    ) async -> EjectResponse {
        do {
            try await eject(request.path, request.force, request.wholeDisk)
        } catch {
            let failure = error as? EjectError
            let errnum = failure?.errnum
            let failedPath = failure?.path ?? request.path
            if errnum == ENOENT, failedPath == request.path {
                return EjectResponse(status: .ejected)
            }
            let reason = failure?.reason.flatMap { $0.isEmpty ? nil : $0 }
            return EjectResponse(
                status: errnum == EBUSY ? .busy : .failed, failedPath: failedPath, errnum: errnum, reason: reason)
        }
        return EjectResponse(status: .ejected)
    }
}
