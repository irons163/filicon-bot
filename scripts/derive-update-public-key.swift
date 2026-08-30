#!/usr/bin/env swift
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let privateKeyData = Data(base64Encoded: CommandLine.arguments[1]),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
    FileHandle.standardError.write(Data("invalid Ed25519 private key\n".utf8))
    exit(2)
}
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
