#if os(macOS)
import AppKit
import AuthenticationServices
import Foundation

/// The production provider deliberately constructs only security-key requests.
/// It never creates `ASAuthorizationPlatformPublicKeyCredentialProvider` requests.
public final class AuthenticationServicesHardwareSecurityKeyProvider: HardwareSecurityKeyProvider, @unchecked Sendable {
    private let state: AuthorizationState

    @MainActor public init() { state = AuthorizationState() }

    public func perform(
        _ ceremony: SecurityKeyCeremony,
        status: @escaping @Sendable (SecurityKeyStatus) async -> Void
    ) async throws -> SecurityKeyCredentialResponse {
        guard #available(macOS 14.4, *) else { throw SecurityKeyError.unsupported }
        try SecurityKeyValidation.validate(ceremony)
        await status(.waitingForPresence)
        // AuthenticationServices owns all authenticator PIN/UV UI. There is no public API
        // for an app to inject a PIN; this status tells the app to explain that boundary.
        if ceremony.userVerification != .discouraged { await status(.waitingForSystemPIN) }
        return try await state.perform(ceremony)
    }

    public func cancel() async { await state.cancel() }
}

@MainActor
private final class AuthorizationState: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<SecurityKeyCredentialResponse, Error>?

    @available(macOS 14.4, *)
    func perform(_ ceremony: SecurityKeyCeremony) async throws -> SecurityKeyCredentialResponse {
        guard controller == nil, continuation == nil else { throw SecurityKeyError.providerUnavailable }
        let request = try makeRequest(ceremony)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        controller?.cancel()
        finish(.failure(SecurityKeyError.cancelled))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let registration = authorization.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration,
           let attestation = registration.rawAttestationObject {
            finish(.success(.registration(
                id: registration.credentialID,
                clientDataJSON: registration.rawClientDataJSON,
                attestationObject: attestation
            )))
            return
        }
        if let assertion = authorization.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion {
            finish(.success(.assertion(
                id: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature,
                userHandle: assertion.userID.isEmpty ? nil : assertion.userID
            )))
            return
        }
        finish(.failure(SecurityKeyError.invalidCredential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain,
           nsError.code == ASAuthorizationError.canceled.rawValue {
            finish(.failure(SecurityKeyError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    @available(macOS 14.4, *)
    private func makeRequest(_ ceremony: SecurityKeyCeremony) throws -> ASAuthorizationRequest {
        let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: ceremony.rpID)
        let clientData = ASPublicKeyCredentialClientData(challenge: ceremony.challenge, origin: ceremony.origin)
        switch ceremony.kind {
        case .create:
            guard let userID = ceremony.userID, let name = ceremony.userName, let displayName = ceremony.userDisplayName else {
                throw SecurityKeyError.invalidRequest
            }
            let request = provider.createCredentialRegistrationRequest(
                clientData: clientData, displayName: displayName, name: name, userID: userID
            )
            request.credentialParameters = ceremony.algorithms.map {
                ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
            }
            request.excludedCredentials = ceremony.credentialIDs.map(makeDescriptor)
            request.userVerificationPreference = makeUserVerification(ceremony.userVerification)
            request.attestationPreference = makeAttestation(ceremony.attestation)
            request.residentKeyPreference = makeResidentKey(ceremony.residentKey)
            return request
        case .get:
            let request = provider.createCredentialAssertionRequest(clientData: clientData)
            request.allowedCredentials = ceremony.credentialIDs.map(makeDescriptor)
            request.userVerificationPreference = makeUserVerification(ceremony.userVerification)
            return request
        }
    }

    private func makeDescriptor(_ value: SecurityKeyCredentialDescriptor) -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor {
        ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: value.id,
            transports: value.transports.compactMap { transport in
                switch transport.lowercased() {
                case "usb": .usb
                case "nfc": .nfc
                case "ble", "bluetooth": .bluetooth
                default: nil
                }
            }
        )
    }

    private func makeUserVerification(_ value: SecurityKeyUserVerification) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value {
        case .discouraged: .discouraged
        case .preferred: .preferred
        case .required: .required
        }
    }

    private func makeAttestation(_ value: SecurityKeyAttestation) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch value {
        case .none: .none
        case .indirect: .indirect
        case .direct: .direct
        case .enterprise: .enterprise
        }
    }

    private func makeResidentKey(_ value: SecurityKeyResidentKey) -> ASAuthorizationPublicKeyCredentialResidentKeyPreference {
        switch value {
        case .discouraged: .discouraged
        case .preferred: .preferred
        case .required: .required
        }
    }

    private func finish(_ result: Result<SecurityKeyCredentialResponse, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        controller = nil
        continuation?.resume(with: result)
    }
}
#endif
