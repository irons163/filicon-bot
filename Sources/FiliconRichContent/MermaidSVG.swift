import Foundation

public struct MermaidSVG: Sendable, Equatable {
    public let markup: String
    public let width: Double
    public let height: Double

    public static let maximumBytes = 2_097_152

    public static func validated(_ source: String) -> Self? {
        guard source.utf8.count <= maximumBytes, !source.contains("<!"),
              !source.contains("<?"), !source.contains("\u{0000}") else { return nil }
        let validator = Validator()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse(), validator.valid, validator.stack.isEmpty,
              let size = validator.size, validator.references.isSubset(of: validator.ids),
              validator.output.utf8.count <= maximumBytes else { return nil }
        return .init(markup: validator.output, width: size.0, height: size.1)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private final class Validator: NSObject, XMLParserDelegate {
        struct Element {
            let name: String
            let namespace: String
            var text = ""
        }

        static let svgNamespace = "http://www.w3.org/2000/svg"
        static let htmlNamespace = "http://www.w3.org/1999/xhtml"
        static let mathNamespace = "http://www.w3.org/1998/Math/MathML"
        static let svgElements: Set<String> = ["svg", "g", "defs", "title", "desc", "path", "rect", "circle", "ellipse", "switch",
            "line", "polyline", "polygon", "text", "tspan", "marker", "symbol", "style", "foreignObject",
            "clipPath", "linearGradient", "radialGradient", "stop", "filter", "feDropShadow"]
        static let htmlElements: Set<String> = ["div", "span", "p", "br", "strong", "em", "b", "i", "u", "s",
            "small", "sub", "sup", "code"]
        static let mathElements: Set<String> = ["math", "semantics", "annotation", "mrow", "mi", "mo", "mn",
            "mtext", "mspace", "msup", "msub", "msubsup", "mfrac", "msqrt", "mroot", "mtable", "mtr", "mtd",
            "mover", "munder", "munderover", "mpadded", "mphantom", "menclose", "mstyle"]
        static let commonAttributes: Set<String> = ["xmlns", "id", "class", "style", "role", "aria-roledescription",
            "aria-label", "aria-labelledby", "aria-describedby", "aria-hidden", "name"]
        static let svgAttributes: Set<String> = ["xmlns:xlink", "version", "width", "height", "viewBox", "preserveAspectRatio",
            "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr", "d", "points",
            "fill", "fill-opacity", "fill-rule", "clip-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
            "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "transform",
            "transform-origin", "gradientTransform", "gradientUnits", "spreadMethod", "offset", "stop-color", "stop-opacity",
            "color", "vector-effect", "font-family", "font-size", "font-weight", "font-style", "text-anchor", "textLength",
            "lengthAdjust", "dominant-baseline", "alignment-baseline", "dx", "dy", "marker-end", "marker-start", "marker-mid",
            "markerHeight", "markerWidth", "markerUnits", "refX", "refY", "orient", "clip-path", "filter", "filterUnits",
            "stdDeviation", "flood-color", "flood-opacity", "overflow"]
        static let mathAttributes: Set<String> = ["display", "encoding", "mathvariant", "mathsize", "mathcolor",
            "mathbackground", "stretchy", "fence", "separator", "lspace", "rspace", "minsize", "maxsize",
            "movablelimits", "accent", "accentunder", "scriptlevel", "displaystyle", "linethickness", "numalign",
            "denomalign", "columnalign", "rowalign", "columnspacing", "rowspacing", "width", "height", "depth", "voffset"]
        static let numericAttributes: Set<String> = ["x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry",
            "fx", "fy", "fr", "d", "points", "dx", "dy", "stroke-width", "stroke-miterlimit", "stroke-dasharray",
            "stroke-dashoffset", "markerHeight", "markerWidth", "refX", "refY", "stdDeviation", "textLength"]
        static let number = try? NSRegularExpression(pattern: #"[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?"#)
        static let identifier = try? NSRegularExpression(pattern: #"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,255}$"#)
        static let url = try? NSRegularExpression(pattern: #"url\(\s*['\"]?(#[A-Za-z0-9_][A-Za-z0-9_.:-]{0,255})['\"]?\s*\)"#, options: .caseInsensitive)

        var valid = true
        var stack: [Element] = []
        var nodes = 0
        var rootSeen = false
        var ids: Set<String> = []
        var references: Set<String> = []
        var size: (Double, Double)?
        var output = ""
        var outputBytes = 0

        func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes values: [String: String]) {
            nodes += 1
            guard nodes <= 16_384, stack.count < 128, !name.contains(":"),
                  stack.last?.name != "style", stack.last?.name != "annotation" else { reject(parser); return }
            let implicitForeignLabel = values["xmlns"] == nil && stack.last?.name == "foreignObject"
                && Self.htmlElements.contains(name)
            let namespace = implicitForeignLabel ? Self.htmlNamespace : values["xmlns"] ?? stack.last?.namespace ?? ""
            let allowed: Set<String>
            switch namespace {
            case Self.svgNamespace:
                guard Self.svgElements.contains(name), stack.last?.namespace != Self.htmlNamespace,
                      stack.last?.namespace != Self.mathNamespace, name != "svg" || !rootSeen else { reject(parser); return }
                allowed = Self.commonAttributes.union(Self.svgAttributes)
            case Self.htmlNamespace:
                guard Self.htmlElements.contains(name), stack.contains(where: { $0.name == "foreignObject" }),
                      stack.last?.name == "foreignObject" || stack.last?.namespace == Self.htmlNamespace else { reject(parser); return }
                allowed = Self.commonAttributes
            case Self.mathNamespace:
                guard Self.mathElements.contains(name), stack.last?.namespace == Self.mathNamespace
                    || (name == "math" && stack.last?.namespace == Self.htmlNamespace) else { reject(parser); return }
                allowed = Self.commonAttributes.union(Self.mathAttributes)
            default: reject(parser); return
            }
            if !rootSeen {
                guard name == "svg", namespace == Self.svgNamespace, let box = values["viewBox"],
                      let dimensions = Self.viewBox(box) else { reject(parser); return }
                size = dimensions
                rootSeen = true
            }
            var normalized = values
            if implicitForeignLabel { normalized["xmlns"] = Self.htmlNamespace }
            if let id = values["id"] {
                guard Self.matches(id, Self.identifier) else { reject(parser); return }
                if !ids.insert(id).inserted { normalized.removeValue(forKey: "id") }
            }
            if name == "annotation", values["encoding"] != "application/x-tex" { reject(parser); return }
            for (key, value) in values {
                guard value.utf8.count <= 65_536, allowed.contains(key) || Self.dataAttribute(key),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0) }) else { reject(parser); return }
                if key == "xmlns:xlink", value != "http://www.w3.org/1999/xlink" { reject(parser); return }
                if key == "overflow", !["visible", "hidden", "scroll", "auto", "clip", "inherit"].contains(value) { reject(parser); return }
                if key == "filter", !CSS.safeFilter(value) { reject(parser); return }
                if key == "style" {
                    guard CSS.declarations(value), collectReferences(in: value, resourceElement: name) else { reject(parser); return }
                    let clean = CSS.normalizedDeclarations(value)
                    if clean.isEmpty { normalized.removeValue(forKey: key) }
                    else { normalized[key] = clean }
                } else if Self.svgAttributes.contains(key), key != "xmlns:xlink" {
                    guard safeAttribute(value), collectReferences(in: value, resourceElement: name) else { reject(parser); return }
                }
                if Self.numericAttributes.contains(key), !Self.boundedNumbers(value, maximum: key == "stdDeviation" ? 64 : 1_000_000) {
                    reject(parser); return
                }
                if ["width", "height", "font-size"].contains(key), !Self.boundedNumbers(value, maximum: 20_000) { reject(parser); return }
            }
            stack.append(.init(name: name, namespace: namespace))
            append("<" + name + normalized.keys.sorted().map { " \($0)=\"\(MermaidSVG.escape(normalized[$0]!))\"" }.joined() + ">", parser: parser)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else {
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
                return
            }
            if stack.last?.name == "style" { stack[stack.count - 1].text += string }
            else { append(MermaidSVG.escape(string), parser: parser) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let element = stack.popLast(), element.name == name else { reject(parser); return }
            if name == "style" {
                guard CSS.stylesheet(element.text), collectReferences(in: element.text, requireTarget: false) else { reject(parser); return }
                append(element.text.replacingOccurrences(of: "&", with: "&amp;"), parser: parser)
            }
            append("</\(name)>", parser: parser)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser) }
        func parser(_ parser: XMLParser, foundComment comment: String) { reject(parser) }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }

        private func append(_ value: String, parser: XMLParser) {
            outputBytes += value.utf8.count
            guard outputBytes <= MermaidSVG.maximumBytes else { reject(parser); return }
            output += value
        }

        private func safeAttribute(_ value: String) -> Bool {
            !value.contains("\\") && !value.contains("/*") && !value.contains("@")
                && !value.contains("<") && !value.contains(">") && !value.contains("://")
        }

        private func collectReferences(in value: String, requireTarget: Bool = true, resourceElement: String = "") -> Bool {
            guard let regex = Self.url else { return false }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, range: range)
            let resources = ["marker", "clipPath", "linearGradient", "radialGradient", "filter"]
            if requireTarget && !matches.isEmpty && (resources.contains(resourceElement) || stack.contains(where: { resources.contains($0.name) })) { return false }
            for match in matches {
                guard let fragment = Range(match.range(at: 1), in: value) else { return false }
                if requireTarget { references.insert(String(value[fragment].dropFirst())) }
            }
            let remainder = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            return remainder.range(of: "url", options: .caseInsensitive) == nil
        }

        private static func dataAttribute(_ key: String) -> Bool {
            key.range(of: #"^data-[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
        }

        private static func viewBox(_ value: String) -> (Double, Double)? {
            let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            guard tokens.count == 4 else { return nil }
            let values = tokens.compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
                  values[2] > 0, values[3] > 0, values[2] <= 20_000, values[3] <= 20_000 else { return nil }
            return (values[2], values[3])
        }

        private static func matches(_ value: String, _ regex: NSRegularExpression?) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
        }

        static func boundedNumbers(_ value: String, maximum: Double) -> Bool {
            guard let regex = number else { return false }
            let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
            guard matches.count <= 16_384 else { return false }
            return matches.allSatisfy {
                guard let range = Range($0.range, in: value), let number = Double(value[range]) else { return false }
                return number.isFinite && abs(number) <= maximum
            }
        }
    }

    private enum CSS {
        static let properties: Set<String> = ["--mermaid-font-family", "align-items", "alignment-baseline", "animation",
            "animation-name", "animation-duration", "animation-timing-function", "animation-iteration-count",
            "animation-direction", "animation-delay", "animation-fill-mode", "background", "background-color",
            "border", "border-bottom", "border-color", "border-width", "border-style", "border-radius", "box-shadow",
            "color", "cursor", "display", "dominant-baseline", "dy", "fill", "fill-opacity", "fill-rule", "filter",
            "font-family", "font-size", "font-style", "font-weight", "height", "justify-content", "line-height",
            "margin", "margin-top", "margin-bottom", "margin-left", "margin-right", "max-width", "max-height",
            "min-width", "min-height", "opacity", "overflow", "overflow-x", "overflow-y", "padding", "padding-top",
            "padding-bottom", "padding-left", "padding-right", "pointer-events", "position", "rx", "ry", "scale",
            "shape-rendering", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin",
            "stroke-opacity", "stroke-width", "text-align", "text-anchor", "text-decoration", "transform",
            "transform-origin", "transition-duration", "vertical-align", "visibility", "white-space", "width",
            "word-break", "overflow-wrap", "z-index"]
        static let functions: Set<String> = ["rgb", "rgba", "hsl", "hsla", "var", "calc", "min", "max", "clamp", "url",
            "translate", "translatex", "translatey", "scale", "scalex", "scaley", "rotate", "matrix", "linear-gradient", "drop-shadow", "brightness"]
        static let functionPattern = try? NSRegularExpression(pattern: #"([A-Za-z_-][A-Za-z0-9_-]*)\s*\("#)
        static let shadowLengths = try? NSRegularExpression(pattern: #"^drop-shadow\(\s*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)(?:px)?\s+([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)(?:px)?(?:\s+([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)(?:px)?)?(?:\s|\))"#)
        static let brightness = try? NSRegularExpression(pattern: #"^brightness\(\s*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)(%)?\s*\)$"#, options: .caseInsensitive)

        static func declarations(_ value: String) -> Bool {
            guard safeTokens(value), !value.contains("{") && !value.contains("}"), !value.contains("@") else { return false }
            for statement in value.split(separator: ";", omittingEmptySubsequences: true) {
                if statement.trimmingCharacters(in: .whitespacesAndNewlines) == "undefined" { continue }
                guard let colon = statement.firstIndex(of: ":") else {
                    if statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    return false
                }
                let property = statement[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let contents = statement[statement.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard properties.contains(property), !contents.isEmpty, safeFunctions(contents), balanced(contents),
                      !contents.contains(":"), property != "cursor" || ["default", "pointer", "auto", "inherit"].contains(contents) else { return false }
                if ["width", "height", "font-size", "max-width", "max-height", "min-width", "min-height"].contains(property),
                   !Validator.boundedNumbers(contents, maximum: 20_000) { return false }
                if property == "filter", !safeFilter(contents) { return false }
            }
            return true
        }

        static func normalizedDeclarations(_ value: String) -> String {
            value.split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "undefined" }.joined(separator: ";")
        }

        static func stylesheet(_ value: String) -> Bool {
            guard safeTokens(value), balanced(value) else { return false }
            return rules(value[...], keyframes: false)
        }

        private static func rules(_ input: Substring, keyframes: Bool) -> Bool {
            var remainder = input
            while !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let open = remainder.firstIndex(of: "{") else { return false }
                let selector = remainder[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selector.isEmpty else { return false }
                var depth = 1, cursor = remainder.index(after: open)
                let start = cursor
                while cursor < remainder.endIndex, depth > 0 {
                    if remainder[cursor] == "{" { depth += 1 }
                    if remainder[cursor] == "}" { depth -= 1 }
                    if depth > 4 { return false }
                    if depth > 0 { cursor = remainder.index(after: cursor) }
                }
                guard depth == 0 else { return false }
                let body = remainder[start..<cursor]
                if selector.hasPrefix("@keyframes ") && !keyframes {
                    let name = String(selector.dropFirst(11))
                    guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil,
                          rules(body, keyframes: true) else { return false }
                } else {
                    guard !selector.contains("@"), !selector.contains(";"), !selector.contains("}"),
                          !selector.contains("<"),
                          declarations(String(body)) else { return false }
                    if keyframes, selector.range(of: #"^(from|to|[0-9]{1,3}%(\s*,\s*[0-9]{1,3}%)*)$"#, options: .regularExpression) == nil { return false }
                }
                remainder = remainder[remainder.index(after: cursor)...]
            }
            return true
        }

        private static func safeTokens(_ value: String) -> Bool {
            !value.contains("\\") && !value.contains("/*") && !value.contains("*/")
                && !value.contains("<") && !value.contains("://")
                && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0) })
        }

        private static func safeFunctions(_ value: String) -> Bool {
            guard let regex = functionPattern else { return false }
            return regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)).allSatisfy {
                guard let range = Range($0.range(at: 1), in: value) else { return false }
                return functions.contains(value[range].lowercased())
            }
        }

        static func safeFilter(_ value: String) -> Bool {
            if ["none", "inherit"].contains(value) { return true }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if let match = Validator.url?.firstMatch(in: value, range: range), match.range == range { return true }
            if let regex = brightness, let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) {
                guard let range = Range(match.range(at: 1), in: value), let amount = Double(value[range]),
                      amount.isFinite, amount >= 0 else { return false }
                return amount <= (match.range(at: 2).location == NSNotFound ? 2 : 200)
            }
            guard value.range(of: "brightness", options: .caseInsensitive) == nil else { return false }
            guard let regex = shadowLengths, let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) else { return false }
            for index in 1...3 where match.range(at: index).location != NSNotFound {
                guard let range = Range(match.range(at: index), in: value), let length = Double(value[range]),
                      length.isFinite, abs(length) <= 64 else { return false }
            }
            return !value.dropFirst(match.range.length).lowercased().contains("drop-shadow")
        }

        private static func balanced(_ value: String) -> Bool {
            var stack: [Character] = [], quote: Character?
            for character in value {
                if let current = quote {
                    if character == current { quote = nil }
                    continue
                }
                if character == "\"" || character == "'" { quote = character }
                else if character == "(" || character == "[" || character == "{" { stack.append(character) }
                else if character == ")" || character == "]" || character == "}" {
                    let expected: Character = character == ")" ? "(" : character == "]" ? "[" : "{"
                    guard stack.popLast() == expected else { return false }
                }
                if stack.count > 16 { return false }
            }
            return quote == nil && stack.isEmpty
        }
    }
}
