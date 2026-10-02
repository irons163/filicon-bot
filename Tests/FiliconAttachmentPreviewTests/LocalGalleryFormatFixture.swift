import Foundation
import CoreGraphics
import ImageIO
import Testing

enum LocalGalleryFormatFixture {
    static func bytes(type: String, index: Int = 0) throws -> Data {
        if type == "webp" { return try webP(index: index) }
        let identifier: String
        switch type {
        case "gif": identifier = "com.compuserve.gif"
        case "apng": identifier = "public.png"
        case "tiff": identifier = "public.tiff"
        case "bmp": identifier = "com.microsoft.bmp"
        case "heic": identifier = "public.heic"
        case "avif": identifier = "public.avif"
        case "ico": identifier = "com.microsoft.ico"
        default: identifier = "public.png"
        }
        let frames = ["gif", "apng", "tiff"].contains(type) ? 2 : 1
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, identifier as CFString, frames, nil))
        let dictionary = type == "apng" ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
        let delay = type == "apng" ? kCGImagePropertyAPNGUnclampedDelayTime : kCGImagePropertyGIFUnclampedDelayTime
        let loop = type == "apng" ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyGIFLoopCount
        if ["gif", "apng"].contains(type) {
            CGImageDestinationSetProperties(destination, [dictionary: [loop: 2]] as CFDictionary)
        }
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for frame in 0..<frames {
            let red = (frame + index).isMultiple(of: 2)
            context.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1))
            context.fill(.init(x: 0, y: 0, width: 32, height: 32))
            let properties: CFDictionary? = ["gif", "apng"].contains(type)
                ? [dictionary: [delay: frame == 0 ? 0.1 : 0.2]] as CFDictionary : nil
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func webP(index: Int) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var body = Data("WEBP".utf8)
        body.append(chunk("VP8X", Data([0x12, 0, 0, 0]) + integer(1_535, count: 3) + integer(2_287, count: 3)))
        body.append(chunk("ANIM", Data(repeating: 0, count: 4) + integer(2, count: 2)))
        let names = index.isMultiple(of: 2) ? ["codex", "dewey"] : ["dewey", "codex"]
        for (frame, name) in names.enumerated() {
            let original = try Data(contentsOf: root.appending(path: "Sources/Filicon/Resources/PetAvatars/\(name).webp"))
            var cursor = 12
            var pixels = Data()
            while cursor + 8 <= original.count {
                let length = (0..<4).reduce(0) { $0 | Int(original[cursor + 4 + $1]) << ($1 * 8) }
                let end = cursor + 8 + length + length % 2
                try #require(end <= original.count)
                let tag = String(decoding: original[cursor..<(cursor + 4)], as: UTF8.self)
                if ["ALPH", "VP8 ", "VP8L"].contains(tag) { pixels.append(original[cursor..<end]) }
                cursor = end
            }
            try #require(!pixels.isEmpty)
            let header = Data(repeating: 0, count: 6) + integer(1_535, count: 3) + integer(2_287, count: 3)
                + integer(frame == 0 ? 100 : 200, count: 3) + Data([2])
            body.append(chunk("ANMF", header + pixels))
        }
        return Data("RIFF".utf8) + integer(body.count, count: 4) + body
    }

    private static func integer(_ value: Int, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func chunk(_ tag: String, _ payload: Data) -> Data {
        Data(tag.utf8) + integer(payload.count, count: 4) + payload + Data(repeating: 0, count: payload.count % 2)
    }
}
