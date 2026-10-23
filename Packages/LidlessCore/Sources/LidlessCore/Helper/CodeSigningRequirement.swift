import Foundation
import Security

/// Builds the code-signing requirement each side of the XPC connection
/// demands of its peer. Both sides must carry the same Team ID.
public enum CodeSigningRequirement {
    /// Team ID of the running code, or nil when unsigned or ad-hoc signed.
    public static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        return validTeamID(dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// A Team ID is exactly ten uppercase ASCII letters or digits. Anything
    /// else is rejected so it can never be spliced into a requirement string.
    public static func validTeamID(_ s: String?) -> String? {
        guard let s, s.utf8.count == 10,
              s.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) })
        else { return nil }
        return s
    }

    public static func requirement(identifier: String, teamID: String?) -> String? {
        guard let team = validTeamID(teamID) else { return nil }
        return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
    }
}
