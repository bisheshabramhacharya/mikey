import Foundation

/// Free-space probe for the volume hosting the Archive. Behind a protocol so
/// tests can fake low disk. (SPEC §7: refuse to start under ~500 MB free.)
public protocol DiskSpaceProbing: Sendable {
    /// Bytes free for important usage on the volume containing `url`
    /// (`volumeAvailableCapacityForImportantUsageKey`), or nil when it can't
    /// be determined.
    func availableCapacity(at url: URL) -> Int64?
}

/// The real probe: asks the filesystem for the volume's available capacity.
public struct VolumeDiskSpaceProbe: DiskSpaceProbing {
    public init() {}

    public func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage
    }
}
