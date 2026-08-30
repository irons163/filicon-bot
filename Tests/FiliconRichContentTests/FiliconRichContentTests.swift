import Foundation
import Testing
@testable import FiliconRichContent

@Suite("Markdown content")
struct MarkdownContentTests {
    let parser = RichMarkdownParser()

    @Test func proseAndExplicitMathAreOrdered() {
        #expect(parser.parse("before \\(x_1\\) after") == [.prose("before "), .math(source: "x_1", mode: .inline), .prose(" after")])
        #expect(parser.parse("\\[x^2\\]") == [.math(source: "x^2", mode: .display)])
    }

    @Test func singleDollarAndEscapedDelimiterStayProse() {
        #expect(parser.parse("It costs $5 and $x$ stays literal") == [.prose("It costs $5 and $x$ stays literal")])
        #expect(parser.parse(#"literal \\(not math\\)"#) == [.prose(#"literal \\(not math\\)"#)])
    }

    @Test func displayDollarBlocks() {
        #expect(parser.parse("$$\na+b\n$$") == [.math(source: "a+b", mode: .display)])
        #expect(parser.parse("$$a+b$$") == [.math(source: "a+b", mode: .display)])
        #expect(parser.parse("$$\nunclosed") == [.prose("$$\nunclosed")])
    }

    @Test func codeFencesTrackTerminationAndLanguage() {
        #expect(parser.parse("```swift extra\nlet x = 1\n```") == [.code(language: "swift", source: "let x = 1", isTerminated: true)])
        #expect(parser.parse("~~~~ js\nx()") == [.code(language: "js", source: "x()", isTerminated: false)])
    }

    @Test func mermaidFenceUsesNativeParser() {
        let blocks = parser.parse("```mermaid\nflowchart LR\nA[Start] --> B[Done]\n```")
        guard case .mermaid(_, .diagram(let diagram)) = blocks.first else { Issue.record("expected diagram"); return }
        #expect(diagram.kind == .flowchart)
        #expect(diagram.nodes.map(\.id) == ["A", "B"])
    }

    @Test func gfmTableAndEscapedPipe() {
        #expect(parser.parse("| Name | Value |\n| :--- | ---: |\n| a\\|b | 2 |") == [.table(.init(headers: ["Name", "Value"], rows: [["a|b", "2"]]))])
    }

    @Test func setextHeadingIsNotMistakenForTable() {
        #expect(parser.parse("Heading\n---") == [.prose("Heading\n---")])
    }
}

@Suite("Offline math")
struct OfflineMathTests {
    @Test func supportedLatexBecomesSelfContainedMathML() {
        let result = OfflineMathPresenter().presentation(for: #"\frac{a_1}{\sqrt{2}}"#, mode: .display)
        guard case .mathML(let value) = result else { Issue.record("expected MathML"); return }
        #expect(value.hasPrefix("<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\">"))
        #expect(value.contains("<mfrac>"))
        #expect(!value.lowercased().contains("script"))
    }

    @Test func unsupportedUnsafeOrOversizedLatexFallsBackExactly() {
        for source in [#"\href{x}{y}"#, "x\u{0}y", String(repeating: "a", count: 16_385), "   "] {
            #expect(OfflineMathPresenter().presentation(for: source, mode: .inline) == .fallback(original: source))
        }
    }
}

@Suite("Native Mermaid")
struct MermaidTests {
    let parser = MermaidParser()

    @Test func commonFlowchart() {
        guard case .diagram(let diagram) = parser.parse("FLOWCHART LR\nA[Start] -->|ok| B((Done))") else { Issue.record("expected diagram"); return }
        #expect(diagram.kind == .flowchart)
        #expect(diagram.nodes == [.init(id: "A", label: "Start"), .init(id: "B", label: "Done")])
        #expect(diagram.edges == [.init(from: "A", to: "B", label: "ok")])
    }

    @Test func commonSequence() {
        guard case .diagram(let diagram) = parser.parse("sequenceDiagram\nparticipant A as Alice\nactor B as Bob\nA-->>B: Hello") else { Issue.record("expected diagram"); return }
        #expect(diagram.kind == .sequence)
        #expect(diagram.nodes.map(\.label) == ["Alice", "Bob"])
        #expect(diagram.edges == [.init(from: "A", to: "B", label: "Hello")])
    }

    @Test func commonStateWithBoundary() {
        guard case .diagram(let diagram) = parser.parse("stateDiagram-v2\n[*] --> Idle\nIdle --> [*]: stop") else { Issue.record("expected diagram"); return }
        #expect(diagram.kind == .state)
        #expect(diagram.nodes.map(\.id) == ["__state_boundary", "Idle"])
        #expect(diagram.edges.count == 2)
    }

    @Test func activeContentAndControlsAreRejected() {
        let inputs = ["flowchart LR\nA[<b>x</b>]", "flowchart LR\nclick A https://example.com", "flowchart LR\nA --> B\nlinkStyle 0 stroke:red", "flowchart LR\nA\u{0} --> B", "flowchart LR\nA[broken"]
        for source in inputs {
            guard case .fallback = parser.parse(source) else { Issue.record("accepted unsafe source: \(source)"); continue }
        }
    }

    @Test func limitsAreEnforced() {
        var limits = MermaidLimits(); limits.maximumNodes = 1; limits.maximumEdges = 1; limits.maximumLabelCharacters = 3
        let bounded = MermaidParser(limits: limits)
        for source in ["flowchart LR\nA --> B", "flowchart LR\nA[long]"] {
            guard case .fallback = bounded.parse(source) else { Issue.record("expected bounds fallback"); continue }
        }
    }

    @Test func unsupportedDiagramFallsBackWithOriginal() {
        let source = "pie\n\"A\" : 1"
        #expect(parser.parse(source) == .fallback(original: source, reason: "unsupported_diagram"))
    }
}

private enum FixtureError: Error { case failed }

private struct FixtureResolver: SafeLinkResolving {
    let values: [String: [ResolvedAddress]]
    var failing = false
    func resolve(host: String) async throws -> [ResolvedAddress] {
        if failing { throw FixtureError.failed }
        return values[host] ?? []
    }
}

private actor FixtureTransport: SafeLinkTransporting {
    nonisolated let supportsAddressPinning: Bool
    private var responses: [SafeLinkResponse]
    private var sent: [SafeLinkRequest] = []
    init(pinning: Bool = true, responses: [SafeLinkResponse]) { supportsAddressPinning = pinning; self.responses = responses }
    func send(_ request: SafeLinkRequest) async throws -> SafeLinkResponse {
        sent.append(request)
        guard !responses.isEmpty else { throw FixtureError.failed }
        return responses.removeFirst()
    }
    func requests() -> [SafeLinkRequest] { sent }
}

private actor RacingTransport: SafeLinkTransporting {
    nonisolated let supportsAddressPinning = true
    let address: ResolvedAddress
    private var callCount = 0
    init(address: ResolvedAddress) { self.address = address }
    func send(_ request: SafeLinkRequest) async throws -> SafeLinkResponse {
        callCount += 1
        let call = callCount
        if call == 1 { try await Task.sleep(for: .milliseconds(40)) }
        let title = call == 1 ? "stale" : "fresh"
        return .init(statusCode: 200, headers: ["Content-Type": "text/html"], body: Data("<title>\(title)</title>".utf8), connectedAddress: address)
    }
}

@Suite("Safe link metadata")
struct SafeLinkTests {
    let publicV4 = SafeLinkMetadataClient.parseIPAddress("8.8.8.8")!
    let secondV4 = SafeLinkMetadataClient.parseIPAddress("1.1.1.1")!

    func response(_ body: String, address: ResolvedAddress? = nil, status: Int = 200, headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]) -> SafeLinkResponse {
        .init(statusCode: status, headers: headers, body: Data(body.utf8), connectedAddress: address ?? publicV4)
    }

    @Test func publicAddressClassificationRejectsPrivateAndReservedRanges() {
        #expect(SafeLinkMetadataClient.isPublic(publicV4))
        for host in ["0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "192.0.0.9", "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1"] {
            #expect(!SafeLinkMetadataClient.isPublic(SafeLinkMetadataClient.parseIPAddress(host)!))
        }
    }

    @Test func ipv6ClassificationRejectsLocalReservedAndTunneledPrivate() {
        #expect(SafeLinkMetadataClient.isPublic(SafeLinkMetadataClient.parseIPAddress("2606:4700:4700::1111")!))
        for host in ["::", "::1", "fc00::1", "fe80::1", "fec0::1", "ff02::1", "2001:db8::1", "2001:20::1", "3fff::1", "::ffff:10.0.0.1", "64:ff9b::0a00:0001", "2002:0a00:0001::"] {
            #expect(!SafeLinkMetadataClient.isPublic(SafeLinkMetadataClient.parseIPAddress(host)!))
        }
    }

    @Test func rejectsSchemesCredentialsLocalAndMixedDNS() async {
        let resolver = FixtureResolver(values: ["mixed.example": [publicV4, SafeLinkMetadataClient.parseIPAddress("127.0.0.1")!]])
        let client = SafeLinkMetadataClient(resolver: resolver, transport: FixtureTransport(responses: []))
        for url in ["file:///tmp/a", "http://example.com", "https://user:pass@example.com", "https://localhost/x", "https://printer", "https://service.lan", "https://mixed.example"] {
            do { _ = try await client.metadata(for: URL(string: url)!); Issue.record("accepted \(url)") }
            catch { #expect((error as? SafeLinkError) == .invalidURL || (error as? SafeLinkError) == .forbiddenHost) }
        }
    }

    @Test func requiresPinnedTransportAndMatchingPeer() async {
        let resolver = FixtureResolver(values: ["example.com": [publicV4]])
        let unavailable = SafeLinkMetadataClient(resolver: resolver, transport: FixtureTransport(pinning: false, responses: []))
        do { _ = try await unavailable.metadata(for: URL(string: "https://example.com")!); Issue.record("expected rejection") }
        catch { #expect((error as? SafeLinkError) == .addressPinningUnavailable) }

        let mismatch = SafeLinkMetadataClient(resolver: resolver, transport: FixtureTransport(responses: [response("<title>x</title>", address: secondV4)]))
        do { _ = try await mismatch.metadata(for: URL(string: "https://example.com")!); Issue.record("expected rejection") }
        catch { #expect((error as? SafeLinkError) == .connectedAddressMismatch) }
    }

    @Test func redirectReResolvesAndPreservesHTTPS() async throws {
        let resolver = FixtureResolver(values: ["a.example": [publicV4], "b.example": [secondV4]])
        let transport = FixtureTransport(responses: [response("", status: 302, headers: ["Location": "https://b.example/final"]), response("<title>Final</title>", address: secondV4)])
        let value = try await SafeLinkMetadataClient(resolver: resolver, transport: transport).metadata(for: URL(string: "https://a.example")!)
        #expect(value.url == URL(string: "https://b.example/final")!)
        #expect(await transport.requests().map(\.approvedAddresses) == [[publicV4], [secondV4]])
    }

    @Test func redirectDowngradeAndLimitAreRejected() async {
        let resolver = FixtureResolver(values: ["example.com": [publicV4]])
        let downgrade = FixtureTransport(responses: [response("", status: 302, headers: ["Location": "http://example.com"] )])
        do { _ = try await SafeLinkMetadataClient(resolver: resolver, transport: downgrade).metadata(for: URL(string: "https://example.com")!); Issue.record("expected downgrade") }
        catch { #expect((error as? SafeLinkError) == .redirectDowngrade) }

        var policy = SafeLinkPolicy(); policy.maximumRedirects = 0
        let limited = FixtureTransport(responses: [response("", status: 302, headers: ["Location": "/next"] )])
        do { _ = try await SafeLinkMetadataClient(resolver: resolver, transport: limited, policy: policy).metadata(for: URL(string: "https://example.com")!); Issue.record("expected limit") }
        catch { #expect((error as? SafeLinkError) == .redirectLimit) }
    }

    @Test func bodyDeclaredLengthAndContentTypeAreBounded() async {
        let resolver = FixtureResolver(values: ["example.com": [publicV4]])
        var policy = SafeLinkPolicy(); policy.maximumBodyBytes = 8
        let cases: [(SafeLinkResponse, SafeLinkError)] = [(response("x", headers: ["Content-Type": "text/html", "Content-Length": "9"]), .responseTooLarge), (response("123456789"), .responseTooLarge), (response("x", headers: ["Content-Type": "application/json"]), .unsupportedContentType)]
        for (fixture, expected) in cases {
            let client = SafeLinkMetadataClient(resolver: resolver, transport: FixtureTransport(responses: [fixture]), policy: policy)
            do { _ = try await client.metadata(for: URL(string: "https://example.com")!); Issue.record("expected rejection") }
            catch { #expect((error as? SafeLinkError) == expected) }
        }
    }

    @Test func extractsSanitizesBoundsAndValidatesImage() async throws {
        let resolver = FixtureResolver(values: ["example.com": [publicV4], "cdn.example": [secondV4]])
        let html = """
        <meta content="A &amp; <b>title</b>" property="og:title">
        <meta content="  useful   summary " name="description">
        <meta content="https://cdn.example/image.png" property="og:image">
        """
        var policy = SafeLinkPolicy(); policy.maximumTitleCharacters = 7
        let value = try await SafeLinkMetadataClient(resolver: resolver, transport: FixtureTransport(responses: [response(html)]), policy: policy).metadata(for: URL(string: "https://example.com/page")!)
        #expect(value.title == "A & tit")
        #expect(value.summary == "useful summary")
        #expect(value.imageURL == URL(string: "https://cdn.example/image.png")!)
    }

    @Test func cacheForceRefreshAndInvalidation() async throws {
        let resolver = FixtureResolver(values: ["example.com": [publicV4]])
        let transport = FixtureTransport(responses: [response("<title>one</title>"), response("<title>two</title>"), response("<title>three</title>")])
        let client = SafeLinkMetadataClient(resolver: resolver, transport: transport)
        let url = URL(string: "https://example.com/#fragment")!
        #expect(try await client.metadata(for: url).title == "one")
        #expect(await transport.requests().first?.url.fragment == nil)
        #expect(try await client.metadata(for: URL(string: "https://example.com/")!).title == "one")
        #expect(try await client.metadata(for: url, forceRefresh: true).title == "two")
        await client.invalidate(url)
        #expect(try await client.metadata(for: url).title == "three")
        #expect(await transport.requests().count == 3)
    }

    @Test func slowerGenerationCannotOverwriteForcedRefresh() async throws {
        let resolver = FixtureResolver(values: ["example.com": [publicV4]])
        let client = SafeLinkMetadataClient(resolver: resolver, transport: RacingTransport(address: publicV4))
        let url = URL(string: "https://example.com")!
        async let stale = client.metadata(for: url)
        try await Task.sleep(for: .milliseconds(10))
        #expect(try await client.metadata(for: url, forceRefresh: true).title == "fresh")
        #expect(try await stale.title == "stale")
        #expect(try await client.metadata(for: url).title == "fresh")
    }

    @Test func invalidPolicyDoesNotTrap() async {
        var policy = SafeLinkPolicy(); policy.maximumRedirects = -1
        let client = SafeLinkMetadataClient(resolver: FixtureResolver(values: [:]), transport: FixtureTransport(responses: []), policy: policy)
        do { _ = try await client.metadata(for: URL(string: "https://example.com")!); Issue.record("expected invalid policy") }
        catch { #expect((error as? SafeLinkError) == .invalidPolicy) }
    }
}
