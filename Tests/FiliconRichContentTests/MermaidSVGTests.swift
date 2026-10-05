import Foundation
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Mermaid output SVG safety")
struct MermaidSVGTests {
    @Test func boundedSVGPreservesShapesMarkersStylesAndPlainForeignLabels() throws {
        let input = document("""
        <defs><marker id="arrow" markerWidth="5" markerHeight="5"><path d="M0 0 L5 2.5 L0 5Z"/></marker></defs>
        <style>#diagram .edge{stroke:#333;stroke-width:2px;filter:drop-shadow(1px 2px 2px rgba(185,185,185,1));}#diagram text.actor>tspan{fill:black;}@keyframes dash{to{stroke-dashoffset:0;}}</style>
        <path class="edge" marker-end="url(#arrow)" d="M0 0 L100 50"/>
        <foreignObject width="100" height="40"><div xmlns="http://www.w3.org/1999/xhtml" style="display:table-cell;vertical-align:middle"><span>Hello &amp; 你好 👋</span></div></foreignObject>
        """)
        let svg = try #require(MermaidSVG.validated(input))
        expectNoDifference(svg.width, 200)
        expectNoDifference(svg.height, 100)
        #expect(svg.markup.contains("marker-end=\"url(#arrow)\""))
        #expect(svg.markup.contains("Hello &amp; 你好 👋"))
        #expect(svg.markup.contains("@keyframes dash"))
        expectNoDifference(MermaidSVG.validated(svg.markup), svg)
    }

    @Test func mathMLAnnotationsRemainPlainTextWithoutAnnotationXML() throws {
        let svg = try #require(MermaidSVG.validated(document("""
        <foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><math xmlns="http://www.w3.org/1998/Math/MathML"><semantics><msup><mi>x</mi><mn>2</mn></msup><annotation encoding="application/x-tex">x^2 &lt; y</annotation></semantics></math></div></foreignObject>
        """)))
        #expect(svg.markup.contains("x^2 &lt; y"))
        #expect(MermaidSVG.validated(document("<foreignObject><div xmlns=\"http://www.w3.org/1999/xhtml\"><math xmlns=\"http://www.w3.org/1998/Math/MathML\"><annotation-xml encoding=\"text/html\"><script/></annotation-xml></math></div></foreignObject>")) == nil)
    }

    @Test func publicEngineInertIrregularitiesAreCanonicalizedWithoutAddingResourceTargets() throws {
        let svg = try #require(MermaidSVG.validated(document("""
        <style>#diagram [data-look="neo"] rect{stroke:url(#unused-gradient);}</style>
        <g id="node"><path id="node" style="undefined;;;undefined" d="M0 0 L1 1"/></g>
        """)))
        expectNoDifference(svg.markup.components(separatedBy: "id=\"node\"").count, 2)
        #expect(!svg.markup.contains("undefined"))
        #expect(svg.markup.contains("url(#unused-gradient)"))
        expectNoDifference(MermaidSVG.validated(svg.markup), svg)
    }

    @Test func journeySwitchLabelsAndOverflowRemainInertAndCanonical() throws {
        let svg = try #require(MermaidSVG.validated(document("""
        <g><switch><foreignObject width="100" height="40"><div class="task" style="display:table;height:100%;width:100%"><div class="label" style="display:table-cell;text-align:center;vertical-align:middle">Design &amp; review</div></div></foreignObject><text>Design &amp; review</text></switch></g>
        <circle cx="20" cy="30" r="15" overflow="visible"/>
        """)))
        #expect(svg.markup.contains("<switch>"))
        #expect(svg.markup.contains("overflow=\"visible\""))
        #expect(svg.markup.contains("Design &amp; review"))
        expectNoDifference(svg.markup.components(separatedBy: "xmlns=\"http://www.w3.org/1999/xhtml\"").count, 2)
        expectNoDifference(MermaidSVG.validated(svg.markup), svg)
    }

    @Test(arguments: ["brightness(0)", "brightness(1.2)", "brightness(120%)", "brightness(0%)", "brightness(200%)"])
    func boundedBrightnessFilterSupportsTimelineWithoutResources(value: String) throws {
        let svg = try #require(MermaidSVG.validated(document("<style>#diagram .eventWrapper{filter:\(value);}</style><g class=\"eventWrapper\" filter=\"\(value)\"><text>Delivery</text></g>")))
        #expect(svg.markup.contains("filter:\(value)"))
        expectNoDifference(MermaidSVG.validated(svg.markup), svg)
    }

    @Test func aSingleLocalFilterResolvesToItsBoundedDefinition() throws {
        let svg = try #require(MermaidSVG.validated(document("""
        <defs><filter id="shadow"><feDropShadow stdDeviation="2"/></filter></defs>
        <rect style="filter:url(#shadow)"/><rect filter="url(#shadow)"/>
        """)))
        #expect(svg.markup.contains("filter=\"url(#shadow)\""))
        expectNoDifference(MermaidSVG.validated(svg.markup), svg)
    }

    @Test(arguments: [
        "<script>globalThis.bad=true</script>", "<rect onclick=\"bad()\"/>", "<rect onLoad=\"bad()\"/>",
        "<image href=\"https://example.invalid/image\"/>", "<image href=\"data:image/svg+xml,bad\"/>",
        "<a href=\"javascript:bad()\"><text>Link</text></a>", "<use href=\"#node\"/>",
        "<animate attributeName=\"href\" values=\"https://example.invalid\"/>",
        "<foreignObject><img xmlns=\"http://www.w3.org/1999/xhtml\" src=\"https://example.invalid\"/></foreignObject>",
        "<foreignObject><iframe xmlns=\"http://www.w3.org/1999/xhtml\" src=\"about:blank\"/></foreignObject>",
        "<foreignObject><div xmlns=\"http://www.w3.org/1999/xhtml\"><form><input/></form></div></foreignObject>",
        "<foreignObject><div xmlns=\"http://www.w3.org/1999/xhtml\" contenteditable=\"true\"/></foreignObject>",
        "<switch><script>globalThis.bad=true</script></switch>",
        "<switch><foreignObject><div><img src=\"https://example.invalid/image\"/></div></foreignObject></switch>",
        "<switch requiredExtensions=\"https://example.invalid\"><text>Label</text></switch>",
        "<foreignObject><div xmlns=\"urn:foreign\">Label</div></foreignObject>",
        "<foreignObject><div><svg viewBox=\"0 0 1 1\"/></div></foreignObject>",
        "<foreignObject><div onclick=\"bad()\">Label</div></foreignObject>",
        "<circle overflow=\"url(https://example.invalid)\"/>", "<circle overflow=\"unknown\"/>",
        "<rect href=\"file:///private/fixture\"/>", "<g xml:base=\"https://example.invalid\"/>",
        "<foreignObject><div xmlns=\"http://www.w3.org/1999/xhtml\"><style>body{display:none}</style></div></foreignObject>",
        "<g xmlns=\"urn:foreign\"><rect/></g>", "<div/>", "<svg viewBox=\"0 0 1 1\"/>",
        "<rect xmlns:xlink=\"urn:foreign\"/>", "<svg:rect xmlns:svg=\"http://www.w3.org/2000/svg\"/>",
        "<rect id=\"bad id\"/>",
        "<path marker-end=\"url(#missing)\"/>", "<path fill=\"url(https://example.invalid)\"/>",
        "<rect fill=\"u&#114;l(https://example.invalid)\"/>", "<rect filter=\"url(data:image/svg+xml,bad)\"/>",
        "<rect style=\"background-image:url(https://example.invalid)\"/>",
        "<rect style=\"fill:var(--mermaid-font-family,url(//example.invalid))\"/>",
        "<rect style=\"fill:U R L(//example.invalid)\"/>",
        "<rect style=\"fill:u\\72l(https://example.invalid)\"/>",
        "<rect style=\"fill:u/**/rl(https://example.invalid)\"/>",
        "<rect style=\"width:expression(bad())\"/>", "<rect style=\"background:image-set('bad')\"/>",
        "<rect style=\"-moz-binding:url(bad)\"/>", "<rect style=\"behavior:url(bad)\"/>",
        "<style>@import 'https://example.invalid';</style>", "<style>@font-face{src:url(bad);}</style>",
        "<style>@media screen{rect{fill:red}}</style>",
        "<defs><marker id=\"cycle\"><path marker-end=\"url(#cycle)\"/></marker></defs>",
        "<style>rect{fill:red}broken</style>", "<style>rect{fill:red</style>",
        "<style><![CDATA[rect{fill:red}]]></style>", "<?xml-stylesheet href=\"https://example.invalid\"?>",
        "<!-- discarded comment -->", "<rect x=\"1e999\"/>", "<rect width=\"20001\"/>",
        "<rect style=\"font-size:1e999px\"/>", "<filter><feDropShadow stdDeviation=\"1000000\"/></filter>",
        "<rect style=\"filter:drop-shadow(1px 2px 1000000px black)\"/>",
        "<rect style=\"filter:drop-shadow(1px 2px 2px black) drop-shadow(1px 2px 1000000px black)\"/>",
        "<rect style=\"filter:brightness(200.1%)\"/>", "<rect style=\"filter:brightness(2.001)\"/>",
        "<rect style=\"filter:brightness(-1)\"/>", "<rect style=\"filter:brightness(1e999)\"/>",
        "<rect style=\"filter:brightness(nan)\"/>", "<rect style=\"filter:brightness(120%) brightness(120%)\"/>",
        "<rect style=\"filter:brightness(var(--mermaid-font-family))\"/>",
        "<rect style=\"filter:brightness(120%) url(https://example.invalid)\"/>",
        "<rect style=\"filter:drop-shadow(1px 2px 2px black) brightness(300%)\"/>",
        "<rect style=\"filter:drop-shadow(1px 2px 2px black) brightness(120%)\"/>",
        "<defs><filter id=\"shadow\"><feDropShadow stdDeviation=\"2\"/></filter></defs><rect style=\"filter:url(#shadow) brightness(300%)\"/>",
        "<defs><filter id=\"shadow\"><feDropShadow stdDeviation=\"2\"/></filter></defs><rect style=\"filter:url(#shadow) brightness(120%)\"/>",
        "<rect filter=\"brightness(300%)\"/>", "<rect filter=\"brightness(1e999)\"/>",
        "<rect filter=\"drop-shadow(1px 2px 1000000px black)\"/>",
        "<rect filter=\"drop-shadow(1px 2px 2px black) brightness(120%)\"/>"
    ])
    func activeAndResourceBearingOutputFailsClosed(body: String) {
        #expect(MermaidSVG.validated(document(body)) == nil, "Must reject: \(body)")
    }

    @Test(arguments: ["0 0 200 100 junk", "0 0 junk 200 100", "0 0 0 100", "0 0 -1 100", "0 0 20001 100", "0 0 inf 100", "0 0 nan 100", "1e999 0 100 100", "0 0 200"])
    func viewBoxMustHaveExactlyFourFiniteBoundedNumbers(box: String) {
        #expect(MermaidSVG.validated(document("", box: box)) == nil)
    }

    @Test func entitiesInputOutputTreeAndAttributeBudgetsFailClosed() throws {
        #expect(MermaidSVG.validated("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///private/fixture'>]>" + document("<text>&x;</text>")) == nil)
        #expect(MermaidSVG.validated(document(String(repeating: " ", count: MermaidSVG.maximumBytes))) == nil)
        #expect(MermaidSVG.validated(document(String(repeating: "<g>", count: 128) + String(repeating: "</g>", count: 128))) == nil)
        #expect(MermaidSVG.validated(document(String(repeating: "<rect/>", count: 16_384))) == nil)
        #expect(MermaidSVG.validated(document("<rect data-label=\"" + String(repeating: "a", count: 65_537) + "\"/>")) == nil)
        let oversizedOutput = document(String(repeating: "<g/>", count: 10_000) + "<text>" + String(repeating: "&gt;", count: 510_000) + "</text>")
        #expect(oversizedOutput.utf8.count < MermaidSVG.maximumBytes)
        #expect(MermaidSVG.validated(oversizedOutput) == nil)
        #expect(MermaidSVG.validated(document("<text>&lt;/style&gt;&lt;script&gt;bad()&lt;/script&gt;</text>")) != nil)
    }

    private func document(_ body: String, box: String = "0 0 200 100") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"diagram\" viewBox=\"\(box)\">\(body)</svg>"
    }
}
