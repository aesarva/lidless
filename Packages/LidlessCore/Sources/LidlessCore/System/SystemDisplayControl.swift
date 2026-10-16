import CoreGraphics
import Foundation
import os

/// Real display control: CoreGraphics for the external-display check, `pmset displaysleepnow`
/// (no privileges needed) to turn the screens off.
@MainActor public final class SystemDisplayControl: DisplayControlling {
    nonisolated private static let log = Logger(subsystem: "io.github.alexsarva.Lidless", category: "session")
    private let runner: CommandRunner

    public init(runner: CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    public func sleepDisplayNow() {
        let runner = self.runner
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runner.run("/usr/bin/pmset", ["displaysleepnow"])
                if result.exitCode != 0 {
                    Self.log.error("pmset displaysleepnow failed: \(result.stderr, privacy: .public)")
                }
            } catch {
                Self.log.error("pmset displaysleepnow failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
