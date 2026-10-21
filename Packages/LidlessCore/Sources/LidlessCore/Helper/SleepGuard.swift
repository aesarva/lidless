import Foundation

/// Persisted "we set disablesleep to 1" flag, so a crashed daemon or a reboot can still undo it.
public protocol OwnershipStore: Sendable {
    func exists() -> Bool
    func create() throws
    func remove() throws
}

public struct FileOwnershipStore: OwnershipStore {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/Lidless/sleep-owned")

    private let url: URL

    public init(url: URL = FileOwnershipStore.defaultURL) { self.url = url }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func create() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        guard fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }
}

/// Daemon-side bookkeeping: `disablesleep` goes back to 0 only when every holder has let go and
/// the 1 was set by us. One lock covers whole operations so "file before 1, 0 before removing the
/// file" never interleaves between XPC queues.
public final class SleepGuard: @unchecked Sendable {
    private let setting: SleepSetting
    private let store: OwnershipStore
    private let lock = NSLock()
    private var holders: Set<UUID> = []
    private var owned = false

    public init(setting: SleepSetting, store: OwnershipStore) {
        self.setting = setting
        self.store = store
    }

    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return holders.isEmpty && !owned
    }

    public func acquire(_ holder: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if holders.isEmpty && !owned {
            if try !setting.isDisabled() {
                try store.create()
                do {
                    try setting.setDisabled(true)
                } catch {
                    try? store.remove()
                    throw error
                }
                owned = true
            } else if store.exists() {
                owned = true
            }
        }
        holders.insert(holder)
    }

    public func release(_ holder: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        holders.remove(holder)
        try resetIfUnheld()
    }

    public func releaseAll() throws {
        lock.lock(); defer { lock.unlock() }
        holders.removeAll()
        try resetIfUnheld()
    }

    public func recoverAtStart() throws {
        lock.lock(); defer { lock.unlock() }
        guard store.exists() else { return }
        try setting.setDisabled(false)
        try store.remove()
        owned = false
    }

    private func resetIfUnheld() throws {
        guard holders.isEmpty, owned else { return }
        try setting.setDisabled(false)
        try store.remove()
        owned = false
    }
}
