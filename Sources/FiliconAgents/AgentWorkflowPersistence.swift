import Foundation

enum AgentWorkflowSafePersistence {
    static func prepare(_ url: URL, fileManager: FileManager) throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else {
            throw AgentWorkflowError.persistenceUnsafe
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(inExistingPath: parent, fileManager: fileManager)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try rejectSymbolicLinks(inExistingPath: parent, fileManager: fileManager)
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw AgentWorkflowError.persistenceUnsafe
            }
        }
    }

    static func read(_ url: URL, maximumBytes: Int, fileManager: FileManager) throws -> Data? {
        try prepare(url, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
            throw AgentWorkflowError.boundsExceeded("persistence file")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw AgentWorkflowError.boundsExceeded("persistence file") }
        return data
    }

    static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try prepare(url, fileManager: fileManager)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try prepare(url, fileManager: fileManager)
    }

    private static func rejectSymbolicLinks(inExistingPath url: URL, fileManager: FileManager) throws {
        var current = url.standardizedFileURL
        var chain: [URL] = []
        while current.path != "/" {
            chain.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        for component in chain.reversed() where fileManager.fileExists(atPath: component.path) {
            let values = try component.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            // macOS exposes these fixed compatibility links into /private. Do not broadly trust
            // arbitrary top-level links: a caller may persist to another mounted/user-owned path.
            let trustedTopLevelCompatibilityLink = ["/etc", "/tmp", "/var"].contains(component.path)
            guard trustedTopLevelCompatibilityLink && values.isSymbolicLink == true
                    || values.isSymbolicLink != true && values.isDirectory == true else {
                throw AgentWorkflowError.persistenceUnsafe
            }
        }
    }
}

struct AgentWorkflowRunDocument: Codable, Sendable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    var runs: [AgentWorkflowRun]
}

struct AgentWorkflowRunPersistence {
    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() throws -> [AgentWorkflowRun] {
        let maximumBytes = AgentWorkflowLimits.maximumRuns * (AgentWorkflowLimits.maximumBodyBytes + AgentWorkflowLimits.maximumRunFailureBytes + 4_096)
        guard let data = try AgentWorkflowSafePersistence.read(url, maximumBytes: maximumBytes, fileManager: fileManager) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(AgentWorkflowRunDocument.self, from: data)
        guard document.schemaVersion == AgentWorkflowRunDocument.schemaVersion else {
            throw AgentWorkflowError.unsupportedSchema(document.schemaVersion)
        }
        return try Self.validated(document.runs)
    }

    func save(_ runs: [AgentWorkflowRun]) throws {
        let safe = try Self.validated(runs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = try encoder.encode(AgentWorkflowRunDocument(runs: safe))
        data.append(0x0A)
        try AgentWorkflowSafePersistence.write(data, to: url, fileManager: fileManager)
    }

    private static func validated(_ runs: [AgentWorkflowRun]) throws -> [AgentWorkflowRun] {
        guard runs.count <= AgentWorkflowLimits.maximumRuns else { throw AgentWorkflowError.boundsExceeded("run history") }
        var ids = Set<UUID>()
        for run in runs {
            guard ids.insert(run.id).inserted, AgentWorkflow.isSafeIdentifier(run.workflowID) else {
                throw AgentWorkflowError.malformed("run history identity")
            }
            let outputBytes = run.outputs.reduce(0) { $0 + $1.utf8.count }
            guard outputBytes <= AgentWorkflowLimits.maximumBodyBytes,
                  (run.failure?.utf8.count ?? 0) <= AgentWorkflowLimits.maximumRunFailureBytes else {
                throw AgentWorkflowError.boundsExceeded("run history record")
            }
        }
        return runs
    }
}
