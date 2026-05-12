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
    /// Tokens just past the current position that count as "reading straight on":
    /// a forward match in here barely pays a distance penalty and commits cheaply.
    private let nearWindow = 28
    /// How far past the current position we'll still look for the spoken words —
    /// wide enough to re-acquire a speaker who skipped a line or a whole
    /// paragraph. Matches out here have to clear a much higher similarity bar.
    private let lookAheadWindow = 220
    /// How many of the most-recent recognized words we try to align each update.
    private let matchTail = 8
    /// Allowed gap (skipped script tokens) inside an otherwise-good alignment.
    private let maxSkips = 2
    /// Score docked per token of forward jump — within `nearWindow` at the first
    /// rate, then a gentler rate beyond. This is what keeps the prompter on the
    /// *nearest* copy of a line that occurs more than once: a far candidate has
    /// to out-match a near one by enough to overcome the accumulated penalty.
    private let jumpPenaltyNear = 0.06
    private let jumpPenaltyFar = 0.03

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

    /// Set the position so the next word to be matched is the first token at or
    /// after `line` — i.e. "start reading again from this paragraph". If the
    /// line (and everything after it) has no tokens, parks at the end.
    func start(fromLine line: Int) {
        if let first = tokens.first(where: { $0.lineIndex >= line }) {
            matchedTokenIndex = first.index - 1
        } else {
            matchedTokenIndex = tokens.count - 1
        }
        consumedWordsThisUtterance = 0
        lastMatchDate = nil
        Log.sync.debug("start from line \(line) -> matchedTokenIndex=\(self.matchedTokenIndex)")
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

    /// Try to align `spoken` (recent recognized words) against the script ahead
    /// of `matchedTokenIndex`. Returns true if we advanced. Never rewinds.
    ///
    /// We consider every spoken word as a possible anchor — the speaker often
    /// prepends filler that isn't in the script ("我记得…", "uh, so…"), and a
    /// later word is the real first match — landing anywhere in the look-ahead
    /// window, then greedily extend the alignment from there (tolerating dropped
    /// script words via small forward jumps and inserted/mis-heard spoken words
    /// via skips).
    ///
    /// Each candidate scores `matched − distancePenalty(jump)`, so the prompter
    /// follows the *nearest* place the words fit: if a line repeats, the copy
    /// we're already next to wins unless a farther one genuinely matches more of
    /// what was just said. That fixes the stall where the speaker jumps to the
    /// next line/paragraph before finishing the current one — the continuation
    /// is now found ahead and, having far more matched words than the stale
    /// position, wins despite the distance penalty.
    ///
    /// To actually commit, a jump must clear a similarity bar that rises with
    /// distance: reading straight on needs only a 2-word confirmation; skipping
    /// a paragraph needs most of the recent tail to line up there — so a couple
    /// of coincidental common characters (every CJK token is one character!)
    /// can't creep the prompter forward over a rough patch of recognition.
    private func advance(usingSpokenTail spoken: [String]) -> Bool {
        guard !tokens.isEmpty, !spoken.isEmpty else { return false }
        let searchStart = matchedTokenIndex + 1
        guard searchStart < tokens.count else { return false }
        let searchEnd = min(tokens.count, searchStart + lookAheadWindow)
        let gap = maxSkips + 2

        func penalty(forJump jump: Int) -> Double {
            let near = Double(min(jump, nearWindow))
            let far = Double(max(0, jump - nearWindow))
            return near * jumpPenaltyNear + far * jumpPenaltyFar
        }

        var best: (end: Int, matched: Int, jump: Int, score: Double)?

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
                let score = Double(matched) - penalty(forJump: jump)
                if best == nil
                    || score > best!.score
                    || (score == best!.score && jump < best!.jump) {
                    best = (end, matched, jump, score)
                }
            }
        }

        guard let best, best.end > matchedTokenIndex else { return false }

        if best.jump <= 1 {
            // Reading straight on — a short confirmation is plenty.
            guard best.matched >= 2 else { return false }
        } else {
            // A jump must be backed by a solid fraction of what we just heard,
            // and the further the jump the larger that fraction — up to ~85%.
            // A *small* hop, though, is usually just the last word or two of a
            // paragraph going unrecognized before the speaker moves on, so it
            // only needs a light confirmation — otherwise the prompter stalls a
            // word shy of the paragraph break and you have to nudge it across.
            let base = best.jump <= maxSkips + 1 ? 0.30 : 0.45
            let need = min(0.85, base + Double(best.jump) * 0.012)
            let ratio = Double(best.matched) / Double(spoken.count)
            guard best.matched >= 3, ratio >= need else {
                Log.sync.debug("rejecting jump: matched \(best.matched)/\(spoken.count) ratio \(ratio) < need \(need) for jump \(best.jump) (still at token \(self.matchedTokenIndex))")
                return false
            }
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
