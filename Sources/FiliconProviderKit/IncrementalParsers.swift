import Foundation

public struct SSEParser: Sendable {
    private var line = Data()
    private var eventLines: [String] = []
    private var previousWasCR = false
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        var output: [String] = []
        for byte in data {
            if byte == 0x0D {
                completeLine(into: &output)
                previousWasCR = true
            } else if byte == 0x0A {
                if previousWasCR {
                    previousWasCR = false
                } else {
                    completeLine(into: &output)
                }
            } else {
                previousWasCR = false
                line.append(byte)
            }
        }
        return output
    }
    public mutating func finish() -> [String] {
        var output: [String] = []
        if !line.isEmpty { completeLine(into: &output) }
        dispatchEvent(into: &output)
        previousWasCR = false
        return output
    }

    private mutating func completeLine(into output: inout [String]) {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            dispatchEvent(into: &output)
        } else {
            eventLines.append(text)
        }
    }

    private mutating func dispatchEvent(into output: inout [String]) {
        guard !eventLines.isEmpty else { return }
        let dataLines = eventLines.compactMap { current -> String? in
            guard current.hasPrefix("data:") else { return nil }
            var value = String(current.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            return value
        }
        eventLines.removeAll(keepingCapacity: true)
        if !dataLines.isEmpty { output.append(dataLines.joined(separator: "\n")) }
    }
}

public struct NDJSONParser: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var output: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { output.append(text) }
        }
        return output
    }
    public mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: false)
        return text.isEmpty ? [] : [text]
    }
}
