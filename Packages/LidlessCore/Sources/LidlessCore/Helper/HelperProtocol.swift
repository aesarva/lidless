import Foundation

public enum HelperIDs {
    public static let app = "io.github.aesarva.Lidless"
    public static let helper = "io.github.aesarva.Lidless.helper"
    public static let plistName = "io.github.aesarva.Lidless.helper.plist"
}

/// XPC interface of the privileged daemon. A `String?` reply is an error
/// message, `nil` meaning success.
@objc public protocol HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void)
    /// Replies with the daemon version and build, the current `disablesleep` value, whether the
    /// daemon set that 1 itself, and an error message when the value could not be read (the
    /// value is then meaningless).
    func info(reply: @escaping @Sendable (String, String, Bool, Bool, String?) -> Void)
    /// Replies with the removed paths and an error message, if any.
    func removeLegacyHelper(reply: @escaping @Sendable ([String], String?) -> Void)
}
