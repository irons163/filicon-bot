import Foundation
import FiliconDomain

enum ProviderCatalogWireFormat: Sendable { case openAI, openRouter, anthropic, gemini, ollama }

actor ProviderModelCatalog {
    private let providerID: ProviderID
    private let baseURL: URL
    private let format: ProviderCatalogWireFormat
    private let fallback: [AIModel]
    private let credential: CredentialResolver?
    private let session: URLSession
    private let ttl: TimeInterval
    private var cached: ProviderModelCatalogSnapshot?
    private var generation: UInt64 = 0

    init(providerID: ProviderID, baseURL: URL, format: ProviderCatalogWireFormat, fallback: [AIModel],
         credential: CredentialResolver?, session: URLSession, ttl: TimeInterval = 15 * 60) {
        self.providerID = providerID; self.baseURL = baseURL; self.format = format; self.fallback = fallback
        self.credential = credential; self.session = session; self.ttl = max(5, min(ttl, 24 * 60 * 60))
    }

    func snapshot(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl { return cached }
        generation &+= 1; let current = generation
        do {
            let result = try await fetch()
            let snapshot = ProviderModelCatalogSnapshot(models: result.sorted { $0.id.rawValue < $1.id.rawValue }, source: .dynamic)
            if generation == current { cached = snapshot }
            return generation == current ? snapshot : (cached ?? snapshot)
        } catch is CancellationError {
            let value = cached ?? .init(models: fallback, source: .builtInFallback, isStale: true, errorDescription: "cancelled")
            return value
        } catch {
            guard generation == current else { return cached ?? .init(models: fallback, source: .builtInFallback, isStale: true, errorDescription: "superseded refresh") }
            if var cached { cached.isStale = true; cached.errorDescription = String(describing: error); self.cached = cached; return cached }
            let value = ProviderModelCatalogSnapshot(models: fallback, source: .builtInFallback, isStale: true, errorDescription: String(describing: error))
            if generation == current { cached = value }; return value
        }
    }

    private func fetch() async throws -> [AIModel] {
        try Task.checkCancellation()
        let endpoint: URL
        switch format {
        case .openAI, .openRouter: endpoint = baseURL.appending(path: "models")
        case .anthropic: endpoint = baseURL.appending(path: "v1/models").appending(queryItems: [.init(name: "limit", value: "1000")])
        case .gemini: endpoint = baseURL.appending(path: "v1beta/models").appending(queryItems: [.init(name: "pageSize", value: "1000")])
        case .ollama: endpoint = baseURL.appending(path: "api/tags")
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = try await credential?() ?? ""
        switch format {
        case .openAI, .openRouter: if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        case .ollama: break
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw ProviderError.invalidResponse }
        guard sameOrigin(endpoint, finalURL) else { throw ProviderError.catalog("cross-origin redirect rejected") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.httpStatus(http.statusCode, message: boundedMessage(data)) }
        guard http.mimeType == nil || http.mimeType == "application/json" || http.mimeType?.hasSuffix("+json") == true else { throw ProviderError.catalog("unexpected content type") }
        guard data.count <= 2_000_000, http.expectedContentLength <= 0 || http.expectedContentLength <= 2_000_000 else { throw ProviderError.catalog("response exceeds 2 MB") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderError.invalidResponse }
        let models = try parse(root)
        guard !models.isEmpty, models.count <= 1_000 else { throw ProviderError.catalog("model count is empty or exceeds 1000") }
        return models
    }

    private func parse(_ root: [String: Any]) throws -> [AIModel] {
        let rows: [[String: Any]]
        switch format {
        case .openAI, .openRouter, .anthropic: rows = root["data"] as? [[String: Any]] ?? []
        case .gemini: rows = root["models"] as? [[String: Any]] ?? []
        case .ollama: rows = root["models"] as? [[String: Any]] ?? []
        }
        guard rows.count <= 1_000 else { throw ProviderError.catalog("model count exceeds 1000") }
        var seen = Set<String>(), result: [AIModel] = []
        for row in rows {
            let rawID: String?
            switch format {
            case .gemini: rawID = (row["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            case .ollama: rawID = row["name"] as? String ?? row["model"] as? String
            default: rawID = row["id"] as? String
            }
            guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  id.utf8.count <= 256, seen.insert(id).inserted else { continue }
            if case .openAI = format {
                let value = id.lowercased()
                guard !["embedding", "moderation", "whisper", "tts", "dall-e", "image-", "audio-"].contains(where: value.contains) else { continue }
            }
            if case .gemini = format {
                let methods = Set(row["supportedGenerationMethods"] as? [String] ?? [])
                guard methods.contains("generateContent") || methods.contains("streamGenerateContent") else { continue }
            }
            let display: String
            switch format {
            case .openRouter: display = bounded(row["name"] as? String) ?? id
            case .anthropic: display = bounded(row["display_name"] as? String) ?? id
            case .gemini: display = bounded(row["displayName"] as? String) ?? id
            default: display = id
            }
            let context: Int?, output: Int?, capabilities: AIModelCapabilities
            switch format {
            case .openRouter:
                context = boundedInt(row["context_length"])
                output = boundedInt((row["top_provider"] as? [String: Any])?["max_completion_tokens"])
                let architecture = row["architecture"] as? [String: Any]
                var inputs = modalities(architecture?["input_modalities"] as? [String]); inputs.insert(.text)
                var outputs = modalities(architecture?["output_modalities"] as? [String]); outputs.insert(.text)
                let parameters = Set(row["supported_parameters"] as? [String] ?? [])
                let efforts: Set<ReasoningEffort> = parameters.contains("reasoning") || parameters.contains("reasoning_effort") ? [.disabled, .low, .medium, .high] : [.disabled]
                capabilities = .init(inputModalities: inputs.union(parameters.contains("tools") ? [.tools] : []), outputModalities: outputs, reasoningEfforts: efforts)
            case .gemini:
                context = boundedInt(row["inputTokenLimit"]); output = boundedInt(row["outputTokenLimit"])
                let methods = Set(row["supportedGenerationMethods"] as? [String] ?? [])
                capabilities = .init(inputModalities: methods.contains("generateContent") ? [.text, .image, .audio, .video, .document, .tools] : [.text], reasoningEfforts: inferredEfforts(id))
            case .ollama:
                context = nil; output = nil
                let caps = Set(row["capabilities"] as? [String] ?? [])
                var inputs: Set<AIModelModality> = [.text]
                if caps.contains("vision") { inputs.insert(.image) }; if caps.contains("tools") { inputs.insert(.tools) }
                capabilities = .init(inputModalities: inputs, reasoningEfforts: caps.contains("thinking") ? [.disabled, .low, .medium, .high] : [.disabled])
            case .openAI:
                context = nil; output = nil
                let value = id.lowercased(), multimodal = value.contains("gpt-4o") || value.contains("gpt-4.1") || value.contains("gpt-5") || value.hasPrefix("o")
                capabilities = .init(inputModalities: multimodal ? [.text, .image, .document, .tools] : [.text], reasoningEfforts: inferredEfforts(id))
            case .anthropic:
                context = nil; output = nil; capabilities = .init(inputModalities: [.text, .image, .document, .tools], reasoningEfforts: inferredEfforts(id))
            }
            result.append(.init(id: ModelID(rawValue: id), displayName: display, capabilities: capabilities,
                                contextWindow: context, maximumOutputTokens: output,
                                isDeprecated: (row["deprecated"] as? Bool) == true))
        }
        return result
    }

    private func inferredEfforts(_ id: String) -> Set<ReasoningEffort> {
        let value = id.lowercased()
        switch format {
        case .openAI where value.hasPrefix("o") || value.contains("gpt-5"): return [.disabled, .minimal, .low, .medium, .high]
        case .anthropic where value.contains("claude-3-7") || value.contains("claude-4"): return [.disabled, .low, .medium, .high]
        case .gemini where value.contains("2.5") || value.contains("3-"): return [.disabled, .low, .medium, .high]
        default: return [.disabled]
        }
    }

    private func modalities(_ values: [String]?) -> Set<AIModelModality> {
        Set((values ?? []).compactMap { AIModelModality(rawValue: $0 == "file" ? "document" : $0) })
    }
    private func bounded(_ value: String?) -> String? { guard let value, !value.isEmpty, value.utf8.count <= 512 else { return nil }; return value }
    private func boundedInt(_ value: Any?) -> Int? { guard let value = value as? Int, (1...10_000_000).contains(value) else { return nil }; return value }
    private func boundedMessage(_ data: Data) -> String { String(decoding: data.prefix(2_048), as: UTF8.self) }
    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(lhs)) == (rhs.port ?? defaultPort(rhs))
    }
    private func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }
}
