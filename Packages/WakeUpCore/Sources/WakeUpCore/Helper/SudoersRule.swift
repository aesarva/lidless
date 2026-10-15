import Foundation

public enum SudoersRule {
    /// Conservative POSIX-style login name (^[A-Za-z_][A-Za-z0-9_.-]{0,31}$, not "ALL").
    /// Anything outside it could inject sudoers syntax.
    public static func isValidUserName(_ name: String) -> Bool {
        guard name != "ALL", name.utf8.count <= 32, let first = name.unicodeScalars.first else { return false }
        func isLetter(_ s: Unicode.Scalar) -> Bool {
            (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
        }
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }
        guard isLetter(first) || first == "_" else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            isLetter($0) || isDigit($0) || $0 == "_" || $0 == "." || $0 == "-"
        }
    }

    public static func render(userName: String) throws -> String {
        guard isValidUserName(userName) else { throw HelperError.invalidUserName(userName) }
        return """
        # Installed by WakeUp. Remove via WakeUp → Settings → Helper.
        \(userName) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

        """
    }
}
