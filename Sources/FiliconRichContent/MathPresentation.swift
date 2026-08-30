import Foundation

public enum MathPresentation: Sendable, Equatable {
    /// Self-contained MathML, safe to place in a WebKit document with scripts disabled.
    case mathML(String)
    case fallback(original: String)
}

public struct OfflineMathPresenter: Sendable {
    public init() {}
    public func presentation(for source: String, mode: MathMode) -> MathPresentation {
        guard source.utf8.count <= 16_384, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
        else { return .fallback(original: source) }
        var parser = LatexParser(source)
        guard let body = parser.parseSequence(until: nil), parser.atEnd else { return .fallback(original: source) }
        let display = mode == .display ? "block" : "inline"
        return .mathML("<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"\(display)\"><mrow>\(body)</mrow></math>")
    }
}

private struct LatexParser {
    let chars: [Character]; var index = 0
    init(_ value: String) { chars = Array(value) }
    var atEnd: Bool { index == chars.count }

    mutating func parseSequence(until terminator: Character?) -> String? {
        var output = ""
        while index < chars.count {
            if let terminator, chars[index] == terminator { index += 1; return output }
            if chars[index] == "}" { return nil }
            guard var atom = parseAtom() else { return nil }
            while index < chars.count, chars[index] == "^" || chars[index] == "_" {
                let superscript = chars[index] == "^"; index += 1
                guard let argument = parseArgument() else { return nil }
                atom = superscript ? "<msup>\(atom)<mrow>\(argument)</mrow></msup>" : "<msub>\(atom)<mrow>\(argument)</mrow></msub>"
            }
            output += atom
        }
        return terminator == nil ? output : nil
    }

    mutating func parseAtom() -> String? {
        let ch = chars[index]; index += 1
        if ch == "{" { return parseSequence(until: "}").map { "<mrow>\($0)</mrow>" } }
        if ch == "\\" {
            var command = ""
            while index < chars.count, chars[index].isLetter { command.append(chars[index]); index += 1 }
            if command == "frac" { guard let a = parseArgument(), let b = parseArgument() else { return nil }; return "<mfrac><mrow>\(a)</mrow><mrow>\(b)</mrow></mfrac>" }
            if command == "sqrt" { guard let a = parseArgument() else { return nil }; return "<msqrt><mrow>\(a)</mrow></msqrt>" }
            let symbols = ["alpha":"α","beta":"β","gamma":"γ","delta":"δ","theta":"θ","lambda":"λ","mu":"μ","pi":"π","sigma":"σ","phi":"φ","omega":"ω","times":"×","cdot":"·","le":"≤","ge":"≥","neq":"≠","infty":"∞","sum":"∑","int":"∫"]
            guard let symbol = symbols[command] else { return nil }
            return "<mi>\(symbol)</mi>"
        }
        if ch.isWhitespace { return "<mspace width=\"0.25em\"/>" }
        let escaped = escape(String(ch))
        if ch.isNumber { return "<mn>\(escaped)</mn>" }
        if ch.isLetter { return "<mi>\(escaped)</mi>" }
        if "+-=()[]/,.*<>".contains(ch) { return "<mo>\(escaped)</mo>" }
        return nil
    }

    mutating func parseArgument() -> String? {
        guard index < chars.count else { return nil }
        if chars[index] == "{" { index += 1; return parseSequence(until: "}") }
        return parseAtom()
    }

    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}
