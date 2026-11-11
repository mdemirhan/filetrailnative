import Darwin
import Foundation

/// An eject that failed: the errno, the volume (or disk, "/dev/disk4") that failed, which with `wholeDisk`
/// may be another volume of the disk, and Disk Arbitration's own sentence when it gave one.
public struct EjectError: Error, Equatable, Sendable {
    public var errnum: Int32
    public var path: String
    public var reason: String?

    public init(errnum: Int32, path: String, reason: String? = nil) {
        self.errnum = errnum
        self.path = path
        self.reason = reason
    }
}
