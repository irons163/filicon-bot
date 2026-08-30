import Foundation

public struct BackendUpdateRequirement: Equatable, Sendable {
    public var scope: String
    public var minimumVersion: String

    public init(scope: String, minimumVersion: String) throws {
        let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = minimumVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, scope.count <= 128,
              scope.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-")).contains($0) }) else {
            throw UpdateError.invalidBackendRequirementScope
        }
        _ = try ReleaseVersion(version)
        self.scope = scope
        self.minimumVersion = version
    }
}

public struct BackendUpdatePolicySnapshot: Codable, Equatable, Sendable {
    public var minimumVersionsByScope: [String: String]

    public init(minimumVersionsByScope: [String: String] = [:]) {
        self.minimumVersionsByScope = minimumVersionsByScope
    }

    public var highestMinimumVersion: String? {
        minimumVersionsByScope.values.max { left, right in
            guard let lhs = try? ReleaseVersion(left), let rhs = try? ReleaseVersion(right) else { return true }
            return lhs < rhs
        }
    }
}

public actor BackendUpdatePolicyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func snapshot() -> BackendUpdatePolicySnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(BackendUpdatePolicySnapshot.self, from: data) else {
            return .init()
        }
        let valid = decoded.minimumVersionsByScope.filter { scope, version in
            (try? BackendUpdateRequirement(scope: scope, minimumVersion: version)) != nil
        }
        return .init(minimumVersionsByScope: valid)
    }

    @discardableResult
    public func raise(_ requirement: BackendUpdateRequirement) throws -> BackendUpdatePolicySnapshot {
        var policy = snapshot()
        if let current = policy.minimumVersionsByScope[requirement.scope],
           let currentVersion = try? ReleaseVersion(current),
           let proposedVersion = try? ReleaseVersion(requirement.minimumVersion),
           proposedVersion <= currentVersion {
            return policy
        }
        policy.minimumVersionsByScope[requirement.scope] = requirement.minimumVersion
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        return policy
    }
}

/// Accepts update policy carried by a real backend/gateway lifecycle response.
/// A newly raised policy is persisted before the immediate check callback runs.
public actor BackendUpdateRequirementCoordinator {
    public typealias ImmediateCheck = @Sendable (_ highestMinimumVersion: String, _ updateRequired: Bool) async -> Void

    private let store: BackendUpdatePolicyStore
    private let installedVersion: String
    private let immediateCheck: ImmediateCheck

    public init(
        store: BackendUpdatePolicyStore,
        installedVersion: String,
        immediateCheck: @escaping ImmediateCheck
    ) {
        self.store = store
        self.installedVersion = installedVersion
        self.immediateCheck = immediateCheck
    }

    @discardableResult
    public func ingest(scope: String, minimumVersion: String) async throws -> BackendUpdatePolicySnapshot {
        let requirement = try BackendUpdateRequirement(scope: scope, minimumVersion: minimumVersion)
        let before = await store.snapshot()
        let policy = try await store.raise(requirement)
        if policy != before, let highest = policy.highestMinimumVersion {
            await immediateCheck(
                highest,
                UpdateRequirementEvaluator.isBelowMinimum(
                    installedVersion: installedVersion,
                    minimumRequiredVersion: highest
                )
            )
        }
        return policy
    }
}
