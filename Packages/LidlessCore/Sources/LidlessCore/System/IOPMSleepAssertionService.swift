import Foundation
import IOKit
import IOKit.pwr_mgt
import os

public enum AssertionError: Error, Equatable {
    case createFailed(Int32)
}

/// Holds IOPM power assertions that keep the Mac (and optionally the display) awake.
@MainActor public final class IOPMSleepAssertionService: SleepAssertionService {
    private static let log = Logger(subsystem: "io.github.aesarva.Lidless", category: "session")
    private static let name = "Lidless session" as CFString

    private var held: [IOPMAssertionID] = []

    public init() {}

    deinit {
        for id in held { IOPMAssertionRelease(id) }
    }

    /// Creates the new assertions first, then releases the old ones, so there is no unprotected window.
    public func acquire(keepDisplayOn: Bool) throws {
        var types = [kIOPMAssertionTypePreventUserIdleSystemSleep as String]
        if keepDisplayOn { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep as String) }

        var created: [IOPMAssertionID] = []
        for type in types {
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 Self.name, &id)
            guard rc == kIOReturnSuccess else {
                for c in created { IOPMAssertionRelease(c) }
                Self.log.error("IOPMAssertionCreateWithName failed: \(rc)")
                throw AssertionError.createFailed(rc)
            }
            created.append(id)
        }
        let old = held
        held = created
        for id in old { IOPMAssertionRelease(id) }
        Self.log.debug("acquired \(created.count) assertion(s)")
    }

    public func release() {
        let old = held
        held = []
        for id in old { IOPMAssertionRelease(id) }
    }
}
