// Port of volume_physical_disk in packages/native-fs/src/native_volumes.c
import Foundation
import IOKit

/// The physical disk a volume's device is on, from the I/O Registry, which the kernel answers without
/// asking the disk.
public struct PhysicalDisk: Sendable, Equatable {
    /// "disk5": the same for every volume of a partitioned drive or an APFS container.
    public var whole: String
    /// Whether Finder shows an Eject button: it can be ejected or removed, or isn't inside the Mac.
    public var ejectable: Bool

    public init(whole: String, ejectable: Bool) {
        self.whole = whole
        self.ejectable = ejectable
    }

    // The values of kIOMediaWholeKey, kIOMediaEjectableKey, kIOMediaRemovableKey, kIOBSDNameKey, kIOMediaClass.
    private static let wholeKey = "Whole"
    private static let ejectableKey = "Ejectable"
    private static let removableKey = "Removable"
    private static let bsdNameKey = "BSD Name"
    private static let mediaClass = "IOMedia"

    private static func registryBool(_ entry: io_registry_entry_t, _ key: String) -> Bool {
        guard
            let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return (value as? Bool) ?? false
    }

    /// `bsdName` is the device without "/dev/" ("disk5s1"). nil when the registry doesn't know it.
    public static func lookup(bsdName: String) -> PhysicalDisk? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        // The last whole disk going up the stack: the volume's own device may be one (a disk without
        // partitions, an APFS container's synthesized disk); the physical disk is the last.
        var top: io_registry_entry_t = IO_OBJECT_NULL
        if registryBool(media, wholeKey) {
            IOObjectRetain(media)
            top = media
        }
        var parents: io_iterator_t = IO_OBJECT_NULL
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        if IORegistryEntryCreateIterator(media, kIOServicePlane, options, &parents) == KERN_SUCCESS {
            var entry = IOIteratorNext(parents)
            while entry != IO_OBJECT_NULL {
                if IOObjectConformsTo(entry, mediaClass) != 0, registryBool(entry, wholeKey) {
                    if top != IO_OBJECT_NULL { IOObjectRelease(top) }
                    top = entry
                } else {
                    IOObjectRelease(entry)
                }
                entry = IOIteratorNext(parents)
            }
            IOObjectRelease(parents)
        }
        guard top != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(top) }

        guard
            let name = IORegistryEntryCreateCFProperty(top, bsdNameKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        else { return nil }

        var isInternal = false
        if let characteristics = IORegistryEntrySearchCFProperty(
            top, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault, options)
            as? [String: Any]
        {
            isInternal = (characteristics["Physical Interconnect Location"] as? String) == "Internal"
        }
        let ejectable = registryBool(top, ejectableKey) || registryBool(top, removableKey) || !isInternal
        return PhysicalDisk(whole: name, ejectable: ejectable)
    }
}
