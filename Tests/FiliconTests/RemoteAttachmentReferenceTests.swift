import CustomDump
import Foundation
import Testing
import FiliconAgents

@Suite("Remote attachment locators")
struct RemoteAttachmentReferenceTests {
    @Test(arguments: [
        "https://example.com/report.pdf",
        "https://example.com/%E5%A0%B1%E5%91%8A%20final.pdf?signature=a%2Bb%2F&part=2#page=3",
        "https://example.com:8443/video.mp4#t=10",
        "https://[2001:db8::1]/file"
    ])
    func preservesExactLocatorWithoutClaimingLocalBytes(url: String) throws {
        let value = try RemoteAttachmentReference(url: url, alt: "報告 / Report")
        expectNoDifference(value.url, url)
        let data = try JSONEncoder().encode(value)
        expectNoDifference(try JSONDecoder().decode(RemoteAttachmentReference.self, from: data), value)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        expectNoDifference(Set(fields.keys), ["url", "alt"])
    }

    @Test(arguments: [
        "", "http://example.com/a", "file:///tmp/a", "javascript:alert(1)",
        "data:text/plain,hi", "//example.com/a", "https:///a", "https://",
        "https://user:password@example.com/a", "https://user@example.com/a",
        "https://example.com:0/a", "https://example.com:65536/a",
        "https://example.com/a\n", " https://example.com/a", "https://example.com/a b",
        "https://example.com/a%00", "https://example.com/a%0D%0Aheader:value",
        "https://example.com/a%", "https://example.com\\@other.example/a",
        "https://example.com/" + String(repeating: "x", count: 16_384)
    ])
    func rejectsUnsafeOrAmbiguousLocatorsIncludingDecodedState(url: String) throws {
        #expect(throws: RemoteAttachmentReference.ValidationError.invalidURL) {
            try RemoteAttachmentReference(url: url)
        }
        let forged = try JSONSerialization.data(withJSONObject: ["url": url])
        #expect(throws: RemoteAttachmentReference.ValidationError.invalidURL) {
            try JSONDecoder().decode(RemoteAttachmentReference.self, from: forged)
        }
    }

    @Test(arguments: ["", "  ", "line\nline", "nul\0", String(repeating: "x", count: 4_097)])
    func rejectsInvalidAlt(alt: String) throws {
        #expect(throws: RemoteAttachmentReference.ValidationError.invalidAlt) {
            try RemoteAttachmentReference(url: "https://example.com/a", alt: alt)
        }
    }
}
