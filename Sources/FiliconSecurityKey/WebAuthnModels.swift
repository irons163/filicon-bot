import Foundation

public enum SecurityKeyCeremonyKind: String, Codable, Sendable {
    case create, get
}

public enum SecurityKeyUserVerification: String, Codable, Sendable {
    case discouraged, preferred, required
}

public enum SecurityKeyAttestation: String, Codable, Sendable {
    case none, indirect, direct, enterprise
}

public enum SecurityKeyResidentKey: String, Codable, Sendable {
    case discouraged, preferred, required
}

public struct SecurityKeyCredentialDescriptor: Codable, Sendable, Equatable {
    public var id: Data
    public var transports: [String]

    public init(id: Data, transports: [String] = []) {
        self.id = id
        self.transports = transports
    }
}

/// Provider-neutral WebAuthn input. `origin` is intentionally separate from `rpID`:
/// the desktop must validate and display both before asking AuthenticationServices.
public struct SecurityKeyCeremony: Codable, Sendable, Equatable {
    public var kind: SecurityKeyCeremonyKind
    public var origin: String
    public var rpID: String
    public var challenge: Data
    public var userID: Data?
    public var userName: String?
    public var userDisplayName: String?
    public var credentialIDs: [SecurityKeyCredentialDescriptor]
    public var algorithms: [Int]
    public var userVerification: SecurityKeyUserVerification
    public var attestation: SecurityKeyAttestation
    public var residentKey: SecurityKeyResidentKey

    public init(
        kind: SecurityKeyCeremonyKind,
        origin: String,
        rpID: String,
        challenge: Data,
        userID: Data? = nil,
        userName: String? = nil,
        userDisplayName: String? = nil,
        credentialIDs: [SecurityKeyCredentialDescriptor] = [],
        algorithms: [Int] = [-7],
        userVerification: SecurityKeyUserVerification = .preferred,
        attestation: SecurityKeyAttestation = .none,
        residentKey: SecurityKeyResidentKey = .discouraged
    ) {
        self.kind = kind
        self.origin = origin
        self.rpID = rpID
        self.challenge = challenge
        self.userID = userID
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.credentialIDs = credentialIDs
        self.algorithms = algorithms
        self.userVerification = userVerification
        self.attestation = attestation
        self.residentKey = residentKey
    }
}

public enum SecurityKeyCredentialResponse: Codable, Sendable, Equatable {
    case registration(id: Data, clientDataJSON: Data, attestationObject: Data)
    case assertion(id: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?)

    private enum CodingKeys: String, CodingKey {
        case type, id, rawId, response
    }
    private enum ResponseKeys: String, CodingKey {
        case clientDataJSON, attestationObject, authenticatorData, signature, userHandle
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        try root.encode("public-key", forKey: .type)
        let credentialID: Data
        switch self {
        case .registration(let id, let clientDataJSON, let attestationObject):
            credentialID = id
            var response = root.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response)
            try response.encode(clientDataJSON.base64URLEncodedString(), forKey: .clientDataJSON)
            try response.encode(attestationObject.base64URLEncodedString(), forKey: .attestationObject)
        case .assertion(let id, let clientDataJSON, let authenticatorData, let signature, let userHandle):
            credentialID = id
            var response = root.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response)
            try response.encode(clientDataJSON.base64URLEncodedString(), forKey: .clientDataJSON)
            try response.encode(authenticatorData.base64URLEncodedString(), forKey: .authenticatorData)
            try response.encode(signature.base64URLEncodedString(), forKey: .signature)
            if let userHandle { try response.encode(userHandle.base64URLEncodedString(), forKey: .userHandle) }
        }
        let encodedID = credentialID.base64URLEncodedString()
        try root.encode(encodedID, forKey: .id)
        try root.encode(encodedID, forKey: .rawId)
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        guard try root.decode(String.self, forKey: .type) == "public-key",
              let id = Data(base64URLEncoded: try root.decode(String.self, forKey: .rawId)) else {
            throw DecodingError.dataCorruptedError(forKey: .rawId, in: root, debugDescription: "Invalid public-key credential")
        }
        let response = try root.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response)
        guard let clientData = Data(base64URLEncoded: try response.decode(String.self, forKey: .clientDataJSON)) else {
            throw DecodingError.dataCorruptedError(forKey: .clientDataJSON, in: response, debugDescription: "Invalid clientDataJSON")
        }
        if let encoded = try response.decodeIfPresent(String.self, forKey: .attestationObject) {
            guard let attestation = Data(base64URLEncoded: encoded) else {
                throw DecodingError.dataCorruptedError(forKey: .attestationObject, in: response, debugDescription: "Invalid attestation")
            }
            self = .registration(id: id, clientDataJSON: clientData, attestationObject: attestation)
        } else {
            guard let authenticator = Data(base64URLEncoded: try response.decode(String.self, forKey: .authenticatorData)),
                  let signature = Data(base64URLEncoded: try response.decode(String.self, forKey: .signature)) else {
                throw DecodingError.dataCorruptedError(forKey: .authenticatorData, in: response, debugDescription: "Invalid assertion")
            }
            let handle = try response.decodeIfPresent(String.self, forKey: .userHandle).flatMap(Data.init(base64URLEncoded:))
            self = .assertion(id: id, clientDataJSON: clientData, authenticatorData: authenticator, signature: signature, userHandle: handle)
        }
    }
}

public struct SecurityKeyConsent: Sendable, Equatable {
    public let requestID: String
    public let origin: String
    public let rpID: String
    public let generation: UInt64

    public init(requestID: String, origin: String, rpID: String, generation: UInt64) {
        self.requestID = requestID
        self.origin = origin
        self.rpID = rpID
        self.generation = generation
    }
}

public enum SecurityKeyStatus: Sendable, Equatable {
    case disabled
    case disconnected
    case reconnecting(attempt: Int)
    case connected
    case awaitingConsent(origin: String, rpID: String)
    case waitingForSystemPIN
    case waitingForPresence
    case completed
    case failed(String)
}

public enum SecurityKeyError: Error, LocalizedError, Sendable, Equatable {
    case disabled, unsupported, invalidRequest, invalidOrigin, invalidRPID
    case requestTooLarge(limit: Int), challengeOutOfBounds
    case consentDeclined, cancelled, deadlineExceeded, staleGeneration, replay
    case providerUnavailable, backendUnavailable, invalidCredential

    public var errorDescription: String? {
        switch self {
        case .disabled: "Hardware security keys are disabled."
        case .unsupported: "Hardware security keys are unavailable on this Mac."
        case .invalidRequest: "The remote computer sent an invalid security-key request."
        case .invalidOrigin: "The WebAuthn origin is invalid or is not HTTPS."
        case .invalidRPID: "The relying-party ID is not valid for the requesting origin."
        case .requestTooLarge(let limit): "The security-key request exceeds \(limit) bytes."
        case .challengeOutOfBounds: "The WebAuthn challenge has an unsafe size."
        case .consentDeclined: "The security-key request was declined on this Mac."
        case .cancelled: "The security-key request was cancelled."
        case .deadlineExceeded: "The security-key request timed out."
        case .staleGeneration: "A stale security-key response was discarded."
        case .replay: "A replayed security-key request was rejected."
        case .providerUnavailable: "No hardware security-key provider is available."
        case .backendUnavailable: "The remote security-key service is unavailable."
        case .invalidCredential: "AuthenticationServices returned an invalid credential."
        }
    }
}

public enum SecurityKeyValidation {
    public static let maximumRequestBytes = 128 * 1024
    public static let challengeRange = 16...1024
    public static let maximumCredentialCount = 64
    public static let maximumCredentialIDBytes = 1024

    public static func validate(_ ceremony: SecurityKeyCeremony, encodedBytes: Int? = nil) throws {
        if let encodedBytes, encodedBytes > maximumRequestBytes { throw SecurityKeyError.requestTooLarge(limit: maximumRequestBytes) }
        guard challengeRange.contains(ceremony.challenge.count) else { throw SecurityKeyError.challengeOutOfBounds }
        guard ceremony.origin.utf8.count <= 2_048, ceremony.rpID.utf8.count <= 253 else { throw SecurityKeyError.invalidRequest }
        guard let components = URLComponents(string: ceremony.origin), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw SecurityKeyError.invalidOrigin }
        let rpID = ceremony.rpID.lowercased()
        guard isValidDNSName(rpID), host == rpID || host.hasSuffix("." + rpID) else { throw SecurityKeyError.invalidRPID }
        guard ceremony.credentialIDs.count <= maximumCredentialCount,
              ceremony.credentialIDs.allSatisfy({ !$0.id.isEmpty && $0.id.count <= maximumCredentialIDBytes }) else { throw SecurityKeyError.invalidRequest }
        guard !ceremony.algorithms.isEmpty, ceremony.algorithms.count <= 16 else { throw SecurityKeyError.invalidRequest }
        switch ceremony.kind {
        case .create:
            guard let userID = ceremony.userID, (1...1024).contains(userID.count),
                  let userName = ceremony.userName, !userName.isEmpty, userName.utf8.count <= 256,
                  let display = ceremony.userDisplayName, !display.isEmpty, display.utf8.count <= 256 else { throw SecurityKeyError.invalidRequest }
        case .get:
            guard ceremony.userID == nil else { throw SecurityKeyError.invalidRequest }
        }
    }

    private static func isValidDNSName(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else { return false }
        return value.split(separator: ".").allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            }
        }
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    fileprivate init?(base64URLEncoded value: String) {
        guard value.utf8.count <= SecurityKeyValidation.maximumRequestBytes * 2,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}
