import Foundation
import FiliconLocalTools

guard let generationText = ProcessInfo.processInfo.environment["FILICON_LOCAL_TOOL_GENERATION"],
      let generation = UUID(uuidString: generationText),
      let keyText = ProcessInfo.processInfo.environment["FILICON_LOCAL_TOOL_SESSION_KEY"],
      let key = Data(base64Encoded: keyText) else {
    FileHandle.standardError.write(Data("Missing helper generation/session key.\n".utf8))
    exit(64)
}

let authenticator = LocalSessionAuthenticator(sessionKey: key)
let host = LocalToolProcessHost(generation: generation, authenticate: authenticator.verify)
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .millisecondsSince1970
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .millisecondsSince1970
encoder.outputFormatting = [.sortedKeys]

while let line = readLine() {
    let response: LocalToolWireResponse
    do {
        let request = try decoder.decode(LocalToolWireRequest.self, from: Data(line.utf8))
        response = await host.perform(request)
    } catch {
        response = LocalToolWireResponse(requestID: UUID(), result: nil, error: .invalidRequest(error.localizedDescription))
    }
    if let encoded = try? encoder.encode(response) {
        print(String(decoding: encoded, as: UTF8.self))
        fflush(stdout)
    }
}
