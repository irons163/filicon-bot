import Foundation
import FiliconLocalTools
import Security

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientSignatureGate.accepts(connection) else { return false }
        let endpoint = ServiceEndpoint()
        connection.exportedInterface = NSXPCInterface(with: FiliconLocalToolXPCProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { _ = endpoint }
        connection.interruptionHandler = { _ = endpoint }
        connection.resume()
        return true
    }
}

private enum ClientSignatureGate {
    static func accepts(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), connection.processIdentifier > 1 else { return false }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest,
              let guestInfo = signingInformation(guest),
              guestInfo[kSecCodeInfoIdentifier as String] as? String == "com.filicon.app" else { return false }

        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              let ownInfo = signingInformation(own) else { return false }
        if let team = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return guestInfo[kSecCodeInfoTeamIdentifier as String] as? String == team
        }
        return true
    }

    private static func signingInformation(_ code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}

private final class ServiceEndpoint: NSObject, @unchecked Sendable, FiliconLocalToolXPCProtocol {
    private let lock = NSLock()
    private var host: LocalToolProcessHost?

    func establishSession(generation: String, sessionKey: Data, withReply reply: @escaping (Bool) -> Void) {
        guard let generation = UUID(uuidString: generation), sessionKey.count >= 32 else {
            reply(false)
            return
        }
        let authenticator = LocalSessionAuthenticator(sessionKey: sessionKey)
        lock.lock()
        host = LocalToolProcessHost(
            generation: generation,
            requiresSecurityScopedRoots: true,
            requiresPermissionReceipts: true,
            authenticate: { authenticator.verify($0) },
            verifyReceipt: { authenticator.verify($0) }
        )
        lock.unlock()
        reply(true)
    }

    func perform(request: Data, withReply reply: @escaping (Data) -> Void) {
        let host = currentHost()
        let replyBox = DataReplyBox(reply)
        Task.detached { [host, replyBox, request] in
            let response: LocalToolWireResponse
            do {
                guard let host else { throw LocalToolError.invalidRequest("session is not established") }
                let decoded = try Self.makeDecoder().decode(LocalToolWireRequest.self, from: request)
                response = await host.perform(decoded)
            } catch let error as LocalToolError {
                response = .init(requestID: Self.requestID(from: request), result: nil, error: error)
            } catch {
                response = .init(requestID: Self.requestID(from: request), result: nil, error: .invalidRequest(error.localizedDescription))
            }
            replyBox.call((try? Self.makeEncoder().encode(response)) ?? Data())
        }
    }

    func cancel(runID: String, generation: String, withReply reply: @escaping () -> Void) {
        let host = currentHost()
        let replyBox = VoidReplyBox(reply)
        Task.detached { [host, replyBox, runID, generation] in
            if let host, let runID = UUID(uuidString: runID), let generation = UUID(uuidString: generation) {
                await host.cancel(runID: runID, generation: generation)
            }
            replyBox.call()
        }
    }

    private func currentHost() -> LocalToolProcessHost? {
        lock.lock(); defer { lock.unlock() }
        return host
    }

    private static func requestID(from data: Data) -> UUID {
        (try? makeDecoder().decode(LocalToolWireRequest.self, from: data).scope.requestID) ?? UUID()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private final class DataReplyBox: @unchecked Sendable {
    private let reply: (Data) -> Void
    init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    func call(_ data: Data) { reply(data) }
}

private final class VoidReplyBox: @unchecked Sendable {
    private let reply: () -> Void
    init(_ reply: @escaping () -> Void) { self.reply = reply }
    func call() { reply() }
}

let listener = NSXPCListener.service()
private let serviceDelegate = ServiceDelegate()
listener.delegate = serviceDelegate
listener.resume()
