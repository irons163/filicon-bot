import Foundation

/// Tiny, offline libwebp fixtures; preserve these exact source bytes end to end.
enum StaticWebPFixture {
    // 24 × 12 blue, yellow and teal stripes for the selected-image preview.
    static let stripes = Data(base64Encoded: "UklGRjwAAABXRUJQVlA4TDAAAAAvF8ACABegIG0Dxlb90x2JYsFkPvmj9QsEEpW0B9tn/sN9QyAQIEya1Cogov+hUAc=")!
    // The native incoming review checks this magenta swatch against actual pixels.
    static let magenta = Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TBAAAAAvF8ACAAcQ/S9g/wMR0f8A")!
    static let animated = Data(base64Encoded: "UklGRqQAAABXRUJQVlA4WAoAAAACAAAAFwAACwAAQU5JTQYAAAAAAAAAAABBTk1GRgAAAAAAAAAAABcAAAsAAGQAAAJWUDhMLgAAAC8XwAIAFyCQTY4VZP4TCCSh7O+zj5Ag+V9pDrXPf9wTA4EAYdKkVgER/Q8oHQhBTk1GKgAAAAAAAAAAABcAAAsAAGQAAABWUDhMEQAAAC8XwAIAB1CQ+haq/4GI6H8AAA==")!
}
