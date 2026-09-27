import AppKit
import Foundation

/// Static, self-contained vector avatars. Validate before handing bytes to
/// AppKit: no scripts, stylesheets, entity declarations or resource loaders.
/// Unsupported SVG features are rejected, never silently stripped.
enum StaticSVGAvatar {
    static func isXML(_ data: Data) -> Bool {
        // Do not let UTF-16/32 XML bypass the UTF-8 preflight into ImageIO.
        let prefix = Array(data.prefix(4))
        if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF])
            || prefix == [0, 0, 0xFE, 0xFF] || prefix.starts(with: [0x3C, 0])
            || prefix.starts(with: [0, 0x3C]) || prefix == [0, 0, 0, 0x3C] { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("<")
    }

    static func normalizedImage(_ data: Data) throws -> CGImage {
        guard data.count <= AgentAvatarChange.maximumImageSourceBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("<!"), !text.contains("\u{0000}") else { throw AgentAvatarStoreError.invalidImage }
        let delegate = Validator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.rootSeen, delegate.depth == 0 else {
            throw AgentAvatarStoreError.invalidImage
        }
        guard let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 20_000, image.size.height <= 20_000 else {
            throw AgentAvatarStoreError.unsafeDimensions
        }
        let scale = min(1, 1_024 / max(image.size.width, image.size.height))
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AgentAvatarStoreError.encodingFailed }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
                   operation: .copy, fraction: 1)
        guard let result = context.makeImage() else { throw AgentAvatarStoreError.encodingFailed }
        return result
    }

    private final class Validator: NSObject, XMLParserDelegate {
        var valid = true
        var rootSeen = false
        var depth = 0
        var count = 0
        var elementStack: [String] = []
        var gradientIDs: Set<String> = []
        var paintReferences: Set<String> = []
        var allIDs: Set<String> = []
        // Resource-bearing image/use/filter/foreignObject and animation nodes
        // are intentionally absent. No CSS parser or URL resolver is invoked.
        let elements: Set<String> = ["svg", "g", "defs", "title", "desc", "path", "rect", "circle", "ellipse",
            "line", "polyline", "polygon", "linearGradient", "radialGradient", "stop"]
        let attributes: Set<String> = ["id", "xmlns", "version", "width", "height", "viewBox", "preserveAspectRatio",
            "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "fr", "d", "points",
            "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
            "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "transform",
            "gradientTransform", "gradientUnits", "spreadMethod", "offset", "stop-color", "stop-opacity",
            "color", "vector-effect"]

        func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes values: [String: String]) {
            depth += 1; count += 1
            guard depth <= 64, count <= 4_096, elements.contains(elementName),
                  rootSeen || elementName == "svg" else { reject(parser); return }
            if let parent = elementStack.last, ["linearGradient", "radialGradient"].contains(parent),
               !["stop", "title", "desc"].contains(elementName) { reject(parser); return }
            elementStack.append(elementName)
            if let id = values["id"], !allIDs.insert(id).inserted { reject(parser); return }
            if ["linearGradient", "radialGradient"].contains(elementName), let id = values["id"] { gradientIDs.insert(id) }
            if !rootSeen {
                guard values["xmlns"] == "http://www.w3.org/2000/svg" else { reject(parser); return }
                rootSeen = true
            }
            for (key, value) in values {
                guard attributes.contains(key), value.utf8.count <= 65_536,
                      !value.contains("\\"), !value.contains("@"), !value.contains("/*"),
                      !value.contains("<"), !value.contains(">"),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0) }) else {
                    reject(parser); return
                }
                if key == "xmlns" {
                    guard value == "http://www.w3.org/2000/svg" else { reject(parser); return }
                } else if value.lowercased().contains("url") {
                    // Permit a single local paint/clip reference only, never a URL,
                    // data payload, CSS escape, fallback expression or stylesheet.
                    guard ["fill", "stroke"].contains(key),
                          !elementStack.contains(where: { ["linearGradient", "radialGradient"].contains($0) }),
                          value.range(of: #"^url\(#[A-Za-z_][A-Za-z0-9_.-]*\)$"#, options: .regularExpression) != nil else {
                        reject(parser); return
                    }
                    paintReferences.insert(String(value.dropFirst(5).dropLast()))
                }
                if ["width", "height"].contains(key), depth == 1 {
                    let numeric = value.hasSuffix("px") ? String(value.dropLast(2)) : value
                    guard let dimension = Double(numeric), dimension.isFinite, dimension > 0, dimension <= 20_000 else {
                        reject(parser); return
                    }
                }
            }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1; _ = elementStack.popLast()
        }
        func parserDidEndDocument(_ parser: XMLParser) {
            if !paintReferences.isSubset(of: gradientIDs) { reject(parser) }
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    }
}
