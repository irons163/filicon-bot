import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAgents

@Suite("Remote image gallery model")
struct RemoteImageGalleryTests {
    @Test func roundTripsBothMessageKindsAndLegacyState() throws {
        let gallery = try RemoteImageGallery(images: [
            RemoteAttachmentReference(url: "https://example.com/first?sig=a%2Bb", alt: "First"),
            RemoteAttachmentReference(url: "https://example.com/second", alt: "Second")])
        var direct = ChatMessage(role: .assistant, text: "Compare", remoteImages: gallery)
        let room = RoomMessage(groupID: UUID(), senderID: UUID(), text: "Compare", remoteImages: gallery)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(direct)), direct)
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(room)), room)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
        fields.removeValue(forKey: "remoteImages")
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self,
            from: JSONSerialization.data(withJSONObject: fields)).remoteImages, nil)
        direct.prepareForResend()
        expectNoDifference(direct.remoteImages, nil)
    }

    @Test func rejectsInvalidCountsAndDuplicateSourcesOnDecode() throws {
        let url = "https://example.com/image"
        for images in [[], Array(repeating: ["url": url], count: 5),
                       [["url": url, "alt": "A"], ["url": url, "alt": "B"]]] as [[[String: String]]] {
            let data = try JSONSerialization.data(withJSONObject: ["images": images])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RemoteImageGallery.self, from: data) }
        }
    }
}
