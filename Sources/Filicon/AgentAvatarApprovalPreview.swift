import AppKit
import CryptoKit
import FiliconAgents
import Foundation
import ImageIO

/// Kept only in memory for one approval. Raw pixels never enter approval
/// metadata, transcript cards or audit logs, and rendering never reads a URL.
struct AgentAvatarApprovalPreview: Sendable, Equatable {
    let agentID: UUID
    let proposed: PreparedAgentAvatar
    let previous: AgentAvatar?
    let previousPNG: Data?

    init(agentID: UUID, proposed: PreparedAgentAvatar, previous: AgentAvatar?, previousPNG: Data?) {
        self.agentID = agentID; self.proposed = proposed; self.previous = previous
        self.previousPNG = Self.validPNG(previousPNG, hash: previous?.imageHash) ? previousPNG : nil
    }

    func matches(_ metadata: [String: String]) -> Bool {
        metadata["agentStateTarget"] == "avatar" && metadata["agentAvatarAction"] == "set"
            && metadata["agentAvatarOwner"] == agentID.uuidString
            && metadata["agentAvatarImageHash"] == proposed.avatar.imageHash
            && Self.validPNG(proposed.pngData, hash: proposed.avatar.imageHash)
    }

    static func validPNG(_ data: Data?, hash: String?) -> Bool {
        guard let data, let hash, !data.isEmpty, data.count < 1_024 * 1_024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash.lowercased(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 256,
              (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 256 else { return false }
        return true
    }
}
