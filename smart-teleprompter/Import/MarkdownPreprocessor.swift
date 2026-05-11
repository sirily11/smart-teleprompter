//
//  MarkdownPreprocessor.swift
//  smart-teleprompter
//
//  Turns a Markdown document into the plain prose a teleprompter wants to
//  scroll: link/image syntax is noise to read aloud, so images are dropped
//  entirely and links collapse to their visible text. Everything else
//  (headers, emphasis, lists) is left exactly as written — out of scope.
//

import Foundation

enum MarkdownPreprocessor {

    /// Returns plain text for a teleprompter: images removed entirely, links
    /// replaced by their visible text, link reference definitions and autolinks
    /// stripped. Other Markdown is preserved verbatim.
    static func plainText(fromMarkdown markdown: String) -> String {
        // Drop reference-definition lines (`[id]: https://… "title"`) wholesale,
        // optionally indented up to three spaces.
        let lines = markdown.components(separatedBy: "\n")
        let kept = lines.filter { !isReferenceDefinition($0) }
        var text = kept.joined(separator: "\n")

        // Images first — `![alt](url)` / `![alt][id]` — so the leading `!` is
        // gone before we unwrap links. Removed entirely (alt text included).
        text = replace(in: text, pattern: #"!\[[^\]]*\]\([^)]*\)"#, with: "")
        text = replace(in: text, pattern: #"!\[[^\]]*\]\[[^\]]*\]"#, with: "")

        // Inline links `[text](url "title")` → `text`. Empty text (e.g. a link
        // whose only content was an image we just removed) collapses to nothing.
        text = replace(in: text, pattern: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        // Reference links `[text][id]` / `[text][]` → `text`.
        text = replace(in: text, pattern: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1")

        // Autolinks `<https://…>` / `<mailto:…>` — drop them.
        text = replace(in: text, pattern: #"<(?:https?|mailto):[^>\s]+>"#, with: "")

        return text
    }

    /// `[id]: destination "optional title"`, possibly indented ≤ 3 spaces.
    private static func isReferenceDefinition(_ line: String) -> Bool {
        let pattern = #"^\s{0,3}\[[^\]]+\]:\s*\S.*$"#
        return firstMatch(in: line, pattern: pattern) != nil
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)
    }
}
