import Foundation

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    private let core: [Int]
    private let prerelease: [Identifier]

    private enum Identifier: Equatable, Sendable {
        case number(Int)
        case text(String)
    }

    public init(_ value: String) throws {
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !coreParts.isEmpty, coreParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw UpdateError.invalidVersion(value)
        }
        core = try coreParts.map {
            guard let number = Int($0) else { throw UpdateError.invalidVersion(value) }
            return number
        }
        if pieces.count == 2 {
            guard !pieces[1].isEmpty else { throw UpdateError.invalidVersion(value) }
            prerelease = try pieces[1].split(separator: ".", omittingEmptySubsequences: false).map { part in
                guard !part.isEmpty, part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                    throw UpdateError.invalidVersion(value)
                }
                if part.allSatisfy(\.isNumber), let number = Int(part) { return .number(number) }
                return .text(String(part).lowercased())
            }
        } else {
            prerelease = []
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (left, right) {
            case let (.number(a), .number(b)): return a < b
            case (.number, .text): return true
            case (.text, .number): return false
            case let (.text(a), .text(b)): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum UpdateSelector {
    public static func newestUpdate(
        in feed: UpdateFeed,
        channel: UpdateChannel,
        installed: InstalledVersion,
        systemVersion: String
    ) throws -> UpdateRelease? {
        guard feed.schemaVersion == 1 else { throw UpdateError.invalidFeedSchema(feed.schemaVersion) }
        guard feed.channel == channel else { throw UpdateError.channelMismatch }
        let installedVersion = try ReleaseVersion(installed.version)
        let osVersion = try ReleaseVersion(systemVersion)

        return try feed.releases
            .filter { release in
                let minimum = try ReleaseVersion(release.minimumSystemVersion)
                guard minimum <= osVersion else { return false }
                let candidate = try ReleaseVersion(release.version)
                return candidate > installedVersion || (candidate == installedVersion && release.build > installed.build)
            }
            .sorted { left, right in
                let leftVersion = try ReleaseVersion(left.version)
                let rightVersion = try ReleaseVersion(right.version)
                if leftVersion != rightVersion { return leftVersion > rightVersion }
                return left.build > right.build
            }
            .first
    }
}
