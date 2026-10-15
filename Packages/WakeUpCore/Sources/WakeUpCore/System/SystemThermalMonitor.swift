import Foundation

@MainActor public final class SystemThermalMonitor: ThermalMonitoring {
    public var onChange: (() -> Void)? {
        didSet { updateObserver() }
    }

    private var observer: NSObjectProtocol?

    public init() {}

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func current() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    private func updateObserver() {
        if onChange != nil, observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        } else if onChange == nil, let o = observer {
            NotificationCenter.default.removeObserver(o)
            observer = nil
        }
    }
}
