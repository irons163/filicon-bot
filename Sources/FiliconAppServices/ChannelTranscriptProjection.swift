import Foundation
import FiliconDomain
import FiliconChannels

/// Pure projection of an authoritative outbox snapshot. No store, source URL,
/// connector, credential, approval, or model is accessed here.
public enum ChannelTranscriptProjection {
    public static func publication(for delivery: ChannelDelivery) -> ExternalChannelTranscriptPublication? {
        guard let origin = delivery.origin, let authorization = delivery.authorization,
              origin.isConsistent(agentID: authorization.agentID, outbound: delivery.outbound),
              let route = ExternalChannelTranscriptPublication.Route(rawValue: origin.route.rawValue),
              let kind = ExternalChannelTranscriptPublication.Kind(rawValue: origin.intent.kind.rawValue),
              let status = ExternalChannelTranscriptPublication.Status(rawValue: delivery.status.rawValue) else { return nil }
        let value = ExternalChannelTranscriptPublication(deliveryID: delivery.id, connectionID: delivery.connectionID,
            owner: .init(accountID: authorization.ownerAccountID, agentID: authorization.agentID), route: route,
            conversationID: origin.conversationID, senderID: origin.senderID, senderName: origin.senderName,
            runID: origin.runID, callID: origin.callID, replyToMessageID: origin.replyToMessageID,
            queuedAt: delivery.createdAt, kind: kind, text: origin.intent.text,
            sources: origin.intent.sources.map { .init(url: $0.url, alt: $0.alt) },
            files: delivery.outbound.attachments.map { .init(digest: $0.blobID, filename: $0.filename,
                mimeType: $0.mimeType, byteCount: Int64($0.byteCount)) }, platform: delivery.address.platform,
            channelID: delivery.address.channelID, threadID: delivery.address.threadID,
            delivery: .init(status: status, attemptCount: delivery.attemptCount, deliveredAt: delivery.deliveredAt))
        return value.isValid ? value : nil
    }
}
