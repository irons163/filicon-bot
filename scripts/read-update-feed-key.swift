#!/usr/bin/env swift

import Foundation
import Security

let environment = ProcessInfo.processInfo.environment
let service = environment["FILICON_UPDATE_KEYCHAIN_SERVICE"] ?? "com.filicon.app.update-feed-signing-key"
let account = environment["FILICON_UPDATE_KEYCHAIN_ACCOUNT"] ?? "production"

guard CommandLine.arguments.dropFirst().first == "--for-release" else {
    FileHandle.standardError.write(Data("refusing to print a Keychain secret; pass --for-release only from a release process\n".utf8))
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]

var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess else {
    fail("update-feed signing key is unavailable in Keychain (OSStatus \(status))")
}
guard let rawKey = result as? Data, rawKey.count == 32 else {
    fail("update-feed signing key in Keychain is not a 32-byte Ed25519 key")
}

// This command is intended to be captured by release-macos.sh. Never log its
// stdout in CI output or paste it into source control.
FileHandle.standardOutput.write(Data(rawKey.base64EncodedString().utf8))
