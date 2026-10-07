import Foundation

/// Locates the accepted remote message behind a native question/secure-input
/// card. These IDs are not a permission, saved execution, or delivery grant.
/// A human response must resolve them against the current native stores.
public struct ChannelInboundCardOrigin: Codable, Hashable, Sendable {
    public let runID: UUID
    public let messageID: UUID

    public init(runID: UUID, messageID: UUID) {
        self.runID = runID; self.messageID = messageID
    }

    private enum CodingKeys: String, CodingKey { case runID, messageID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runID = try values.decode(UUID.self, forKey: .runID)
        messageID = try values.decode(UUID.self, forKey: .messageID)
        guard runID != messageID else {
            throw DecodingError.dataCorruptedError(forKey: .messageID, in: values,
                debugDescription: "Incoming card locators must have distinct identities")
        }
    }
}

extension TranscriptCard {
    public var directChannelInboundOrigin: ChannelInboundCardOrigin? {
        switch payload {
        case .widget(let value): value.channelInboundOrigin
        case .secretRequest(let value): value.channelInboundOrigin
        default: nil
        }
    }
}
