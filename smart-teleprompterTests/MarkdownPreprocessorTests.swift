//
//  MarkdownPreprocessorTests.swift
//  smart-teleprompterTests
//

import Testing
@testable import smart_teleprompter

struct MarkdownPreprocessorTests {

    @Test func unwrapsInlineLinkToVisibleText() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "See [the docs](https://example.com) now")
        #expect(out == "See the docs now")
    }

    @Test func unwrapsLinkWithTitle() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: #"Read [this](https://x.com "A title") later"#)
        #expect(out == "Read this later")
    }

    @Test func removesInlineImageEntirely() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "![logo](a.png)Hello")
        #expect(out == "Hello")
    }

    @Test func imageOnlyLineCollapsesToEmpty() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "Title\n![banner](https://x.com/b.png)\nBody")
        #expect(out == "Title\n\nBody")
    }

    @Test func handlesMultipleLinksOnOneLine() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "Both [Apple](https://apple.com) and [Google](https://google.com) ship browsers")
        #expect(out == "Both Apple and Google ship browsers")
    }

    @Test func handlesImageNestedInsideLink() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "[![icon](i.png)](https://x.com)")
        #expect(out == "")
    }

    @Test func unwrapsReferenceLinkAndDropsDefinition() {
        let md = """
        Check [the spec][1] for details.

        [1]: https://example.com/spec "Spec"
        """
        let out = MarkdownPreprocessor.plainText(fromMarkdown: md)
        #expect(out == "Check the spec for details.\n")
    }

    @Test func unwrapsCollapsedReferenceLink() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "Visit [Example][] today")
        #expect(out == "Visit Example today")
    }

    @Test func removesAutolink() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "Source: <https://example.com> — enjoy")
        #expect(out == "Source:  — enjoy")
    }

    @Test func leavesNonLinkBracketsAlone() {
        let out = MarkdownPreprocessor.plainText(fromMarkdown: "array[0] = 1 and a [bracketed] aside")
        #expect(out == "array[0] = 1 and a [bracketed] aside")
    }

    @Test func preservesPlainTextAndLineStructure() {
        let md = """
        # Heading

        A plain paragraph with *emphasis* and a [link](https://x.com).

        - bullet one
        - bullet two
        """
        let expected = """
        # Heading

        A plain paragraph with *emphasis* and a link.

        - bullet one
        - bullet two
        """
        #expect(MarkdownPreprocessor.plainText(fromMarkdown: md) == expected)
    }
}
