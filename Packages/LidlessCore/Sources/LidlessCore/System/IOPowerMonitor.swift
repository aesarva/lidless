import Foundation
import IOKit
import IOKit.ps
import os

@MainActor public final class IOPowerMonitor: PowerMonitoring {
    private static let log = Logger(subsystem: "io.github.aesarva.Lidless", category: "safety")

    public var onChange: (() -> Void)? {
        didSet { updateSource() }
    }

    private var source: CFRunLoopSource?

    public init() {}

    isolated deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    public func current() -> PowerReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerReading(batteryLevel: nil, onBattery: false)
        }
        let onBattery: Bool = {
            guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
            return type == kIOPSBatteryPowerValue
        }()

        var level: Int?
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as [CFTypeRef]?) ?? []
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            level = Swift.min(100, Swift.max(0, cur * 100 / max))
            break
        }
        return PowerReading(batteryLevel: level, onBattery: onBattery)
    }

    private func updateSource() {
        if onChange != nil, source == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOPowerSourceCallbackType = { ctx in
                guard let ctx else { return }
                // The source is scheduled on the main run loop, so this runs on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<IOPowerMonitor>.fromOpaque(ctx).takeUnretainedValue().onChange?()
                }
            }
            guard let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
                Self.log.error("IOPSNotificationCreateRunLoopSource failed")
                return
            }
            // Common modes: power changes arrive while a menu or an alert is open too.
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        } else if onChange == nil, let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            source = nil
        }
    }
}
