import Foundation

public protocol ComputerClock: Sendable {
    func nowMilliseconds() async -> Int64
    func sleep(milliseconds: Int64) async throws
}
public struct SystemComputerClock: ComputerClock {
    public init() {}

    public func nowMilliseconds() async -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    public func sleep(milliseconds: Int64) async throws {
        try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
    }
}
