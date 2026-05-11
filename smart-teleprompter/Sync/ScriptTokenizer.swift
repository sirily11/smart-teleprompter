//
//  ScriptTokenizer.swift
//  smart-teleprompter
//

import Foundation

/// One matchable unit of the script, plus where it lives in the rendered layout.
///
/// For space-delimited languages (English, etc.) a token is a word. For scripts
/// written without spaces (Chinese, Japanese, …) each ideograph/kana is its own
/// token — that's the granularity Apple's speech recognizer effectively gives
/// back, so it keeps both sides aligned.
struct ScriptToken: Equatable {
    let index: Int                    // position in the full token list
    let lineIndex: Int                // which rendered line it belongs to
    let normalized: String            // lowercased, letters/digits only — for matching
    let original: String              // exact substring as written
    let range: Range<String.Index>    // character range within its rendered line
}

/// A contiguous chunk of a rendered line tagged with the script token it belongs
/// to (if any). The teleprompter renders one `Text` per run so each can fade its
/// colour independently when speech reaches it. Inter-token runs (whitespace,
/// bare punctuation) carry `tokenIndex == nil` and dim along with the token that
/// precedes them.
struct LineRun: Identifiable {
    let id: Int                       // position within its line
    let text: String
    let tokenIndex: Int?              // script token this run renders, if any
    let precedingTokenIndex: Int      // nearest token at/before this run (-1 = none yet)
}

enum ScriptTokenizer {

    /// Normalize a chunk of text to lowercase, keeping only letters and digits.
    static func normalize<S: StringProtocol>(_ s: S) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() where ch.isLetter || ch.isNumber {
            out.append(ch)
        }
        return out
    }

    /// Break one line into matchable pieces with their character ranges: CJK
    /// characters are emitted individually; everything else is split on whitespace.
    static func segments(of line: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var wordStart: String.Index?
        var idx = line.startIndex

        func flushWord(end: String.Index) {
            defer { wordStart = nil }
            guard let ws = wordStart, ws < end else { return }
            result.append((String(line[ws..<end]), ws..<end))
        }

        while idx < line.endIndex {
            let ch = line[idx]
            let next = line.index(after: idx)
            if ch.isWhitespace {
                flushWord(end: idx)
            } else if ch.isCJKLike {
                flushWord(end: idx)
                result.append((String(ch), idx..<next))
            } else if wordStart == nil {
                wordStart = idx
            }
            idx = next
        }
        flushWord(end: line.endIndex)
        return result
    }

    /// Split recognized speech into a flat array of normalized tokens, using the
    /// same segmentation rules as `tokenize`.
    static func normalizedWords(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { segments(of: String($0)).map { normalize($0.text) } }
            .filter { !$0.isEmpty }
    }

    /// Tokenize a script body. Returns the tokens (for matching) and the raw
    /// lines (for rendering, one rendered line per `\n`-separated line — empty
    /// lines preserved so paragraph spacing survives).
    static func tokenize(_ body: String) -> (tokens: [ScriptToken], lines: [String]) {
        let rawLines = body.components(separatedBy: "\n")
        var tokens: [ScriptToken] = []
        for (lineIndex, line) in rawLines.enumerated() {
            for piece in segments(of: line) {
                let normalized = normalize(piece.text)
                guard !normalized.isEmpty else { continue }
                tokens.append(ScriptToken(index: tokens.count,
                                          lineIndex: lineIndex,
                                          normalized: normalized,
                                          original: piece.text,
                                          range: piece.range))
            }
        }
        return (tokens, rawLines)
    }

    /// Slice each rendered line into `LineRun`s — token pieces interleaved with
    /// the whitespace / bare-punctuation between them — using the same token
    /// numbering as `tokenize`. One run per word (or per CJK character) so the
    /// teleprompter can animate each independently.
    static func layoutRuns(forLines lines: [String]) -> [[LineRun]] {
        var result: [[LineRun]] = []
        result.reserveCapacity(lines.count)
        var tokenCounter = 0
        var lastToken = -1

        for line in lines {
            var runs: [LineRun] = []
            func emit(_ s: Substring, token: Int?) {
                guard !s.isEmpty else { return }
                runs.append(LineRun(id: runs.count, text: String(s),
                                    tokenIndex: token, precedingTokenIndex: lastToken))
                if let token { lastToken = token }
            }

            var cursor = line.startIndex
            for seg in segments(of: line) {
                if cursor < seg.range.lowerBound {
                    emit(line[cursor..<seg.range.lowerBound], token: nil)
                }
                if normalize(seg.text).isEmpty {
                    emit(line[seg.range], token: nil)            // bare punctuation
                } else {
                    emit(line[seg.range], token: tokenCounter)
                    tokenCounter += 1
                }
                cursor = seg.range.upperBound
            }
            if cursor < line.endIndex { emit(line[cursor...], token: nil) }
            if runs.isEmpty {
                runs = [LineRun(id: 0, text: " ", tokenIndex: nil, precedingTokenIndex: lastToken)]
            }
            result.append(runs)
        }
        return result
    }
}

extension Character {
    /// True for CJK ideographs, kana, and Hangul — scripts that don't put
    /// spaces between words.
    var isCJKLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,    // Hiragana + Katakana
                 0x3400...0x4DBF,    // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,    // CJK Unified Ideographs
                 0xF900...0xFAFF,    // CJK Compatibility Ideographs
                 0xAC00...0xD7AF,    // Hangul Syllables
                 0x20000...0x2FA1F:  // CJK Extensions B–F + Compatibility Supplement
                return true
            default:
                return false
            }
        }
    }
}
