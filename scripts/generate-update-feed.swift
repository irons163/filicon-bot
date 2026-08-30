#!/usr/bin/env swift

import CryptoKit
import Foundation

struct Artifact: Encodable {
    let url: URL
    let format: String
    let sha256: String
    let size: Int64
    let ed25519Signature: String?
}

struct Release: Encodable {
    let version: String
    let build: Int
    let publishedAt: Date
    let minimumSystemVersion: String
    let notesURL: URL?
    let artifact: Artifact
}

struct Feed: Encodable {
    let schemaVersion = 1
    let channel: String
    let releases: [Release]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 7 else {
    fail("usage: generate-update-feed.swift <channel> <version> <build> <minimum-macOS> <base-https-url> <artifact> <output>")
}
let channel = args[0]
guard ["stable", "nightly", "dogfood"].contains(channel),
      let build = Int(args[2]), build > 0,
      args[1].range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil,
      args[3].range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
      let baseURL = URL(string: args[4]), baseURL.scheme?.lowercased() == "https",
      baseURL.host?.isEmpty == false, baseURL.user == nil, baseURL.password == nil,
      baseURL.query == nil, baseURL.fragment == nil else {
    fail("invalid channel, build, or HTTPS base URL")
}
let artifactURL = URL(fileURLWithPath: args[5])
let outputURL = URL(fileURLWithPath: args[6])
guard FileManager.default.fileExists(atPath: artifactURL.path) else { fail("artifact does not exist") }
let data = try Data(contentsOf: artifactURL, options: .mappedIfSafe)
let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
let signature: String?
if let encodedKey = ProcessInfo.processInfo.environment["FILICON_UPDATE_PRIVATE_KEY_BASE64"],
   let rawKey = Data(base64Encoded: encodedKey) {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    signature = try key.signature(for: data).base64EncodedString()
} else {
    signature = nil
}
let remoteArtifact = baseURL.appendingPathComponent(artifactURL.lastPathComponent)
let notesURL: URL?
if let rawNotes = ProcessInfo.processInfo.environment["RELEASE_NOTES_URL"], !rawNotes.isEmpty {
    guard let value = URL(string: rawNotes), value.scheme?.lowercased() == "https",
          value.host?.isEmpty == false, value.user == nil, value.password == nil else {
        fail("RELEASE_NOTES_URL must be a credential-free HTTPS URL")
    }
    notesURL = value
} else {
    notesURL = nil
}
let release = Release(
    version: args[1],
    build: build,
    publishedAt: Date(),
    minimumSystemVersion: args[3],
    notesURL: notesURL,
    artifact: Artifact(
        url: remoteArtifact,
        format: artifactURL.pathExtension.lowercased() == "dmg" ? "dmg" : "app-zip",
        sha256: digest,
        size: Int64(data.count),
        ed25519Signature: signature
    )
)
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(Feed(channel: channel, releases: [release])).write(to: outputURL, options: .atomic)
print("Created \(outputURL.path)")
