#if os(macOS)
import Foundation
import Testing
@testable import FiliconRichContent

private actor RecordingProcessRunner: SafeLinkProcessRunning {
    enum Action: Sendable { case result(SafeLinkProcessResult), error(SafeLinkError), suspend }
    private var actions: [Action]
    private var invocations: [SafeLinkProcessInvocation] = []
    init(_ actions: [Action]) { self.actions = actions }

    func run(_ invocation: SafeLinkProcessInvocation) async throws -> SafeLinkProcessResult {
        invocations.append(invocation)
        guard !actions.isEmpty else { throw SafeLinkError.transportFailure }
        switch actions.removeFirst() {
        case .result(let result): return result
        case .error(let error): throw error
        case .suspend:
            try await Task.sleep(for: .seconds(60))
            throw SafeLinkError.transportFailure
        }
    }

    func recorded() -> [SafeLinkProcessInvocation] { invocations }
}

@Suite("Production safe link transport")
struct ProductionSafeLinkTransportTests {
    let v4 = SafeLinkMetadataClient.parseIPAddress("8.8.8.8")!
    let v6 = SafeLinkMetadataClient.parseIPAddress("2606:4700:4700::1111")!

    private func result(body: String = "<title>ok</title>", status: Int = 200, peer: String = "8.8.8.8",
                        type: String = "text/html; charset=utf-8", redirect: String = "", size: Int? = nil,
                        headerSize: Int = 256, exit: Int32 = 0, prefix: String = "") -> SafeLinkProcessResult {
        let data = Data(body.utf8)
        let metadata = "\(prefix)FILICON_CURL_WRITE_OUT_V1:\(status)\n\(peer)\n\(type)\n\(redirect)\n\(size ?? data.count)\n\(headerSize)"
        return .init(standardOutput: data, standardError: Data(metadata.utf8), terminationStatus: exit)
    }

    private func request(addresses: [ResolvedAddress]? = nil, maximum: Int = 1024) -> SafeLinkRequest {
        .init(url: URL(string: "https://example.com/path?q=1")!, approvedAddresses: addresses ?? [v4], maximumBodyBytes: maximum)
    }

    @Test func pinsEveryAttemptAndStripsProxyCredentialEnvironment() async throws {
        let runner = RecordingProcessRunner([.result(result())])
        let response = try await CurlSafeLinkTransport(runner: runner).send(request())
        #expect(response.connectedAddress == v4)
        let invocation = try #require(await runner.recorded().first)
        #expect(invocation.executableURL.path == "/usr/bin/curl")
        #expect(invocation.arguments.first == "--disable")
        #expect(invocation.arguments.contains("example.com:443:8.8.8.8"))
        #expect(invocation.arguments.contains("::8.8.8.8:443"))
        #expect(invocation.arguments.contains("--max-redirs"))
        #expect(invocation.arguments.contains("--noproxy"))
        #expect(invocation.arguments.suffix(2) == ["--", "https://example.com/path?q=1"])
        #expect(invocation.environment == ["LC_ALL": "C"])
        #expect(invocation.environment["HTTPS_PROXY"] == nil)
        #expect(!invocation.arguments.contains("--location"))
        #expect(!invocation.arguments.contains("--user"))
    }

    @Test func ipv6PinUsesCurlBracketForm() async throws {
        let runner = RecordingProcessRunner([.result(result(peer: "2606:4700:4700::1111"))])
        _ = try await CurlSafeLinkTransport(runner: runner).send(request(addresses: [v6]))
        #expect(await runner.recorded().first?.arguments.contains("example.com:443:[2606:4700:4700::1111]") == true)
        #expect(await runner.recorded().first?.arguments.contains("::[2606:4700:4700::1111]:443") == true)
    }

    @Test func redirectIsReturnedWithoutFollowingForClientRevalidation() async throws {
        let second = SafeLinkMetadataClient.parseIPAddress("1.1.1.1")!
        let resolver = ProductionFixtureResolver(values: ["example.com": [v4], "other.example": [second]])
        let runner = RecordingProcessRunner([
            .result(result(body: "", status: 302, redirect: "https://other.example/final")),
            .result(result(peer: "1.1.1.1")),
        ])
        let client = SafeLinkMetadataClient(resolver: resolver, transport: CurlSafeLinkTransport(runner: runner))
        let metadata = try await client.metadata(for: URL(string: "https://example.com/start")!)
        #expect(metadata.url == URL(string: "https://other.example/final")!)
        let calls = await runner.recorded()
        #expect(calls.count == 2)
        #expect(calls[0].arguments.contains("example.com:443:8.8.8.8"))
        #expect(calls[1].arguments.contains("other.example:443:1.1.1.1"))
    }

    @Test func credentialAndLocalRedirectsNeverReachASecondProcess() async {
        for (target, expected) in [("https://user:pass@other.example/", SafeLinkError.invalidURL),
                                   ("https://localhost/private", SafeLinkError.forbiddenHost)] {
            let runner = RecordingProcessRunner([.result(result(body: "", status: 302, redirect: target))])
            let client = SafeLinkMetadataClient(
                resolver: ProductionFixtureResolver(values: ["example.com": [v4]]),
                transport: CurlSafeLinkTransport(runner: runner)
            )
            do { _ = try await client.metadata(for: URL(string: "https://example.com/start")!); Issue.record("expected redirect rejection") }
            catch { #expect((error as? SafeLinkError) == expected) }
            #expect(await runner.recorded().count == 1)
        }
    }

    @Test func rejectsOversizeBeforeReturningBody() async {
        let runner = RecordingProcessRunner([.result(result(body: "1234", size: 2048, exit: 63))])
        do { _ = try await CurlSafeLinkTransport(runner: runner).send(request(maximum: 16)); Issue.record("expected oversize") }
        catch { #expect((error as? SafeLinkError) == .responseTooLarge) }

        var policy = CurlSafeLinkTransportPolicy(); policy.maximumHeaderBytes = 16
        let headers = RecordingProcessRunner([.result(result(headerSize: 17))])
        do { _ = try await CurlSafeLinkTransport(runner: headers, policy: policy).send(request()); Issue.record("expected header oversize") }
        catch { #expect((error as? SafeLinkError) == .responseTooLarge) }
    }

    @Test func timeoutAndCancellationRemainDistinguishable() async {
        let timeoutRunner = RecordingProcessRunner([.error(.timeout)])
        do { _ = try await CurlSafeLinkTransport(runner: timeoutRunner).send(request()); Issue.record("expected timeout") }
        catch { #expect((error as? SafeLinkError) == .timeout) }

        let cancellationRunner = RecordingProcessRunner([.suspend])
        let task = Task { try await CurlSafeLinkTransport(runner: cancellationRunner).send(request()) }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") }
        catch { #expect((error as? SafeLinkError) == .cancelled) }

        let curlDeadline = RecordingProcessRunner([.result(result(exit: 28))])
        do { _ = try await CurlSafeLinkTransport(runner: curlDeadline).send(request()); Issue.record("expected curl timeout") }
        catch { #expect((error as? SafeLinkError) == .timeout) }
    }

    @Test func directTransportUseStillRejectsPrivatePinsAndUnsafeConfiguration() async {
        let runner = RecordingProcessRunner([.result(result())])
        let privateAddress = SafeLinkMetadataClient.parseIPAddress("127.0.0.1")!
        do { _ = try await CurlSafeLinkTransport(runner: runner).send(request(addresses: [privateAddress])); Issue.record("expected private pin rejection") }
        catch { #expect((error as? SafeLinkError) == .invalidPolicy) }
        #expect(await runner.recorded().isEmpty)

        var policy = CurlSafeLinkTransportPolicy(); policy.userAgent = "safe\r\nX-Injected: yes"
        do { _ = try await CurlSafeLinkTransport(runner: runner, policy: policy).send(request()); Issue.record("expected header injection rejection") }
        catch { #expect((error as? SafeLinkError) == .invalidPolicy) }
        #expect(await runner.recorded().isEmpty)
    }

    @Test func rejectsPeerMismatchAndMalformedWriteOut() async {
        let mismatch = RecordingProcessRunner([.result(result(peer: "1.1.1.1"))])
        do { _ = try await CurlSafeLinkTransport(runner: mismatch).send(request()); Issue.record("expected mismatch") }
        catch { #expect((error as? SafeLinkError) == .connectedAddressMismatch) }

        let clientMismatch = RecordingProcessRunner([.result(result(peer: "1.1.1.1"))])
        let client = SafeLinkMetadataClient(resolver: ProductionFixtureResolver(values: ["example.com": [v4]]),
                                            transport: CurlSafeLinkTransport(runner: clientMismatch))
        do { _ = try await client.metadata(for: request().url); Issue.record("expected client mismatch") }
        catch { #expect((error as? SafeLinkError) == .connectedAddressMismatch) }
        #expect(await clientMismatch.recorded().count == 1)

        for bytes in [Data(), Data("FILICON_CURL_WRITE_OUT_V1:not-a-status".utf8), Data("FILICON_CURL_WRITE_OUT_V1:200\n8.8.8.8\ntext/html\n\n1\nextra".utf8)] {
            let runner = RecordingProcessRunner([.result(.init(standardOutput: Data("x".utf8), standardError: bytes, terminationStatus: 0))])
            do { _ = try await CurlSafeLinkTransport(runner: runner).send(request()); Issue.record("expected malformed output") }
            catch { #expect((error as? SafeLinkError) == .malformedResponse) }
        }
    }

    @Test func foundationRunnerEnforcesPipeLimitDeadlineAndCancellation() async {
        let processRunner = FoundationSafeLinkProcessRunner()
        let outputInvocation = SafeLinkProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["12345"], environment: ["LC_ALL": "C"],
            maximumStandardOutputBytes: 4, maximumStandardErrorBytes: 128, timeout: .seconds(1)
        )
        do { _ = try await processRunner.run(outputInvocation); Issue.record("expected pipe bound") }
        catch { #expect((error as? SafeLinkError) == .responseTooLarge) }

        let sleepInvocation = SafeLinkProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: ["LC_ALL": "C"],
            maximumStandardOutputBytes: 16, maximumStandardErrorBytes: 16, timeout: .milliseconds(10)
        )
        do { _ = try await processRunner.run(sleepInvocation); Issue.record("expected process deadline") }
        catch { #expect((error as? SafeLinkError) == .timeout) }

        let cancellationInvocation = SafeLinkProcessInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: ["LC_ALL": "C"],
            maximumStandardOutputBytes: 16, maximumStandardErrorBytes: 16, timeout: .seconds(2)
        )
        let task = Task { try await processRunner.run(cancellationInvocation) }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do { _ = try await task.value; Issue.record("expected process cancellation") }
        catch { #expect((error as? SafeLinkError) == .cancelled) }
    }
}

private struct ProductionFixtureResolver: SafeLinkResolving {
    let values: [String: [ResolvedAddress]]
    func resolve(host: String) async throws -> [ResolvedAddress] { values[host] ?? [] }
}
#endif
