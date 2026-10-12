import Foundation

/// Offline libwebp fixtures: 24 × 12 blue, yellow and teal stripes. No network,
/// repository avatars or system encoder support is required by these tests.
enum StaticWebPFixture {
    static let lossless = Data(base64Encoded: "UklGRjwAAABXRUJQVlA4TDAAAAAvF8ACABegIG0Dxlb90x2JYsFkPvmj9QsEEpW0B9tn/sN9QyAQIEya1Cogov+hUAc=")!
    static let lossy = Data(base64Encoded: "UklGRkwAAABXRUJQVlA4IEAAAABwAgCdASoYAAwAAUAmJaACdMoRgD8APwrAiMYAAP7sZv/9tm//7SzzENf8oP/rzOAj3lq64Q6Vp3/fF/jKAAAA")!
    static let alpha = Data(base64Encoded: "UklGRnIAAABXRUJQVlA4WAoAAAAQAAAAFwAACwAAQUxQSBEAAAABDzD/ERHi/v8R/Q//////BwBWUDggOgAAAPACAJ0BKhgADAA+bSyRRaQioZgEAEAGxKALsugACBsAAP7udn/FsUhuZ//Cmv/Cmv/Cmv+AZwAAAAA=")!
    static let animated = Data(base64Encoded: "UklGRqQAAABXRUJQVlA4WAoAAAACAAAAFwAACwAAQU5JTQYAAAAAAAAAAABBTk1GRgAAAAAAAAAAABcAAAsAAGQAAAJWUDhMLgAAAC8XwAIAFyCQTY4VZP4TCCSh7O+zj5Ag+V9pDrXPf9wTA4EAYdKkVgER/Q8oHQhBTk1GKgAAAAAAAAAAABcAAAsAAGQAAABWUDhMEQAAAC8XwAIAB1CQ+haq/4GI6H8AAA==")!

    static var extended: Data {
        var bytes = Data("RIFF".utf8)
        bytes.append(contentsOf: [78, 0, 0, 0])
        bytes.append(contentsOf: "WEBPVP8X".utf8)
        bytes.append(contentsOf: [10, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 11, 0, 0])
        bytes.append(lossless.dropFirst(12))
        return bytes
    }
}
