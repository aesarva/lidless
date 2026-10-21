import Foundation
import os

public struct PowerReading: Equatable, Sendable {
    public var batteryLevel: Int?
    public var onBattery: Bool

    public init(batteryLevel: Int?, onBattery: Bool) {
        self.batteryLevel = batteryLevel
        self.onBattery = onBattery
    }
}

@MainActor public protocol PowerMonitoring: AnyObject {
    func current() -> PowerReading
    var onChange: (() -> Void)? { get set }
}

@MainActor public protocol ThermalMonitoring: AnyObject {
    func current() -> ThermalLevel
    var onChange: (() -> Void)? { get set }
}

@MainActor public protocol LidMonitoring: AnyObject {
    func isLidClosed() -> Bool
    /// Called on the main actor when the lid opens or closes (may also fire for other
    /// power-management events; readers re-check `isLidClosed()`).
    var onChange: (() -> Void)? { get set }
}

/// Gathers power/thermal/lid readings and hands them to `onReadings`.
@MainActor public final class SafetyEngine {
    public static let pollInterval: TimeInterval = 15

    private static let log = Logger(subsystem: "io.github.aesarva.Lidless", category: "safety")

    private let power: PowerMonitoring
    private let thermal: ThermalMonitoring
    private let lid: LidMonitoring
    private let clock: WakeClock
    private let onReadings: @MainActor (SafetyReadings) -> Void
    private var timer: Timer?

    public private(set) var lidClosedOnBatterySince: Date?

    public init(power: PowerMonitoring, thermal: ThermalMonitoring, lid: LidMonitoring, clock: WakeClock,
                onReadings: @escaping @MainActor (SafetyReadings) -> Void) {
        self.power = power
        self.thermal = thermal
        self.lid = lid
        self.clock = clock
        self.onReadings = onReadings
    }

    isolated deinit {
        timer?.invalidate()
    }

    public func start() {
        stop()
        power.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        thermal.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        lid.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes: safety checks keep running while a menu or an alert is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Self.log.debug("safety engine started")
        refresh()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        power.onChange = nil
        thermal.onChange = nil
        lid.onChange = nil
    }

    public func refresh() {
        let p = power.current()
        let closed = lid.isLidClosed()
        let now = clock.now
        if closed && p.onBattery {
            lidClosedOnBatterySince = lidClosedOnBatterySince ?? now
        } else {
            lidClosedOnBatterySince = nil
        }
        onReadings(SafetyReadings(
            batteryLevel: p.batteryLevel, onBattery: p.onBattery, thermal: thermal.current(),
            lidClosed: closed, lidClosedOnBatterySince: lidClosedOnBatterySince, now: now))
    }
}
