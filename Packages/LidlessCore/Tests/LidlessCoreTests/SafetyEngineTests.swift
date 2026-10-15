import Testing
import Foundation
@testable import LidlessCore

@MainActor
struct SafetyEngineTests {
    @MainActor final class Box { var all: [SafetyReadings] = [] }

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let clock: MutableClock
    let power = FakePower()
    let thermal = FakeThermal()
    let lid = FakeLidMonitor()
    let received = Box()

    init() { clock = MutableClock(t0) }

    func makeEngine() -> SafetyEngine {
        let box = received
        return SafetyEngine(power: power, thermal: thermal, lid: lid, clock: clock) { box.all.append($0) }
    }

    @Test func sinceStartsAndPersists() {
        let e = makeEngine()
        lid.closed = true
        power.reading = PowerReading(batteryLevel: 80, onBattery: true)
        e.refresh()
        #expect(e.lidClosedOnBatterySince == t0)
        clock.advance(100)
        e.refresh()
        #expect(e.lidClosedOnBatterySince == t0)
    }

    @Test func sinceResetsOnOpenOrPower() {
        let e = makeEngine()
        lid.closed = true
        power.reading = PowerReading(batteryLevel: 80, onBattery: true)
        e.refresh()
        lid.closed = false
        e.refresh()
        #expect(e.lidClosedOnBatterySince == nil)
        clock.advance(200)
        lid.closed = true
        e.refresh()
        #expect(e.lidClosedOnBatterySince == t0.addingTimeInterval(200))
        power.reading = PowerReading(batteryLevel: 80, onBattery: false)
        e.refresh()
        #expect(e.lidClosedOnBatterySince == nil)
    }

    @Test func refreshEmitsReadings() {
        let e = makeEngine()
        power.reading = PowerReading(batteryLevel: 55, onBattery: true)
        thermal.level = .fair
        e.refresh()
        #expect(received.all == [SafetyReadings(batteryLevel: 55, onBattery: true, thermal: .fair,
                                                lidClosed: false, lidClosedOnBatterySince: nil, now: t0)])
    }

    @Test func monitorChangeTriggersRefresh() {
        let e = makeEngine()
        e.start()
        let before = received.all.count
        #expect(before >= 1)
        power.onChange?()
        #expect(received.all.count == before + 1)
        thermal.onChange?()
        #expect(received.all.count == before + 2)
        e.stop()
        #expect(power.onChange == nil)
        #expect(thermal.onChange == nil)
    }
}
