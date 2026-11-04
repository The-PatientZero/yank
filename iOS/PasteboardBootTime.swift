import Foundation

extension PasteboardAcknowledgementStore {
    /// The store backed by the App Group defaults and the device boot time, or `nil` when the
    /// App Group is unavailable (the acknowledgement then lives in memory only).
    static func live() -> PasteboardAcknowledgementStore? {
        guard let defaults = AppGroupContext.live()?.defaults else { return nil }
        return PasteboardAcknowledgementStore(defaults: defaults, readBootTime: SystemBootTime.read)
    }
}

/// Wall-clock device boot time from `kern.boottime`. It is derived from the wall clock, so
/// unlike uptime clocks it does not drift while the device sleeps. It never leaves the device.
/// Declared in the privacy manifest under the System Boot Time category.
private enum SystemBootTime {
    static func read() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size else {
            return nil
        }
        return Date(
            timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
                + TimeInterval(bootTime.tv_usec) / TimeInterval(USEC_PER_SEC)
        )
    }
}
