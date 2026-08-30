#!/usr/bin/env swift

import CryptoKit
import Foundation
import Security

let environment = ProcessInfo.processInfo.environment
let service = environment["FILICON_UPDATE_KEYCHAIN_SERVICE"] ?? "com.filicon.app.update-feed-signing-key"
let account = environment["FILICON_UPDATE_KEYCHAIN_ACCOUNT"] ?? "production"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

let lookup: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecMatchLimit as String: kSecMatchLimitOne
]

var existing: CFTypeRef?
let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &existing)
guard lookupStatus == errSecItemNotFound else {
    if lookupStatus == errSecSuccess {
        fail("Keychain item already exists for service \(service) / account \(account); refusing to overwrite")
    }
    fail("could not inspect Keychain item (OSStatus \(lookupStatus))")
}

let privateKey = Curve25519.Signing.PrivateKey()
let addQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecAttrLabel as String: "Filicon update-feed Ed25519 signing key",
    kSecValueData as String: privateKey.rawRepresentation
]

let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
guard addStatus == errSecSuccess else {
    fail("could not store update-feed signing key in Keychain (OSStatus \(addStatus))")
}

print("Stored a new Ed25519 update-feed signing key in macOS Keychain.")
print("service=\(service)")
print("account=\(account)")
print("publicKeyBase64=\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
print("privateKeyBase64=<stored in Keychain; not printed>")
