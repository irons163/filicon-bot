import AppKit
import Testing
import WebKit
@testable import Filicon

func mermaidGrammarFixture(_ kind: String) -> String? {
    switch kind {
    case "journey": "journey\ntitle Delivery\nsection Planning\nDesign: 5: Designer\nBuild: 3: Engineer"
    case "timeline": "timeline\ntitle Delivery\n2026 : Design : Build\n2027 : Review"
    case "quadrantChart": "quadrantChart\ntitle Delivery priorities\nx-axis Low effort --> High effort\ny-axis Low value --> High value\nquadrant-1 Plan\nquadrant-2 Deliver\nquadrant-3 Ignore\nquadrant-4 Review\nDesign: [0.25, 0.75]\nBuild: [0.75, 0.75]"
    case "requirementDiagram": "requirementDiagram\nrequirement delivery {\nid: 1\ntext: Ready for delivery\nrisk: low\nverifymethod: test\n}\nelement build {\ntype: project\ndocref: Delivery\n}\nbuild - satisfies -> delivery"
    default: nil
    }
}

@MainActor func mermaidDescendants(in view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + mermaidDescendants(in: $0) }
}

@MainActor func waitForMermaidSVG(in host: NSView, layout: () -> Void = {}) async throws -> MermaidSVGNativeView {
    for _ in 0..<160 {
        layout()
        if let view = ([host] + mermaidDescendants(in: host)).compactMap({ $0 as? MermaidSVGNativeView }).first,
           let value = try? await view.callAsyncJavaScript("""
            const image = document.getElementById('filicon-host-image');
            return !!image && getComputedStyle(image).visibility === 'visible' && image.firstElementChild?.tagName === 'svg';
            """, arguments: [:], in: nil, contentWorld: .defaultClient), value as? Bool == true {
            return view
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw MermaidRenderingTestFailure.notReady
}

@MainActor func captureMermaidSVG(_ webView: WKWebView, name: String) async throws -> NSBitmapImageRep {
    let snapshot = try await webView.takeSnapshot(configuration: nil)
    let bitmap = try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 500)
    if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: "\(name).png"))
    }
    return bitmap
}

@MainActor func captureMermaidHost(_ host: NSView, webView: WKWebView, name: String) async throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try await webView.takeSnapshot(configuration: nil)
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = NSAffineTransform()
    scale.scaleX(by: Double(bitmap.pixelsWide) / host.bounds.width / context.cgContext.ctm.a,
        yBy: Double(bitmap.pixelsHigh) / host.bounds.height / context.cgContext.ctm.d)
    scale.concat()
    var rectangle = host.convert(webView.bounds, from: webView)
    if host.isFlipped { rectangle.origin.y = host.bounds.height - rectangle.maxY }
    image.draw(in: rectangle, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(png.count > 500)
    if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: "\(name).png"))
    }
    return bitmap
}

private enum MermaidRenderingTestFailure: Error { case notReady }
