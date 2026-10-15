import Foundation

public enum PmsetParser {
    /// `pmset -g` prints a `SleepDisabled` line only while it is 1; absence means false.
    public static func sleepDisabled(in pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).last
            if last == "1" { return true }
        }
        return false
    }
}
