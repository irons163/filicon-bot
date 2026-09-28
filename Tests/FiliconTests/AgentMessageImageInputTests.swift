import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices

@Suite("Message image source inputs")
struct AgentMessageImageInputTests {
    @Test func preservesSourceIdentityAndDescriptions() throws {
        expectNoDifference(try AgentMessageImageInput(entry: "host-id").source, .hostImage("host-id"))
        let host = try AgentMessageImageInput(entry: ["image_id": "host-id", "alt": "  圖片  "])
        expectNoDifference(host.source, .hostImage("host-id"))
        expectNoDifference(host.alt, "圖片")
        expectNoDifference(try AgentMessageImageInput(entry: ["image_id": "host-id", "alt": " "]).alt, nil)
        let local = "file:///tmp/a%20b.png"
        expectNoDifference(try AgentMessageImageInput(entry: ["url": local]).source, .localFile(local))
        let remote = "https://example.com/a?sig=x%2By"
        let input = try AgentMessageImageInput(entry: ["url": remote, "alt": "Preview"])
        expectNoDifference(input.source, .remote(try RemoteAttachmentReference(url: remote, alt: "Preview")))
    }

    @Test func rejectsAmbiguousAndUnsafeInputs() {
        let entries: [Any] = [
            ["url": "https://example.com/a", "image_id": "id"], ["image_id": 1], ["url": 1],
            ["image_id": "id", "extra": "value"], ["image_id": "id", "alt": NSNull()],
            ["image_id": "id", "alt": "bad\nalt"], ["image_id": "id", "alt": String(repeating: "a", count: 501)],
            ["url": "http://example.com/a"], ["url": "https://user:password@example.com/a"],
            ["url": "file://other/tmp/a.png"], ["url": "file:///tmp/../secret.png"],
            ["url": "file:///tmp/a%00.png"], ["url": "file:///tmp/a.png?query=1"],
            ["url": "file:///tmp/a.png#fragment"], ["url": "data:image/png;base64,abc"],
            ["url": "/tmp/a.png"], ["alt": "missing source"], NSNull()
        ]
        for entry in entries {
            #expect(throws: (any Error).self) { try AgentMessageImageInput(entry: entry) }
        }
    }
}
