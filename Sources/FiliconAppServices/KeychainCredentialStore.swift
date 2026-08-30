import Foundation
import Security
import FiliconDomain
import FiliconProviderKit

public struct CredentialRef: Hashable, Sendable {
    public let providerID: ProviderID
    public let account: String
    public init(providerID: ProviderID, account: String = "default") { self.providerID = providerID; self.account = account }
}

public enum CredentialStoreError: LocalizedError, Sendable {
    case osStatus(OSStatus)
    public var errorDescription: String? {
        switch self { case .osStatus(let status): "Keychain error \(status)." }
    }
}

public actor KeychainCredentialStore {
    private let service: String
    public init(service: String = "com.filicon.app.provider") { self.service = service }

    public func set(_ secret: String, for ref: CredentialRef) throws {
        let account = key(ref)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialStoreError.osStatus(updateStatus) }
        var add = base
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.osStatus(status) }
    }

    public func value(for ref: CredentialRef) throws -> String {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key(ref)]
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ProviderError.missingCredential(ref.providerID) }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw CredentialStoreError.osStatus(status) }
        return secret
    }

    public func contains(_ ref: CredentialRef) -> Bool { (try? value(for: ref)) != nil }
    public func remove(_ ref: CredentialRef) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key(ref)] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.osStatus(status) }
    }
    private func key(_ ref: CredentialRef) -> String { "\(ref.providerID.rawValue):\(ref.account)" }
}
