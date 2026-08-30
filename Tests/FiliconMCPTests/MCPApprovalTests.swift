import Foundation
import Testing
@testable import FiliconMCP

private final class ApprovalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_000)) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}

private func descriptor(_ annotations: MCPToolAnnotations?) -> MCPToolDescriptor {
    .init(serverIdentifier: "mail-work", name: "send", description: nil, inputSchema: .object([:]), annotations: annotations)
}

private func request(from preparation: MCPDispatchPreparation) throws -> MCPApprovalRequest {
    guard case .approvalRequired(let request) = preparation else {
        throw MCPAuthorizationError.denied
    }
    return request
}

private func receipt(from preparation: MCPDispatchPreparation) throws -> MCPAuthorizationReceipt {
    guard case .authorized(let receipt) = preparation else {
        throw MCPAuthorizationError.denied
    }
    return receipt
}

private actor ApprovalDispatchConnection: MCPConnection {
    private(set) var calls = 0
    func connect() async throws {}
    func listTools() async throws -> [MCPToolDescriptor] {
        [descriptor(.init(readOnlyHint: false, destructiveHint: false, openWorldHint: true))]
    }
    func callTool(name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        calls += 1
        return .init(content: [.init(type: "text", text: "ok")])
    }
    func listResources() async throws -> [MCPResourceDescriptor] { [] }
    func readResource(uri: String) async throws -> MCPResourceResult { .init(contents: []) }
    func close() async {}
}

private struct ApprovalDispatchFactory: MCPConnectionFactory {
    let connection: ApprovalDispatchConnection
    func connection(for config: MCPServerConfig) async throws -> any MCPConnection { connection }
}

@Suite("MCP annotation and approval policy")
struct MCPApprovalTests {
    @Test func legacyDescriptorDecodeAndAnnotationDefaultsAreBackwardCompatible() throws {
        let legacy = Data(#"{"serverIdentifier":"legacy","name":"read","description":null,"inputSchema":{"type":"object"}}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPToolDescriptor.self, from: legacy)
        #expect(decoded.annotations == nil)
        #expect(MCPToolRiskAssessment(descriptor: decoded).risk == .destructive)

        let raw = MCPJSONValue.object([
            "title": .string(String(repeating: "x", count: 400)),
            "readOnlyHint": .bool(true),
        ])
        let annotations = MCPToolAnnotations(rawValue: raw)
        #expect(annotations.title?.count == 256)
        #expect(annotations.readOnlyHint)
        #expect(annotations.destructiveHint) // MCP default
        #expect(!annotations.idempotentHint) // MCP default
        #expect(annotations.openWorldHint) // MCP default
        #expect(MCPToolRiskAssessment(descriptor: descriptor(annotations)).risk == .openWorldRead)
    }

    @Test func malformedUnknownAndContradictoryAnnotationsFailClosed() throws {
        let unknown = MCPToolAnnotations(rawValue: .object([
            "readOnlyHint": .bool(true), "destructiveHint": .bool(false),
            "openWorldHint": .bool(false), "vendorPrivilege": .string("trusted"),
        ]))
        #expect(MCPToolRiskAssessment(descriptor: descriptor(unknown)).risk == .unknown)

        let malformed = MCPToolAnnotations(rawValue: .object([
            "readOnlyHint": .string("true"), "destructiveHint": .bool(false), "openWorldHint": .bool(false),
        ]))
        #expect(MCPToolRiskAssessment(descriptor: descriptor(malformed)).risk == .unknown)

        let contradictory = MCPToolAnnotations(readOnlyHint: true, destructiveHint: true, openWorldHint: false)
        #expect(MCPToolRiskAssessment(descriptor: descriptor(contradictory)).risk == .unknown)

        let roundTripped = try JSONDecoder().decode(MCPToolDescriptor.self, from: JSONEncoder().encode(descriptor(unknown)))
        #expect(MCPToolRiskAssessment(descriptor: roundTripped).risk == .unknown)
    }

    @Test func safeAnnotationCannotOverrideUserManagedOrAutoReviewPolicy() async throws {
        let coordinator = MCPAuthorizationCoordinator()
        let target = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: .object([:]))
        let safe = descriptor(.init(readOnlyHint: true, destructiveHint: false, openWorldHint: false))

        let managedDeny = await coordinator.prepare(target: target, descriptor: safe, policy: .init(userMode: .always, managedCeiling: .never), autoReview: .allow)
        guard case .denied = managedDeny else { Issue.record("Managed deny must win"); return }

        let userDeny = await coordinator.prepare(target: target, descriptor: safe, policy: .init(userMode: .never, managedCeiling: .always), autoReview: .allow)
        guard case .denied = userDeny else { Issue.record("User deny must win"); return }

        let openWorld = descriptor(.init(readOnlyHint: true, destructiveHint: false, openWorldHint: true))
        let reviewAllow = await coordinator.prepare(target: target, descriptor: openWorld, policy: .init(userMode: .always), autoReview: .allow)
        guard case .approvalRequired = reviewAllow else { Issue.record("Auto-review cannot upgrade open-world risk"); return }
    }

    @Test func allowOnceReceiptIsExactSingleUseAndGenerationFenced() async throws {
        let coordinator = MCPAuthorizationCoordinator()
        let arguments: MCPJSONValue = .object(["to": .string("a@example.com")])
        #expect(MCPCallTarget.hash(arguments) == MCPCallTarget.hash(.object(["to": .string("a@example.com")])))
        #expect(MCPCallTarget.hash(.object(["a": .number(1), "b": .number(2)])) == MCPCallTarget.hash(.object(["b": .number(2), "a": .number(1)])))
        let target = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: arguments)
        let risky = descriptor(.init(readOnlyHint: false, destructiveHint: false, openWorldHint: true))
        let pending = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        let approved = try #require(await coordinator.resolve(requestID: pending.id, resolution: .allowOnce, policy: .init()))
        try await coordinator.consume(approved, for: target)
        await #expect(throws: MCPAuthorizationError.receiptAlreadyUsed) {
            try await coordinator.consume(approved, for: target)
        }

        let secondTarget = MCPCallTarget(serverIdentifier: target.serverIdentifier, accountIdentifier: "personal", conversationIdentifier: target.conversationIdentifier, toolName: target.toolName, arguments: arguments, generation: target.generation)
        let pending2 = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        let approved2 = try #require(await coordinator.resolve(requestID: pending2.id, resolution: .allowOnce, policy: .init()))
        await #expect(throws: MCPAuthorizationError.targetMismatch) {
            try await coordinator.consume(approved2, for: secondTarget)
        }

        await coordinator.advanceGeneration(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1")
        await #expect(throws: MCPAuthorizationError.staleGeneration) {
            try await coordinator.consume(approved2, for: target)
        }
    }

    @Test func receiptAndRequestExpireAfterTenMinutesAndCancellationCannotReplay() async throws {
        let clock = ApprovalTestClock()
        let coordinator = MCPAuthorizationCoordinator(now: clock.now)
        let target = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: .object([:]))
        let risky = descriptor(nil)
        let expiringRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        clock.advance(601)
        await #expect(throws: MCPAuthorizationError.requestExpired) {
            _ = try await coordinator.resolve(requestID: expiringRequest.id, resolution: .allowOnce, policy: .init())
        }

        let freshRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        await coordinator.cancel(requestID: freshRequest.id)
        await #expect(throws: MCPAuthorizationError.requestCancelled) {
            _ = try await coordinator.resolve(requestID: freshRequest.id, resolution: .allowOnce, policy: .init())
        }

        let receiptRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        let expiringReceipt = try #require(await coordinator.resolve(requestID: receiptRequest.id, resolution: .allowOnce, policy: .init()))
        clock.advance(601)
        await #expect(throws: MCPAuthorizationError.receiptExpired) {
            try await coordinator.consume(expiringReceipt, for: target)
        }
    }

    @Test func alwaysGrantIsScopedAndManagedCeilingOnlyShrinksIt() async throws {
        let coordinator = MCPAuthorizationCoordinator()
        let risky = descriptor(.init(readOnlyHint: false, destructiveHint: false, openWorldHint: true))
        let first = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: .object(["to": .string("a")]))
        let initialRequest = try request(from: await coordinator.prepare(target: first, descriptor: risky, policy: .init()))
        _ = try await coordinator.resolve(requestID: initialRequest.id, resolution: .allowAlways(scope: .exactArguments), policy: .init(managedCeiling: .always))

        _ = try receipt(from: await coordinator.prepare(target: first, descriptor: risky, policy: .init()))
        let changedArguments = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: .object(["to": .string("b")]))
        guard case .approvalRequired = await coordinator.prepare(target: changedArguments, descriptor: risky, policy: .init()) else {
            Issue.record("Exact-arguments grant crossed its scope"); return
        }

        let managedRequest = try request(from: await coordinator.prepare(target: changedArguments, descriptor: risky, policy: .init(managedCeiling: .ask)))
        await #expect(throws: MCPAuthorizationError.persistentGrantExceedsManagedCeiling) {
            _ = try await coordinator.resolve(requestID: managedRequest.id, resolution: .allowAlways(scope: .tool), policy: .init(managedCeiling: .ask))
        }
    }

    @Test func unknownRiskCannotReceivePersistentGrant() async throws {
        let coordinator = MCPAuthorizationCoordinator()
        let target = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: .object([:]))
        let contradictory = descriptor(.init(readOnlyHint: true, destructiveHint: true, openWorldHint: false))
        let request = try request(from: await coordinator.prepare(target: target, descriptor: contradictory, policy: .init()))
        await #expect(throws: MCPAuthorizationError.unsafePersistentGrant) {
            _ = try await coordinator.resolve(requestID: request.id, resolution: .allowAlways(scope: .exactArguments), policy: .init())
        }
    }

    @Test func denialAndAuthorizedDispatcherEnforceExactArguments() async throws {
        let coordinator = MCPAuthorizationCoordinator()
        let arguments: MCPJSONValue = .object(["to": .string("a")])
        let target = await coordinator.makeTarget(serverIdentifier: "mail-work", accountIdentifier: "work", conversationIdentifier: "c1", toolName: "send", arguments: arguments)
        let risky = descriptor(.init(readOnlyHint: false, destructiveHint: false, openWorldHint: true))

        let deniedRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        await #expect(throws: MCPAuthorizationError.denied) {
            _ = try await coordinator.resolve(requestID: deniedRequest.id, resolution: .deny, policy: .init())
        }

        let approvedRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        let approvedReceipt = try #require(await coordinator.resolve(requestID: approvedRequest.id, resolution: .allowOnce, policy: .init()))
        let connection = ApprovalDispatchConnection()
        let service = MCPService(factory: ApprovalDispatchFactory(connection: connection))
        let config = try MCPServerConfig(
            identifier: "mail-work", displayName: "Mail",
            transport: .stdio(executable: "/usr/bin/false", arguments: [], environmentReferences: [:], workingDirectory: nil)
        )
        try await service.replaceConfigs([config])
        let dispatcher = MCPAuthorizedDispatcher(service: service, authorization: coordinator)
        await #expect(throws: MCPAuthorizationError.targetMismatch) {
            _ = try await dispatcher.dispatch(target: target, arguments: .object(["to": .string("b")]), receipt: approvedReceipt)
        }
        #expect(await connection.calls == 0)
        #expect(try await dispatcher.dispatch(target: target, arguments: arguments, receipt: approvedReceipt).content.first?.text == "ok")
        await #expect(throws: MCPAuthorizationError.receiptAlreadyUsed) {
            _ = try await dispatcher.dispatch(target: target, arguments: arguments, receipt: approvedReceipt)
        }
        #expect(await connection.calls == 1)

        let policyChangeRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        await #expect(throws: MCPAuthorizationError.denied) {
            _ = try await coordinator.resolve(requestID: policyChangeRequest.id, resolution: .allowOnce, policy: .init(managedCeiling: .never))
        }

        let issuedRequest = try request(from: await coordinator.prepare(target: target, descriptor: risky, policy: .init()))
        let issuedReceipt = try #require(await coordinator.resolve(requestID: issuedRequest.id, resolution: .allowOnce, policy: .init()))
        await #expect(throws: MCPAuthorizationError.denied) {
            try await coordinator.consume(issuedReceipt, for: target, policy: .init(managedCeiling: .never))
        }
    }
}
