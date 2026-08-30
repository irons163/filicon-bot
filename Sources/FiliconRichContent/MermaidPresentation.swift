import Foundation

public enum MermaidDiagramKind: String, Sendable, Equatable { case flowchart, sequence, state }
public struct MermaidNode: Sendable, Equatable, Identifiable {
    public let id: String; public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}
public struct MermaidEdge: Sendable, Equatable {
    public let from: String; public let to: String; public let label: String?
    public init(from: String, to: String, label: String? = nil) { self.from = from; self.to = to; self.label = label }
}
public struct MermaidDiagram: Sendable, Equatable {
    public let kind: MermaidDiagramKind; public let nodes: [MermaidNode]; public let edges: [MermaidEdge]
    public init(kind: MermaidDiagramKind, nodes: [MermaidNode], edges: [MermaidEdge]) { self.kind = kind; self.nodes = nodes; self.edges = edges }
}
public enum MermaidPresentation: Sendable, Equatable {
    case diagram(MermaidDiagram)
    case fallback(original: String, reason: String)
}

public struct MermaidLimits: Sendable, Equatable {
    public var maximumSourceBytes = 64 * 1024
    public var maximumLines = 1_000
    public var maximumNodes = 256
    public var maximumEdges = 512
    public var maximumLabelCharacters = 512
    public init() {}
}

public struct MermaidParser: Sendable {
    public let limits: MermaidLimits
    public init(limits: MermaidLimits = .init()) { self.limits = limits }

    public func parse(_ source: String) -> MermaidPresentation {
        guard source.utf8.count <= limits.maximumSourceBytes else { return fallback(source, "source_too_large") }
        guard !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { return fallback(source, "control_character") }
        let lowered = source.lowercased()
        let forbidden = ["click ", "click\t", "href", "javascript:", "linkstyle", "classdef", "callback", "call ", "%%{", "_blank"]
        let containsHTML = source.range(of: #"<[!/?A-Za-z][^>]*>"#, options: .regularExpression) != nil
        guard !containsHTML, !forbidden.contains(where: lowered.contains) else { return fallback(source, "unsafe_directive") }
        let lines = source.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard lines.count <= limits.maximumLines, let header = lines.first else { return fallback(source, "invalid_header") }
        let kind: MermaidDiagramKind
        if header.range(of: #"^(flowchart|graph)(\s+(TB|TD|BT|RL|LR))?$"#, options: [.regularExpression, .caseInsensitive]) != nil { kind = .flowchart }
        else if header.caseInsensitiveCompare("sequenceDiagram") == .orderedSame { kind = .sequence }
        else if header.lowercased().hasPrefix("statediagram") { kind = .state }
        else { return fallback(source, "unsupported_diagram") }

        var nodes: [String: MermaidNode] = [:], order: [String] = [], edges: [MermaidEdge] = []
        func validID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,127}$"#, options: .regularExpression) != nil }
        func cleaned(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty, value.count <= limits.maximumLabelCharacters, !value.contains("<"), !value.contains(">") else { return nil }
            return value
        }
        func put(_ id: String, _ label: String? = nil) -> Bool {
            guard validID(id), let safe = cleaned(label ?? id) else { return false }
            if nodes[id] == nil { nodes[id] = MermaidNode(id: id, label: safe); order.append(id) }
            else if label != nil { nodes[id] = MermaidNode(id: id, label: safe) }
            return nodes.count <= limits.maximumNodes
        }
        func add(_ from: String, _ to: String, _ label: String?) -> Bool {
            guard put(from), put(to), label.map(cleaned) != nil || label == nil else { return false }
            edges.append(MermaidEdge(from: from, to: to, label: label.flatMap(cleaned)))
            return edges.count <= limits.maximumEdges
        }

        for line in lines.dropFirst() {
            if line == "end" || line.hasPrefix("direction ") { continue }
            switch kind {
            case .flowchart:
                guard parseFlow(line, put: put, add: add) else { return fallback(source, "syntax_error") }
            case .sequence:
                guard parseSequence(line, put: put, add: add) else { return fallback(source, "syntax_error") }
            case .state:
                guard parseState(line, put: put, add: add) else { return fallback(source, "syntax_error") }
            }
        }
        guard !nodes.isEmpty else { return fallback(source, "empty_diagram") }
        return .diagram(MermaidDiagram(kind: kind, nodes: order.compactMap { nodes[$0] }, edges: edges))
    }

    private func parseFlow(_ line: String, put: (String, String?) -> Bool, add: (String, String, String?) -> Bool) -> Bool {
        // Supports common A[Label] -->|edge| B((Label)), plus standalone node declarations.
        let arrows = ["-->", "---", "-.->", "==>"]
        if let arrow = arrows.compactMap({ token in line.range(of: token).map { (token, $0) } }).first {
            let lhs = String(line[..<arrow.1.lowerBound]).trimmingCharacters(in: .whitespaces)
            var rhs = String(line[arrow.1.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label: String?
            if rhs.hasPrefix("|") , let close = rhs.dropFirst().firstIndex(of: "|") { label = String(rhs[rhs.index(after: rhs.startIndex)..<close]); rhs = String(rhs[rhs.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
            guard let left = nodeSpec(lhs), let right = nodeSpec(rhs), put(left.id, left.label), put(right.id, right.label) else { return false }
            return add(left.id, right.id, label)
        }
        guard let node = nodeSpec(line) else { return false }
        return put(node.id, node.label)
    }

    private func parseSequence(_ line: String, put: (String, String?) -> Bool, add: (String, String, String?) -> Bool) -> Bool {
        if line.hasPrefix("participant ") || line.hasPrefix("actor ") {
            let rest = line.split(separator: " ", maxSplits: 1)[1]
            let pieces = rest.components(separatedBy: " as ")
            return put(pieces[0].trimmingCharacters(in: .whitespaces), pieces.count > 1 ? pieces[1] : nil)
        }
        if ["Note ", "activate ", "deactivate ", "loop ", "alt ", "opt ", "par ", "else"].contains(where: line.hasPrefix) || line == "end" { return true }
        for arrow in ["-->>", "->>", "-->", "->", "-x", "--x"] {
            guard let range = line.range(of: arrow) else { continue }
            let from = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(line[range.upperBound...]); let parts = tail.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let to = String(parts[0]).trimmingCharacters(in: .whitespaces), label = parts.count > 1 ? String(parts[1]) : nil
            return add(from, to, label)
        }
        return false
    }

    private func parseState(_ line: String, put: (String, String?) -> Bool, add: (String, String, String?) -> Bool) -> Bool {
        if line.hasPrefix("state ") {
            let rest = String(line.dropFirst(6)); let parts = rest.components(separatedBy: " as ")
            if parts.count == 2 { return put(parts[1].trimmingCharacters(in: .whitespaces), parts[0]) }
            return put(rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), nil)
        }
        if let range = line.range(of: "-->") {
            var from = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(line[range.upperBound...]); let parts = tail.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var to = String(parts[0]).trimmingCharacters(in: .whitespaces)
            // Mermaid's pseudo-state is represented by a safe, native node.
            if from == "[*]" { from = "__state_boundary" }
            if to == "[*]" { to = "__state_boundary" }
            let label = parts.count > 1 ? String(parts[1]) : nil
            return add(from, to, label)
        }
        return false
    }

    private func nodeSpec(_ raw: String) -> (id: String, label: String?)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let boundary = text.firstIndex(where: { "[({".contains($0) }) else { return text.isEmpty ? nil : (text, nil) }
        let id = String(text[..<boundary]), tail = String(text[boundary...])
        guard let first = tail.first else { return nil }
        let expected: Character = first == "[" ? "]" : (first == "(" ? ")" : "}")
        guard tail.last == expected else { return nil }
        let label = tail.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}\"' "))
        return id.isEmpty ? nil : (id, label.isEmpty ? nil : label)
    }

    private func fallback(_ original: String, _ reason: String) -> MermaidPresentation { .fallback(original: original, reason: reason) }
}
