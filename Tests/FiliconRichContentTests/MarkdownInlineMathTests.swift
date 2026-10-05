import Foundation
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Inline math Markdown protection")
struct MarkdownInlineMathTests {
    @Test func protectsExpressionsWithoutSplittingInlineFormattingOrReferenceDefinitions() throws {
        let source = #"**before \(\frac{a_1}{b}\) after** [\(y\)][r]"# + "\n\n[r]: https://example.com"
        let value = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(value.formulas.map(\.source), [#"\frac{a_1}{b}"#, "y"])
        expectNoDifference(value.markdown, "**before FILICONINLINEFORMULA0N0END after** [FILICONINLINEFORMULA0N1END][r]\n\n[r]: https://example.com")
        let parsed = try AttributedString(markdown: value.markdown)
        #expect(parsed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        expectNoDifference(parsed.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    @Test func tokensCannotBeForgedByMessageTextOrTeX() throws {
        let source = #"FILICONINLINEFORMULA0N0END \(\text{FILICONINLINEFORMULA1N}\)"#
        let value = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(value.formulas.map(\.token), ["FILICONINLINEFORMULA2N0END"])
        expectNoDifference(value.formulas.map(\.source), [#"\text{FILICONINLINEFORMULA1N}"#])
        expectNoDifference(value.markdown, "FILICONINLINEFORMULA0N0END FILICONINLINEFORMULA2N0END")
        expectNoDifference(MarkdownInlineMath.protect(source), value)
    }

    @Test func codeEscapesDollarDisplayAndUnclosedLookalikesStayLiteral() throws {
        for source in [#"`\(x\)`"#, #"``\(x\) `code` ``"#, #"\\(x\\)"#, #"$x$"#, #"\[x\]"#, #"\(unfinished"#, "\\(across\nlines\\)"] {
            #expect(MarkdownInlineMath.protect(source) == nil, "Must stay literal: \(source)")
        }
        let source = #"`\(code\)` then \(a\\)b\) then \(z\)"#
        let value = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(value.formulas.map(\.source), [#"a\\)b"#, "z"])
        #expect(value.markdown.hasPrefix(#"`\(code\)` then "#))
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func independentLinesKeepTheirMathAndUnclosedFirstLineCannotConsumeTheSecond(newline: String) throws {
        let source = #"\(broken"# + newline + #"Second \(x\)"#
        let value = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(value.formulas.map(\.source), ["x"])
        #expect(value.markdown.hasPrefix(#"\(broken"# + newline))
        let referenceSource = "[r]: https://example.com" + newline + #"Second \(y\)"#
        let afterReference = try #require(MarkdownInlineMath.protect(referenceSource))
        expectNoDifference(afterReference.formulas.map(\.source), ["y"])
    }

    @Test func linkDestinationsReferenceAddressesAndAutolinksAreNotFormulaText() throws {
        let source = #"[label](https://example.com/\(path\)) <https://example.org/\(auto\)> [\(visible\)](https://example.net)"# +
            "\n[r]: https://example.com/\\(ref\\)"
        let value = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(value.formulas.map(\.source), ["visible"])
        #expect(value.markdown.contains(#"https://example.com/\(path\)"#))
        #expect(value.markdown.contains(#"https://example.org/\(auto\)"#))
        #expect(value.markdown.contains(#"https://example.com/\(ref\)"#))
    }

    @Test func displayInsideInlineTeXAndInlineInsideDisplayStayInTheirOwnMode() {
        let inline = #"before \(\text{\[literal\]}\) after"#
        expectNoDifference(RichMarkdownParser().parse(inline), [.prose(inline)])
        expectNoDifference(MarkdownInlineMath.protect(inline)?.formulas.map(\.source), [#"\text{\[literal\]}"#])
        #expect(MarkdownInlineMath.protect(#"\[\text{\(literal\)}\]"#) == nil)
    }

    @Test func unclosedTagSuffixPreservesLaterMathWithoutRepeatedAddressSearches() throws {
        let prefix = String(repeating: "<", count: 200_000)
        let inline = prefix + #" BEFORE \(x\) AFTER"#
        let value = try #require(MarkdownInlineMath.protect(inline))
        expectNoDifference(value.formulas.map(\.source), ["x"])
        #expect(value.markdown.hasPrefix(prefix + " BEFORE "))
        #expect(value.markdown.hasSuffix(" AFTER"))
        #expect(MarkdownInlineMath.protect(prefix) == nil)
        let display = prefix + #" BEFORE \[y\] AFTER"#
        let blocks = RichMarkdownParser().parse(display)
        expectNoDifference(blocks.count, 3)
        expectNoDifference(Array(blocks.dropFirst()), [.math(source: "y", mode: .display), .prose(" AFTER")])
        let closedTag = #"<span title="\(hidden\)"> \(visible\)"#
        expectNoDifference(MarkdownInlineMath.protect(closedTag)?.formulas.map(\.source), ["visible"])
    }

    @Test func sourceAndFormulaCountBoundsFailClosedWithoutPartialReplacement() throws {
        let boundary = (0..<128).map { "\\(x_{\($0)}\\)" }.joined(separator: " ")
        expectNoDifference(try #require(MarkdownInlineMath.protect(boundary)).formulas.count, 128)
        #expect(MarkdownInlineMath.protect(boundary + #" \(tooMany\)"#) == nil)
        expectNoDifference(MarkdownInlineMath.prepare(boundary + #" \(tooMany\)"#), .rejected)
        expectNoDifference(MarkdownInlineMath.prepare("ordinary text"), .plain)
        #expect(MarkdownInlineMath.protect(String(repeating: "a", count: 262_145) + #"\(x\)"#) == nil)
        // Many unmatched delimiters/destinations must not repeatedly scan the entire suffix.
        #expect(MarkdownInlineMath.protect(String(repeating: #"\( ]("#, count: 8_000)) == nil)
    }

    @Test func indexedCodeRunsKeepExactAndNearestClosersWithoutRepeatedSuffixSearches() throws {
        let prefix = (1...600).map { String(repeating: "`", count: $0) + " " }.joined()
        let value = try #require(MarkdownInlineMath.protect(prefix + #"BEFORE \(visible\) AFTER"#))
        expectNoDifference(value.formulas.map(\.source), ["visible"])
        #expect(value.markdown.hasPrefix(prefix + "BEFORE "))
        let separate = #"`one \(hidden\)` middle \(visible\) `two \(hidden\)` tail \(final\)"#
        expectNoDifference(MarkdownInlineMath.protect(separate)?.formulas.map(\.source), ["visible", "final"])
        for source in [#"``\(hidden\) `not a closer` `` \(visible\)"#,
                       #"`\(hidden\) \` \(visible\)"#, #"\` \(visible\)"#, #"\``\(visible\)``"#] {
            expectNoDifference(MarkdownInlineMath.protect(source)?.formulas.map(\.source), ["visible"])
        }
    }

    @Test func collidingMarkerInventoryRemainsCanonicalAndIndependentOfFormulaContents() throws {
        let prefix = (0..<8_000).map { "FILICONINLINEFORMULA\($0)N " }.joined()
        let formula = #"\text{FILICONINLINEFORMULA8000N}"#
        let value = try #require(MarkdownInlineMath.protect(prefix + "\\(" + formula + "\\)"))
        expectNoDifference(value.formulas.map(\.token), ["FILICONINLINEFORMULA8001N0END"])
        expectNoDifference(value.formulas.map(\.source), [formula])
        #expect(value.markdown.hasPrefix(prefix))
        #expect(value.markdown.hasSuffix("FILICONINLINEFORMULA8001N0END"))
        for marker in ["FILICONINLINEFORMULA00N", "FILICONINLINEFORMULA٠N", "FILICONINLINEFORMULA9223372036854775808N", "FILICONINLINEFORMULA\(Int.max)N"] {
            let canonical = try #require(MarkdownInlineMath.protect(marker + #" \(x\)"#))
            expectNoDifference(canonical.formulas.map(\.token), ["FILICONINLINEFORMULA0N0END"])
            #expect(canonical.markdown.hasPrefix(marker + " "))
        }
    }
}
