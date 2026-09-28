import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconAppServices

private actor GalleryPublicationProbe {
    var events: [String] = []
    var valid = true
    func record(_ event: String) { events.append(event) }
    func revoke() { valid = false }
    func validate() throws {
        guard valid else { throw AgentGalleryPublicationTransaction.Failure.unavailable }
    }
}

@Suite("Atomic reviewed text and image gallery", .timeLimit(.minutes(1)))
struct AgentGalleryPublicationTransactionTests {
    @Test(arguments: ["success", "deny", "revoke", "wrong-scope", "empty", "uncertain",
                      "text", "order", "description", "reply", "sender", "destination", "mixed"])
    func wholeMessageMustMatchApproval(mode: String) async throws {
        let origin = UUID(), destination = UUID(), sender = UUID(), reply = UUID()
        let gallery = try RemoteImageGallery(images: [RemoteAttachmentReference(url: "https://example.com/a", alt: "A"),
            RemoteAttachmentReference(url: "https://example.com/b", alt: "B")])
        let probe = GalleryPublicationProbe()
        let transaction = AgentGalleryPublicationTransaction(conversationID: origin, senderID: sender,
            destinationConversationID: destination, validateScope: { try await probe.validate() },
            authorize: { review, _, _ in
                await probe.record("approve")
                expectNoDifference(review.text, "Compare these")
                expectNoDifference(review.gallery, gallery)
                expectNoDifference(review.conversationID, destination)
                expectNoDifference(review.replyTo, reply)
                if mode == "deny" { throw AgentGalleryPublicationTransaction.Failure.unavailable }
                if mode == "revoke" { await probe.revoke() }
            }, commit: { review, _, _ in
                await probe.record("commit")
                if mode == "uncertain" { throw AgentGalleryPublicationTransaction.Failure.uncertainCommit }
                var images = review.gallery.images
                if mode == "order" { images.reverse() }
                if mode == "description" { images[0] = try RemoteAttachmentReference(url: images[0].url, alt: "Changed") }
                var message = RoomMessage(groupID: mode == "destination" ? UUID() : review.conversationID,
                    senderID: mode == "sender" ? UUID() : review.senderID,
                    text: mode == "text" ? "Changed" : review.text,
                    remoteAttachment: mode == "mixed" ? images[0] : nil,
                    remoteImages: try RemoteImageGallery(images: images))
                message.replyToMessageID = mode == "reply" ? nil : review.replyTo
                return .init(review: review, message: message)
            })
        let context = ToolContext(conversationID: mode == "wrong-scope" ? UUID() : origin)
        let call = try NormalizedToolCall(id: "gallery", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let text = mode == "empty" ? " " : "Compare these"
        do {
            let receipt = try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
            expectNoDifference(mode, "success")
            expectNoDifference(receipt.message.remoteImages, gallery)
            await transaction.close()
            let replay = try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
            expectNoDifference(replay, receipt)
            await #expect(throws: AgentGalleryPublicationTransaction.Failure.duplicateCall) {
                try await transaction.publish(text: "Changed", gallery: gallery, replyTo: reply, call: call, context: context)
            }
        } catch let error as AgentGalleryPublicationTransaction.Failure {
            #expect(mode != "success")
            let expected: AgentGalleryPublicationTransaction.Failure = switch mode {
            case "deny", "revoke", "wrong-scope": .unavailable
            case "empty": .invalidText
            case "uncertain": .uncertainCommit
            default: .invalidReceipt
            }
            expectNoDifference(error, expected)
            if expected == .invalidReceipt || expected == .uncertainCommit {
                await #expect(throws: AgentGalleryPublicationTransaction.Failure.uncertainCommit) {
                    try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
                }
            }
        }
        let events = await probe.events
        expectNoDifference(events, ["empty", "wrong-scope"].contains(mode) ? [] :
            ["deny", "revoke"].contains(mode) ? ["approve"] : ["approve", "commit"])
    }
}
