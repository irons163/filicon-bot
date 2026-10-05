import Foundation
import FiliconAppServices
import FiliconDomain
import FiliconLocalTools

struct AgentPublicationFileSource: Sendable {
    let reader: AuthorizedAgentFileReader

    // Current helper transport is bounded to 10 MiB. Larger file/media transport
    // remains separate work; this is not the final publication size contract.
    static let maximumBytes = 10 * 1_024 * 1_024

    func prepare(url: String, agentID: UUID, call: NormalizedToolCall,
                 context: ToolContext) async throws -> PreparedAgentPublicationFile {
        let path = try Self.localPath(url)
        let filename = (path as NSString).lastPathComponent
        guard filename.utf8.count <= 255, !filename.contains("\\") else {
            throw LocalToolError.pathEscape
        }
        let bytes = try await reader.read(path: path, agentID: agentID, call: call, context: context,
            receiptPrefix: "publication-source", maximumBytes: Self.maximumBytes)
        return try PreparedAgentPublicationFile(bytes: bytes, filename: filename)
    }

    static func localPath(_ value: String) throws -> String {
        guard value.utf8.count <= 16_384,
              let components = URLComponents(string: value), components.scheme == "file",
              components.host == nil || components.host == "",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url, url.isFileURL else { throw LocalToolError.pathEscape }
        // Decode explicitly: Foundation's file URL path can discard embedded
        // NULs. Never authorize a normalized target different from the input.
        guard let path = components.percentEncodedPath.removingPercentEncoding else {
            throw LocalToolError.pathEscape
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              url.standardizedFileURL.path == path else { throw LocalToolError.pathEscape }
        return path
    }
}

/// Channel publication obtains bytes, not a remote link card. Reading a local
/// file, downloading each HTTPS destination, and sending externally are distinct
/// host decisions. This adapter neither installs a blob nor queues a message.
struct AgentChannelAttachmentSource: Sendable {
    typealias PrepareLocal = @Sendable (String, NormalizedToolCall, ToolContext) async throws -> PreparedAgentPublicationFile
    typealias AuthorizeDownload = @Sendable (RemoteAttachmentReference, RemoteAttachmentReference?, NormalizedToolCall, ToolContext) async throws -> Void
    let prepareLocal: PrepareLocal
    let downloader: any RemoteAttachmentDownloading
    let validateScope: @Sendable () async throws -> Void
    let authorizeDownload: AuthorizeDownload
    // Preserve the app-wide quota ceiling; the connector's 25 MiB limit is not
    // permission to exceed the host's 8 MiB per-record storage budget.
    static let maximumBytes = 8 * 1_024 * 1_024

    func prepare(_ input: AgentMessageImageInput, isImage: Bool, call: NormalizedToolCall,
        context: ToolContext) async throws -> PreparedAgentChannelAttachment {
        try await checkScope()
        let file: PreparedAgentPublicationFile
        switch input.source {
        case .hostImage: throw AgentImageError.unavailable
        case .localFile(let url):
            file = try await prepareLocal(url, call, context)
        case .remote(let reference):
            let filename = try Self.filename(for: reference)
            try await authorizeDownload(reference, nil, call, context)
            try await checkScope()
            let downloaded = try await downloader.downloadFollowingReviewedRedirects(reference,
                maximumBytes: isImage ? AgentImageStore.maximumBytes : Self.maximumBytes) { from, to in
                    try await checkScope()
                    try await authorizeDownload(to, from, call, context)
                    try await checkScope()
                    return true
                }
            try await checkScope()
            guard downloaded.reference == reference else { throw RemoteAttachmentDownloadError.invalidResponse }
            guard !downloaded.data.isEmpty else { throw RemoteAttachmentDownloadError.empty }
            guard downloaded.data.count <= Self.maximumBytes else { throw RemoteAttachmentDownloadError.tooLarge }
            file = try PreparedAgentPublicationFile(bytes: downloaded.data, filename: filename)
        }
        try await checkScope()
        guard file.bytes.count <= Self.maximumBytes else {
            throw AttachmentStoreError.tooLarge(filename: file.filename, limitBytes: Int64(Self.maximumBytes))
        }
        let verifiedImage = isImage ? try AgentImageStore.validatePublishedImage(file.bytes) : nil
        let metadata = try AttachmentStore.publicationMetadata(for: file,
            createdAt: Date(timeIntervalSince1970: 0), verifiedImageMIMEType: verifiedImage)
        try await checkScope()
        return try PreparedAgentChannelAttachment(file: file, mimeType: metadata.mimeType)
    }

    private func checkScope() async throws {
        try Task.checkCancellation()
        try await validateScope()
        try Task.checkCancellation()
    }

    private static func filename(for reference: RemoteAttachmentReference) throws -> String {
        guard let url = URL(string: reference.url) else { throw RemoteAttachmentDownloadError.invalidResponse }
        let name = url.lastPathComponent.isEmpty ? "remote-attachment" : url.lastPathComponent
        // Reject ambiguous names before asking for approval or making a request.
        return try PreparedAgentPublicationFile(bytes: Data(), filename: name).filename
    }
}
