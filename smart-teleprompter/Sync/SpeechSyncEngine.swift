//
//  SpeechSyncEngine.swift
//  smart-teleprompter
//
//  Maps the live speech transcript onto a position in the script using a
//  forward, never-rewinding fuzzy word match.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class SpeechSyncEngine {

    // MARK: Tuning
    /// How far ahead of the current position we search for the spoken words.
    private let lookAheadWindow = 30
    /// How many of the most-recent recognized words we try to align each update.
    private let matchTail = 8
    /// Allowed gap (skipped script tokens) inside an otherwise-good alignment.
    private let maxSkips = 2

    // MARK: Script
    private(set) var tokens: [ScriptToken] = []
    private(set) var lineCount = 0

    // MARK: Published position
    /// Index of the last script token confirmed spoken (-1 before anything).
    private(set) var matchedTokenIndex: Int = -1
    var currentTokenIndex: Int { min(matchedTokenIndex + 1, tokens.count - 1) }
    var currentLineIndex: Int {
        guard !tokens.isEmpty else { return 0 }
        if matchedTokenIndex < 0 { return tokens.first?.lineIndex ?? 0 }
        let i = min(matchedTokenIndex, tokens.count - 1)
        return tokens[i].lineIndex
    }
    /// Timestamp of the last successful advance — UI can use this to detect
    /// "speaker has stalled / we've lost sync".
    private(set) var lastMatchDate: Date?

    // MARK: Per-utterance buffer
    /// Words from the current utterance we've already consumed (so a growing
    /// partial transcript doesn't get re-matched from the top every time).
    private var consumedWordsThisUtterance = 0

    func load(script: Script) { load(body: script.body) }

    func load(body: String) {
        let result = ScriptTokenizer.tokenize(body)
        tokens = result.tokens
        lineCount = result.lines.count
        reset()
        Log.sync.info("loaded script: \(self.tokens.count) tokens over \(self.lineCount) lines")
    }

    func reset() {
        matchedTokenIndex = -1
        consumedWordsThisUtterance = 0
        lastMatchDate = nil
    }

    /// Resume from a previously-saved position (clamped to the loaded script).
    func restore(tokenIndex: Int) {
        guard tokenIndex >= 0, tokenIndex < tokens.count else { return }
        matchedTokenIndex = tokenIndex
        consumedWordsThisUtterance = 0
        Log.sync.info("restored sync position to token \(tokenIndex) (line \(self.currentLineIndex))")
    }

    /// Force the position to a specific rendered line (used when the user
    /// manually drags the prompter).
    func snap(toLine line: Int) {
        if let last = tokens.last(where: { $0.lineIndex <= line }) {
            matchedTokenIndex = last.index
        } else {
            matchedTokenIndex = -1
        }
        consumedWordsThisUtterance = 0
        Log.sync.debug("snap to line \(line) -> matchedTokenIndex=\(self.matchedTokenIndex)")
    }

    // MARK: Transcript ingestion

    func ingest(_ update: SpeechTranscriptUpdate) {
        let words = ScriptTokenizer.normalizedWords(of: update.text)
        if !words.isEmpty {
            // The recognizer's running transcript can also shrink mid-utterance
            // when it revises an earlier guess — if it did, forget what we'd
            // consumed and re-align against the current tail (we never rewind,
            // so re-matching is safe).
            if words.count < consumedWordsThisUtterance { consumedWordsThisUtterance = 0 }
            // Only consider words we haven't aligned yet from this utterance.
            let newWords = words.count > consumedWordsThisUtterance
                ? Array(words[consumedWordsThisUtterance...]) : []
            if !newWords.isEmpty {
                let tail = Array(newWords.suffix(matchTail))
                let before = matchedTokenIndex
                if advance(usingSpokenTail: tail) {
                    consumedWordsThisUtterance = words.count
                    Log.sync.debug("matched \(tail, privacy: .public) -> token \(before)→\(self.matchedTokenIndex) (line \(self.currentLineIndex))")
                } else {
                    Log.sync.debug("no match for tail \(tail, privacy: .public) (still at token \(before), line \(self.currentLineIndex))")
                }
            }
        }
        if update.isFinal {
            // Next utterance's transcript will start from scratch.
            consumedWordsThisUtterance = 0
        }
    }

    /// Try to align `spoken` (recent recognized words) against the script just
    /// ahead of `matchedTokenIndex`. Returns true if we advanced.
    ///
    /// We consider every spoken word as a possible anchor — the speaker often
    /// prepends filler that isn't in the script ("我记得…", "uh, so…"), and a
    /// later word is the real first match — landing anywhere in the look-ahead
    /// window, then greedily extend the alignment from there (tolerating dropped
    /// script words via small forward jumps and inserted/mis-heard spoken words
    /// via skips). Among all candidates we keep the one that confirms the most
    /// words, preferring the alignment closest to where we already are on a tie.
    /// Never rewinds.
    ///
    /// To commit we then require more matched words the further past our current
    /// position the alignment starts: 2 keeps us reading straight on, a genuine
    /// line-skip (the speaker jumps ahead) is picked up within a word or two,
    /// but — crucially for CJK, where every token is a single character — a
    /// couple of coincidental common characters can't creep the prompter forward
    /// over a rough patch of recognition.
    private func advance(usingSpokenTail spoken: [String]) -> Bool {
        guard !tokens.isEmpty, !spoken.isEmpty else { return false }
        let searchStart = matchedTokenIndex + 1
        guard searchStart < tokens.count else { return false }
        let searchEnd = min(tokens.count, searchStart + lookAheadWindow)
        let gap = maxSkips + 2

        var best: (end: Int, matched: Int, jump: Int)?

        for si0 in spoken.indices {
            for anchor in searchStart..<searchEnd where fuzzyEqual(tokens[anchor].normalized, spoken[si0]) {
                var ti = anchor
                var end = anchor
                var matched = 1
                var misses = 0
                var si = si0 + 1
                while si < spoken.count {
                    let from = ti + 1
                    guard from < tokens.count else { break }
                    let to = min(tokens.count, from + gap)
                    if let found = (from..<to).first(where: { fuzzyEqual(tokens[$0].normalized, spoken[si]) }) {
                        ti = found
                        end = found
                        matched += 1
                        misses = 0
                    } else {
                        misses += 1
                        if misses > maxSkips { break }
                    }
                    si += 1
                }
                let jump = anchor - searchStart
                if best == nil
                    || matched > best!.matched
                    || (matched == best!.matched && jump < best!.jump) {
                    best = (end, matched, jump)
                }
            }
        }

        guard let best, best.end > matchedTokenIndex else { return false }
        let needed = best.jump <= 1 ? 2 : max(3, 2 + best.jump / 4)
        guard best.matched >= needed else {
            Log.sync.debug("rejecting alignment: matched \(best.matched) < needed \(needed) for jump \(best.jump) (still at token \(self.matchedTokenIndex))")
            return false
        }
        matchedTokenIndex = best.end
        lastMatchDate = Date()
        return true
    }

    /// Cheap fuzzy compare for near-homophones / minor mis-hears: equal if one
    /// is a prefix of the other (length ≥ 4) or they differ by a single edit.
    private func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if abs(a.count - b.count) > 1 { return false }
        // One-edit (Levenshtein ≤ 1) check.
        let (s, t) = a.count <= b.count ? (Array(a), Array(b)) : (Array(b), Array(a))
        if s.count < 3 { return false }
        var i = 0, j = 0, edits = 0
        while i < s.count && j < t.count {
            if s[i] == t[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if s.count == t.count { i += 1; j += 1 } else { j += 1 }
        }
        return true
    }
}
