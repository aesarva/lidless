import Foundation
import IOKit
import os

@MainActor public final class IORegistryLidMonitor: LidMonitoring {
    private static let log = Logger(subsystem: "io.github.aesarva.Lidless", category: "safety")

    /// Fires on IOPMrootDomain interest messages (clamshell open/close among them), so a
    /// lid change is seen at once instead of on the next 15 s poll.
    public var onChange: (() -> Void)? {
        didSet { updateNotification() }
    }

    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    public init() {}

    isolated deinit {
        stopObserving()
    }

    public func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private func updateNotification() {
        if onChange != nil, port == nil {
            startObserving()
        } else if onChange == nil {
            stopObserving()
        }
    }

    private func startObserving() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Self.log.error("IOPMrootDomain not found; lid changes fall back to polling")
            return
        }
        defer { IOObjectRelease(service) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            // Delivered on the main dispatch queue (set above).
            MainActor.assumeIsolated {
                Unmanaged<IORegistryLidMonitor>.fromOpaque(refcon).takeUnretainedValue().onChange?()
            }
        }
        var note: io_object_t = 0
        let kr = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, callback, context, &note)
        guard kr == KERN_SUCCESS else {
            Self.log.error("IOServiceAddInterestNotification failed: \(kr, privacy: .public)")
            IONotificationPortDestroy(port)
            return
        }
        self.port = port
        notification = note
    }

    private func stopObserving() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }
}
