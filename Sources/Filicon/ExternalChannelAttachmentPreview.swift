import Foundation
import FiliconAgents
import FiliconDomain

enum ExternalChannelAttachmentLocation: Equatable {
    case direct(conversationID: UUID, messageID: UUID)
    case group(groupID: UUID, messageID: UUID)

    func matches(_ publication: ExternalChannelTranscriptPublication) -> Bool {
        switch (self, publication.route) {
        case (.direct(let id, let message), .directConversation), (.group(let id, let message), .groupConversation):
            return id == publication.conversationID && message == publication.deliveryID
        default: return false
        }
    }
}

/// Native-only receipt of a resolved canonical host. Decoded card fields cannot
/// construct one or substitute a later binding for a queued click.
final class ExternalChannelAttachmentPreviewContext: Sendable {
    let publication: ExternalChannelTranscriptPublication
    let generation: UInt64
    let binding: ConversationBindingLease?
    let group: GroupReadStateLease?
    private let scope = AgentWorkflowExecutionScope()
    private let lease: AgentWorkflowExecutionScope.Lease

    init(publication: ExternalChannelTranscriptPublication, generation: UInt64,
         accountLease: AgentWorkflowExecutionScope.Lease, binding: ConversationBindingLease? = nil,
         group: GroupReadStateLease? = nil) throws {
        self.publication = publication; self.generation = generation; self.binding = binding
        lease = try scope.capture(inheriting: accountLease)
        self.group = try group?.scoped(inheriting: lease)
    }

    var isActive: Bool { (try? commit {}) != nil }
    func close() { scope.invalidate(); binding?.close(); group?.close() }

    func commit<Value>(_ operation: () throws -> Value) throws -> Value {
        if let group { return try group.withValidMembership(operation) }
        guard let binding else { throw CancellationError() }
        return try lease.commit { try binding.withValidBinding(operation) }
    }

    func metadata(for file: ExternalChannelTranscriptPublication.File) throws -> AttachmentMetadata {
        guard publication.isValid, publication.files.contains(file) else { throw AttachmentPreviewError.previewFileUnavailable }
        let kind: AttachmentKind = file.mimeType.hasPrefix("image/") ? .image
            : file.mimeType.hasPrefix("video/") ? .video : file.mimeType.hasPrefix("audio/") ? .audio
            : file.mimeType.hasPrefix("text/") || file.mimeType == "application/pdf" ? .document : .other
        return .init(id: file.digest, filename: file.filename, mimeType: file.mimeType,
                     byteCount: file.byteCount, kind: kind, createdAt: publication.queuedAt,
                     altText: publication.sources.first?.alt)
    }
}
