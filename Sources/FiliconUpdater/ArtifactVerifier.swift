import CryptoKit
import Foundation

public enum SignaturePolicy: Sendable {
    case disabled
    case ifPresent(publicKey: Data)
    case required(publicKey: Data)
}

public enum ArtifactVerifier {
    public static func verify(file: URL, artifact: UpdateArtifact, signaturePolicy: SignaturePolicy) throws {
        guard artifact.sha256.count == 64, artifact.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.invalidDigest
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == artifact.size else {
            throw UpdateError.sizeMismatch(expected: artifact.size, actual: actualSize)
        }

        let digest = try sha256(file: file)
        guard digest == artifact.sha256.lowercased() else { throw UpdateError.checksumMismatch }

        switch signaturePolicy {
        case .disabled:
            return
        case let .ifPresent(publicKey):
            guard let encoded = artifact.ed25519Signature else { return }
            try verifySignature(file: file, encodedSignature: encoded, publicKey: publicKey)
        case let .required(publicKey):
            guard let encoded = artifact.ed25519Signature else { throw UpdateError.missingSignature }
            try verifySignature(file: file, encodedSignature: encoded, publicKey: publicKey)
        }
    }

    public static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifySignature(file: URL, encodedSignature: String, publicKey: Data) throws {
        guard let signature = Data(base64Encoded: encodedSignature) else { throw UpdateError.invalidSignature }
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey) }
        catch { throw UpdateError.invalidPublicKey }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: data) else { throw UpdateError.invalidSignature }
    }
}
