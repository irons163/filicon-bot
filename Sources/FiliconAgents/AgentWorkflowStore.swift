import Foundation

public actor AgentWorkflowStore {
    public let persistenceURL: URL
    private var document: AgentWorkflowDocument
    private var revision = UUID()
    private let fileManager: FileManager

    public init(persistenceURL: URL, fileManager: FileManager = .default) throws {
        self.persistenceURL = persistenceURL; self.fileManager = fileManager
        let maximumBytes = AgentWorkflowLimits.maximumWorkflows * (AgentWorkflowLimits.maximumBodyBytes + AgentWorkflowLimits.maximumActionPayloadBytes)
        if let data = try AgentWorkflowSafePersistence.read(persistenceURL, maximumBytes: maximumBytes, fileManager: fileManager) {
            document = try AgentWorkflowCodec.parse(data)
        } else { document = .init() }
    }

    public func list() -> [AgentWorkflow] { document.workflows.sorted { $0.id < $1.id } }
    public func get(_ id: String) -> AgentWorkflow? { document.workflows.first { $0.id == id } }

    public func writeSnapshot() -> AgentWorkflowLibrarySnapshot {
        .init(revision: revision, workflows: list())
    }

    public func applyAgentWrite(_ change: AgentWorkflowWrite, lifetime: AgentWorkflowWriteLifetime,
                                at date: Date = .now) throws -> AgentWorkflow {
        try lifetime.commit(change) {
            guard revision == change.expectedRevision else { throw AgentWorkflowWriteError.stale }
            let value = change.proposed
            guard AgentWorkflowWrite.isEditable(value, by: change.requesterID),
                  !value.description.isEmpty, try value.validated() == value else { throw AgentWorkflowWriteError.invalid }
            var next = document
            var saved = value
            if let previous = change.previous {
                guard AgentWorkflowWrite.isEditable(previous, by: change.requesterID),
                      let index = next.workflows.firstIndex(where: { $0.id == previous.id }),
                      next.workflows[index] == previous else { throw AgentWorkflowWriteError.unavailable }
                var permitted = previous
                permitted.name = value.name; permitted.description = value.description; permitted.steps = value.steps
                guard permitted == value else { throw AgentWorkflowWriteError.invalid }
                saved.updatedAt = date
                next.workflows[index] = saved
            } else {
                guard value.isEnabled, next.workflows.count < AgentWorkflowLimits.maximumWorkflows,
                      !next.workflows.contains(where: { $0.id == value.id }) else { throw AgentWorkflowWriteError.invalid }
                saved.createdAt = date; saved.updatedAt = date
                next.workflows.append(saved)
            }
            try commit(next)
            return saved
        }
    }

    @discardableResult public func create(_ proposed: AgentWorkflow) throws -> AgentWorkflow {
        guard document.workflows.count < AgentWorkflowLimits.maximumWorkflows else { throw AgentWorkflowError.boundsExceeded("workflow count") }
        var workflow = try proposed.validated()
        workflow.id = try uniqueIdentifier(workflow.id)
        workflow.createdAt = .now; workflow.updatedAt = workflow.createdAt
        var next = document; next.workflows.append(workflow); try commit(next); return workflow
    }

    public func applyAgentDeletion(_ change: AgentWorkflowDeletion, lifetime: AgentWorkflowDeletionLifetime) throws {
        try lifetime.commit(change) {
            guard revision == change.expectedRevision else { throw AgentWorkflowWriteError.stale }
            guard AgentWorkflowWrite.isEditable(change.workflow, by: change.requesterID),
                  let index = document.workflows.firstIndex(where: { $0.id == change.workflow.id }),
                  document.workflows[index] == change.workflow else { throw AgentWorkflowDeletionError.unavailable }
            var next = document
            next.workflows.remove(at: index)
            try commit(next)
        }
    }

    @discardableResult public func create(name: String, description: String = "", trigger: AgentWorkflowTrigger = .manual,
                                          steps: [AgentWorkflowStep], sourceReference: String? = nil) throws -> AgentWorkflow {
        try create(.init(id: AgentWorkflow.slug(name), name: name, description: description, trigger: trigger, steps: steps, sourceReference: sourceReference))
    }

    @discardableResult public func update(_ id: String, with proposed: AgentWorkflow) throws -> AgentWorkflow {
        guard let index = document.workflows.firstIndex(where: { $0.id == id }) else { throw AgentWorkflowError.notFound }
        var workflow = proposed; workflow.id = id; workflow.createdAt = document.workflows[index].createdAt; workflow.updatedAt = .now
        workflow = try workflow.validated(); var next = document; next.workflows[index] = workflow; try commit(next); return workflow
    }

    @discardableResult public func setEnabled(_ enabled: Bool, id: String) throws -> AgentWorkflow {
        guard let current = get(id) else { throw AgentWorkflowError.notFound }
        var next = current; next.isEnabled = enabled; return try update(id, with: next)
    }

    public func delete(_ id: String) throws {
        guard document.workflows.contains(where: { $0.id == id }) else { throw AgentWorkflowError.notFound }
        var next = document; next.workflows.removeAll { $0.id == id }; try commit(next)
    }

    @discardableResult public func importText(_ markdown: String, fallbackName: String? = nil) throws -> AgentWorkflow {
        try create(AgentWorkflowImporter.importText(markdown, fallbackName: fallbackName))
    }

    @discardableResult public func importSkill(_ payload: AgentWorkflowSkillImportPayload) throws -> AgentWorkflow {
        try create(AgentWorkflowImporter.importSkill(payload))
    }

    @discardableResult public func importURL(_ url: URL, fallbackName: String? = nil,
                                             fetcher: any AgentWorkflowHTTPSFetching = URLSessionAgentWorkflowFetcher()) async throws -> AgentWorkflow {
        try await create(AgentWorkflowImporter.importURL(url, fallbackName: fallbackName, fetcher: fetcher))
    }

    /// Creates the recovered live-source form without copying remote contents.
    /// The source remains authoritative and is resolved by the model's explicitly
    /// authorized fetch tools when the workflow is referenced.
    @discardableResult public func linkLiveSource(_ url: URL, fallbackName: String? = nil) throws -> AgentWorkflow {
        try create(AgentWorkflowImporter.liveSource(url, fallbackName: fallbackName))
    }

    public func portPrivateSkills(_ payloads: [AgentWorkflowSkillImportPayload]) -> AgentWorkflowImportResult {
        let parsed = AgentWorkflowImporter.portPrivateSkills(payloads); var result = AgentWorkflowImportResult(skipped: parsed.skipped)
        for workflow in parsed.imported {
            do { result.imported.append(try create(workflow)) }
            catch { result.skipped.append(.init(source: workflow.id, reason: String(describing: error))) }
        }
        return result
    }

    /// Atomically replaces persistence only after the full imported document validates.
    public func replace(with data: Data) throws { try commit(AgentWorkflowCodec.parse(data)) }

    private func uniqueIdentifier(_ requested: String) throws -> String {
        guard AgentWorkflow.isSafeIdentifier(requested) else { throw AgentWorkflowError.invalidIdentifier }
        let ids = Set(document.workflows.map(\.id)); if !ids.contains(requested) { return requested }
        for suffix in 2..<1_000 { let candidate = "\(requested.prefix(70))-\(suffix)"; if !ids.contains(candidate) { return candidate } }
        throw AgentWorkflowError.duplicateIdentifier
    }

    private func commit(_ next: AgentWorkflowDocument) throws {
        let data = try AgentWorkflowCodec.serialize(next)
        try AgentWorkflowSafePersistence.write(data, to: persistenceURL, fileManager: fileManager)
        document = next
        revision = UUID()
    }
}

public struct AgentWorkflowSkillImportPayload: Hashable, Sendable {
    public var identifier: String?
    public var name: String?
    public var description: String?
    public var skillMarkdown: String
    public var sourceReference: String?
    public init(identifier: String? = nil, name: String? = nil, description: String? = nil,
                skillMarkdown: String, sourceReference: String? = nil) {
        self.identifier = identifier; self.name = name; self.description = description
        self.skillMarkdown = skillMarkdown; self.sourceReference = sourceReference
    }
}

public struct AgentWorkflowImportResult: Hashable, Sendable {
    public var imported: [AgentWorkflow]
    public var skipped: [Skipped]
    public struct Skipped: Hashable, Sendable { public var source: String; public var reason: String; public init(source: String, reason: String) { self.source = source; self.reason = reason } }
    public init(imported: [AgentWorkflow] = [], skipped: [Skipped] = []) { self.imported = imported; self.skipped = skipped }
}

public protocol AgentWorkflowHTTPSFetching: Sendable {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> (data: Data, finalURL: URL)
}

public struct URLSessionAgentWorkflowFetcher: AgentWorkflowHTTPSFetching {
    public init() {}
    public func fetch(_ url: URL, maximumBytes: Int) async throws -> (data: Data, finalURL: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"; request.setValue("text/markdown,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let finalURL = response.url else { throw AgentWorkflowError.malformed("HTTPS import failed") }
        guard response.expectedContentLength <= 0 || response.expectedContentLength <= Int64(maximumBytes),
              data.count <= maximumBytes else { throw AgentWorkflowError.boundsExceeded("URL response") }
        return (data, finalURL)
    }
}

public enum AgentWorkflowImporter {
    public static func importText(_ markdown: String, fallbackName: String? = nil,
                                  sourceReference: String? = nil) throws -> AgentWorkflow {
        guard markdown.utf8.count <= AgentWorkflowLimits.maximumBodyBytes + 8_192 else { throw AgentWorkflowError.boundsExceeded("SKILL.md") }
        let parsed = parseSkill(markdown)
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = body.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# *_`>")) }.first { !$0.isEmpty }
        let name = AgentWorkflow.line(parsed.name ?? fallbackName ?? derived ?? "")
        guard !name.isEmpty else { throw AgentWorkflowError.invalidName }
        let description = AgentWorkflow.line(parsed.description ?? "")
        return try AgentWorkflow(id: AgentWorkflow.slug(name), name: String(name.prefix(AgentWorkflowLimits.maximumNameCharacters)),
                                 description: String(description.prefix(AgentWorkflowLimits.maximumDescriptionCharacters)),
                                 steps: [.prompt(body)], sourceReference: parsed.source ?? sourceReference).validated()
    }

    public static func importSkill(_ payload: AgentWorkflowSkillImportPayload) throws -> AgentWorkflow {
        var workflow = try importText(payload.skillMarkdown, fallbackName: payload.name, sourceReference: payload.sourceReference)
        if let identifier = payload.identifier { workflow.id = identifier }
        if let description = payload.description { workflow.description = description }
        return try workflow.validated()
    }

    public static func importURL(_ url: URL, fallbackName: String? = nil,
                                 fetcher: any AgentWorkflowHTTPSFetching = URLSessionAgentWorkflowFetcher()) async throws -> AgentWorkflow {
        try validateHTTPS(url)
        let result = try await fetcher.fetch(url, maximumBytes: AgentWorkflowLimits.maximumURLBytes)
        try validateHTTPS(result.finalURL)
        guard result.data.count <= AgentWorkflowLimits.maximumURLBytes, let text = String(data: result.data, encoding: .utf8) else { throw AgentWorkflowError.boundsExceeded("URL response") }
        return try importText(text, fallbackName: fallbackName ?? derivedName(url), sourceReference: result.finalURL.absoluteString)
    }

    public static func liveSource(_ url: URL, fallbackName: String? = nil) throws -> AgentWorkflow {
        try validateHTTPS(url)
        let name = AgentWorkflow.line(fallbackName ?? derivedName(url))
        guard !name.isEmpty else { throw AgentWorkflowError.invalidName }
        let source = url.absoluteString
        let body = """
        This workflow is a live reference to the skill at `\(source)`.
        Read that source now with your file or fetch tools and follow it as written. Do not assume its contents from this note; the source is the source of truth and may have changed since this workflow was created.
        """
        return try AgentWorkflow(
            id: AgentWorkflow.slug(name),
            name: String(name.prefix(AgentWorkflowLimits.maximumNameCharacters)),
            description: String("Use when the \"\(name)\" skill applies; it is a live reference to \(source).".prefix(AgentWorkflowLimits.maximumDescriptionCharacters)),
            steps: [.prompt(body)],
            sourceReference: source
        ).validated()
    }

    /// Bridges already-read private skills without importing FiliconPlugins or reading arbitrary paths.
    public static func portPrivateSkills(_ payloads: [AgentWorkflowSkillImportPayload]) -> AgentWorkflowImportResult {
        var result = AgentWorkflowImportResult()
        for payload in payloads.prefix(AgentWorkflowLimits.maximumWorkflows) {
            do { result.imported.append(try importSkill(payload)) }
            catch { result.skipped.append(.init(source: payload.identifier ?? payload.name ?? "private skill", reason: String(describing: error))) }
        }
        if payloads.count > AgentWorkflowLimits.maximumWorkflows {
            result.skipped.append(.init(
                source: "private skill import",
                reason: AgentWorkflowError.boundsExceeded("import item count").localizedDescription
            ))
        }
        return result
    }

    private static func validateHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty else { throw AgentWorkflowError.insecureURL }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let forbidden = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || address == "::" || address == "::1" || address.hasPrefix("fc") || address.hasPrefix("fd") || address.hasPrefix("fe8") || address.hasPrefix("fe9") || address.hasPrefix("fea") || address.hasPrefix("feb")
            || address.hasPrefix("127.") || address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("169.254.") || address.hasPrefix("0.")
            || (address.allSatisfy(\.isNumber) && !address.isEmpty)
        if forbidden { throw AgentWorkflowError.insecureURL }
        if let first = address.split(separator: ".").first.flatMap({ Int($0) }), first == 172,
           let second = address.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), (16...31).contains(second) { throw AgentWorkflowError.insecureURL }
    }

    private static func derivedName(_ url: URL) -> String {
        let value = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return value.isEmpty ? "Imported skill" : value
    }

    private static func parseSkill(_ markdown: String) -> (name: String?, description: String?, source: String?, body: String) {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"), let range = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else { return (nil, nil, nil, normalized) }
        let header = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<range.lowerBound]
        var values: [String: String] = [:]
        var inMetadata = false
        for line in header.split(separator: "\n") {
            let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { value = decoded }
            if indentation == 0 { inMetadata = key == "metadata" && value.isEmpty }
            if indentation == 0, ["name", "description", "source"].contains(key) { values[key] = value }
            if indentation > 0, inMetadata, key == "source" { values["source"] = value }
        }
        return (values["name"], values["description"], values["source"], String(normalized[range.upperBound...]))
    }
}
