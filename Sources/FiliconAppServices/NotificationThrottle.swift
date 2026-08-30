import Foundation

public struct NotificationThrottle: Sendable {
    public let minimumInterval: TimeInterval
    private var lastDeliveredAt: [String: Date] = [:]

    public init(minimumInterval: TimeInterval = 30) { self.minimumInterval = minimumInterval }

    public mutating func shouldDeliver(key: String, at now: Date = Date()) -> Bool {
        if let previous = lastDeliveredAt[key], now.timeIntervalSince(previous) < minimumInterval { return false }
        lastDeliveredAt[key] = now
        return true
    }

    public mutating func reset(key: String? = nil) {
        if let key { lastDeliveredAt.removeValue(forKey: key) }
        else { lastDeliveredAt.removeAll() }
    }
}
