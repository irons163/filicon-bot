import CustomDump
import Foundation
import Testing
import FiliconAppServices
import FiliconChannels

@Suite("Secret request metadata and host destination")
struct AgentSecretRequestTests {
    private let agent = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let requestData = Data(#"{"label":"Slack bot token","connector":"slack","field":"token"}"#.utf8)

    private func connection() -> ChannelConnection {
        .init(id: connectionID, connectorID: "slack", displayName: "Design workspace",
            secretReference: "keychain://channels/\(connectionID.uuidString)", agentID: agent,
            authKind: .botToken, accountID: "account-A")
    }

    @Test func canonicalMetadataContainsNoCredentialOrDestination() throws {
        let object = ["label": "  Slack\n  bot\t token  ", "description": "\nHelp\nwith setup\n",
                      "connector": " slack ", "field": " token "]
        let request = try AgentSecretRequest.parse(JSONEncoder().encode(object))
        expectNoDifference(request.label, "Slack bot token")
        expectNoDifference(request.description, "Help\nwith setup")
        expectNoDifference(request.connector, "slack")
        expectNoDifference(request.field, "token")
        let encoded = try JSONEncoder().encode(request)
        expectNoDifference(try JSONDecoder().decode([String: String].self, from: encoded),
            ["label": "Slack bot token", "description": "Help\nwith setup", "connector": "slack", "field": "token"])
        expectNoDifference(try AgentSecretRequest.parse(encoded), request)
    }

    @Test func referenceDisplayBoundsAreAppliedWithoutSplittingCharacters() throws {
        let request = try AgentSecretRequest.parse(JSONEncoder().encode([
            "label": String(repeating: "設", count: 121), "description": String(repeating: "🧑‍💻", count: 401),
            "connector": "discord", "field": "token"]))
        expectNoDifference(request.label, String(repeating: "設", count: 120))
        expectNoDifference(request.description, String(repeating: "🧑‍💻", count: 400))
    }

    @Test(arguments: ["value", "token", "password", "accountID", "agentID", "connectionID", "secretReference", "path", "url"])
    func modelCannotSupplyCredentialValuesOrStorageTargets(key: String) throws {
        var object = ["label": "Token", "connector": "slack", "field": "token"]
        object[key] = "fixture-sensitive-sentinel"
        #expect(throws: AgentSecretRequestError.invalid) {
            try AgentSecretRequest.parse(JSONEncoder().encode(object))
        }
    }

    @Test(arguments: [
        #"{}"#, #"[]"#, #"{"label":" ","connector":"slack","field":"token"}"#,
        #"{"label":"Token","description":null,"connector":"slack","field":"token"}"#,
        #"{"label":"Token","connector":"../slack","field":"token"}"#,
        #"{"label":"Token","connector":"slack","field":"token/path"}"#,
        #"{"label":"Token\u202e","connector":"slack","field":"token"}"#,
        #"{"label":"Token","description":"x\u0000","connector":"slack","field":"token"}"#,
        #"{"label":true,"connector":"slack","field":"token"}"#,
        #"{"label":"Token","connector":"https://slack.com","field":"token"}"#
    ])
    func malformedMetadataIsRejectedWithoutEchoingInput(json: String) {
        #expect(throws: AgentSecretRequestError.invalid) { try AgentSecretRequest.parse(Data(json.utf8)) }
    }

    @Test func oversizedMetadataIsRejected() {
        #expect(throws: AgentSecretRequestError.invalid) {
            try AgentSecretRequest.parse(Data(repeating: 32, count: 16_385))
        }
    }

    @Test func destinationComesOnlyFromMatchingHostConnection() throws {
        let request = try AgentSecretRequest.parse(requestData)
        let target = try AgentSecretRequestDestination.resolve(request, accountID: "account-A", agentID: agent,
            conversationID: scope, connections: [connection()])
        expectNoDifference(target.connectionID, connectionID)
        expectNoDifference(target.displayName, "Design workspace")
        try target.validate(accountID: "account-A", agentID: agent, conversationID: scope, connections: [connection()])
        var polled = connection()
        expectDifference(polled) {
            polled.cursor = "next-page"
            polled.lastActivityAt = Date(timeIntervalSince1970: 100)
        } changes: {
            $0.cursor = "next-page"
            $0.lastActivityAt = Date(timeIntervalSince1970: 100)
        }
        try target.validate(accountID: "account-A", agentID: agent, conversationID: scope, connections: [polled])
        #expect(throws: AgentSecretRequestError.unavailable) {
            try AgentSecretRequestDestination.resolve(request, accountID: "account-B", agentID: agent,
                conversationID: scope, connections: [connection()])
        }
        #expect(throws: AgentSecretRequestError.unavailable) {
            try AgentSecretRequestDestination.resolve(request, accountID: "account-A", agentID: other,
                conversationID: scope, connections: [connection()])
        }
        #expect(throws: AgentSecretRequestError.ambiguous) {
            try AgentSecretRequestDestination.resolve(request, accountID: "account-A", agentID: agent,
                conversationID: scope, connections: [connection(), connection()])
        }
    }

    @Test(arguments: ["account", "agent", "scope", "removed", "renamed", "disabled", "credential", "oauth"])
    func changedDestinationCannotRedirectSecret(mode: String) throws {
        let request = try AgentSecretRequest.parse(requestData)
        let target = try AgentSecretRequestDestination.resolve(request, accountID: "account-A", agentID: agent,
            conversationID: scope, connections: [connection()])
        var changed = connection()
        if mode == "renamed" { changed.displayName = "Changed" }
        if mode == "disabled" { changed.enabled = false }
        if mode == "credential" { changed.secretReference = "keychain://channels/\(other.uuidString)" }
        if mode == "oauth" { changed.authKind = .oauth }
        #expect(throws: AgentSecretRequestError.stale) {
            try target.validate(accountID: mode == "account" ? "account-B" : "account-A",
                agentID: mode == "agent" ? other : agent, conversationID: mode == "scope" ? other : scope,
                connections: mode == "removed" ? [] : [changed])
        }
    }

    @Test(arguments: ["file:///tmp/key", "keychain://channels/../other", "keychain://provider/openai", "keychain://channels/"])
    func invalidHostStorageReferenceIsRejected(reference: String) throws {
        var value = connection(); value.secretReference = reference
        #expect(throws: AgentSecretRequestError.unavailable) {
            try AgentSecretRequestDestination.resolve(AgentSecretRequest.parse(requestData), accountID: "account-A",
                agentID: agent, conversationID: scope, connections: [value])
        }
    }

    @Test(arguments: [("slack", "password"), ("github", "token"), ("discord", "refresh_token")])
    func unsupportedStorageIsNotAdvertisedAsARealDestination(connector: String, field: String) throws {
        let request = try AgentSecretRequest.parse(JSONEncoder().encode(["label": "Credential", "connector": connector, "field": field]))
        #expect(throws: AgentSecretRequestError.unsupported) {
            try AgentSecretRequestDestination.resolve(request, accountID: "account-A", agentID: agent,
                conversationID: scope, connections: [connection()])
        }
    }
}
