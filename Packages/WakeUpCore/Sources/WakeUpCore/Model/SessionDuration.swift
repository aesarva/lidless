import Foundation

public enum SessionDuration: Codable, Equatable, Sendable {
    case minutes(Int)
    case until(Date)
    case indefinite

    public func endDate(from now: Date) -> Date? {
        switch self {
        case .minutes(let m): return now.addingTimeInterval(TimeInterval(m) * 60)
        case .until(let d): return d
        case .indefinite: return nil
        }
    }
}
