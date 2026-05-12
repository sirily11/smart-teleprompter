//
//  SpeechSyncEngineTests.swift
//  smart-teleprompterTests
//

import Testing
@testable import smart_teleprompter

@MainActor
struct SpeechSyncEngineTests {

    private let script = """
    Welcome everyone to today's product demo.
    We are going to show you the new teleprompter.
    It follows your voice as you speak.
    """

    @Test func tokenizerSkipsPunctuationAndKeepsLines() {
        let (tokens, lines) = ScriptTokenizer.tokenize(script)
        #expect(lines.count == 3)
        #expect(tokens.first?.normalized == "welcome")
        // "today's" -> "todays" after normalization
        #expect(tokens.contains { $0.normalized == "todays" })
        // No empty tokens.
        #expect(!tokens.contains { $0.normalized.isEmpty })
        // Line indices are non-decreasing.
        #expect(tokens.map(\.lineIndex) == tokens.map(\.lineIndex).sorted())
    }

    @Test func tokenizerDropsBlankLines() {
        let (tokens, lines) = ScriptTokenizer.tokenize("first paragraph\n\n   \nsecond paragraph\n")
        #expect(lines == ["first paragraph", "second paragraph"])
        #expect(tokens.first?.lineIndex == 0)
        #expect(tokens.last?.lineIndex == 1)
        // Line indices stay contiguous (0, 1) — no gap left by the dropped rows.
        #expect(Set(tokens.map(\.lineIndex)) == [0, 1])
    }

    @Test func advancesMonotonicallyWithGrowingPartialTranscript() {
        let engine = SpeechSyncEngine()
        engine.load(body: script)
        #expect(engine.matchedTokenIndex == -1)

        let partials = [
            "welcome everyone",
            "welcome everyone to todays",
            "welcome everyone to todays product demo",
            "welcome everyone to todays product demo we are going",
        ]
        var last = engine.matchedTokenIndex
        for p in partials {
            engine.ingest(.init(text: p, isFinal: false))
            #expect(engine.matchedTokenIndex >= last)
            last = engine.matchedTokenIndex
        }
        // Should have moved into line 1 ("We are going ...").
        #expect(engine.currentLineIndex == 1)
    }

    @Test func toleratesAMisheardWordInTheMiddle() throws {
        let engine = SpeechSyncEngine()
        engine.load(body: script)
        // "to" misheard as "two", "demo" misheard as "demos".
        engine.ingest(.init(text: "welcome everyone two todays product demos", isFinal: false))
        let (tokens, _) = ScriptTokenizer.tokenize(script)
        let demoIndex = try #require(tokens.firstIndex { $0.normalized == "demo" })
        #expect(engine.matchedTokenIndex >= demoIndex - 1)
    }

    @Test func neverRewindsOnSpuriousLaterUtterance() {
        let engine = SpeechSyncEngine()
        engine.load(body: script)
        engine.ingest(.init(text: "welcome everyone to todays product demo we are going to show you", isFinal: true))
        let advanced = engine.matchedTokenIndex
        #expect(advanced > 5)
        // A new utterance that accidentally contains an early word must not rewind.
        engine.ingest(.init(text: "welcome", isFinal: false))
        #expect(engine.matchedTokenIndex == advanced)
    }

    @Test func weakLaterMatchDoesNotJumpAhead() {
        let engine = SpeechSyncEngine()
        // "alpha bravo" appears again ~9 tokens past where we'll be parked.
        let body = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima alpha bravo zulu"
        engine.load(body: body)
        engine.ingest(.init(text: "alpha bravo charlie delta echo foxtrot", isFinal: true))
        let parked = engine.matchedTokenIndex
        #expect(parked >= 5)
        // New utterance: just two common words whose only occurrence ahead of us
        // is far away — too little evidence for that jump, so we hold position.
        engine.ingest(.init(text: "alpha bravo", isFinal: false))
        #expect(engine.matchedTokenIndex == parked)
        // …but a full run that genuinely reaches there is allowed to catch up.
        engine.ingest(.init(text: "golf hotel india juliet kilo lima alpha bravo zulu", isFinal: false))
        #expect(engine.matchedTokenIndex > parked)
    }

    @Test func followsNextLineWhenSpeakerAddsFiller() {
        let engine = SpeechSyncEngine()
        // "i" recurs late in line 1 — the kind of trap that used to make the
        // matcher anchor on the wrong word and stall.
        let body = """
        do you accept this offer
        back then i was a student who stood up and said i accept
        """
        engine.load(body: body)
        engine.ingest(.init(text: "do you accept this offer", isFinal: true))
        let firstLineEnd = engine.matchedTokenIndex
        #expect(engine.currentLineIndex == 0)
        // New utterance: speaker prepends their own words before the script line.
        engine.ingest(.init(text: "i remember back then i was a student", isFinal: false))
        #expect(engine.matchedTokenIndex > firstLineEnd)
        #expect(engine.currentLineIndex == 1)
    }

    @Test func cjkFollowsNextLineDespiteFillerAndRepeatedChar() {
        let engine = SpeechSyncEngine()
        let body = """
        即可瞬间掌握一切，你愿意吗？
        当时还在高二的我，便在班上的语文课上站起来说：我愿意。
        """
        engine.load(body: body)
        engine.ingest(.init(text: "即可瞬间掌握一切你愿意吗", isFinal: true))
        #expect(engine.currentLineIndex == 0)
        let parked = engine.matchedTokenIndex

        // New utterance, growing partial: the speaker prepends "我记得", says
        // "还是" for "还", and "我" recurs later in the same line — yet the
        // prompter must follow forward into line 1 and never rewind.
        let partials = ["我", "我记", "我记得", "我记得当时", "我记得当时还是在", "我记得当时还是在高二的我"]
        var last = engine.matchedTokenIndex
        for p in partials {
            engine.ingest(.init(text: p, isFinal: false))
            #expect(engine.matchedTokenIndex >= last)
            last = engine.matchedTokenIndex
        }
        #expect(engine.matchedTokenIndex > parked)
        #expect(engine.currentLineIndex == 1)
    }

    @Test func jumpsToNextParagraphWhenSpeakerSkipsAhead() {
        let engine = SpeechSyncEngine()
        let body = """
        first i will cover the background then the design and only at the very end the results
        now the results are what everyone came here for so let us start right there
        """
        engine.load(body: body)
        // Speaker reads the opening of paragraph one, then trails off without
        // finishing it.
        engine.ingest(.init(text: "first i will cover the background", isFinal: true))
        let parked = engine.matchedTokenIndex
        #expect(parked >= 5)
        #expect(engine.currentLineIndex == 0)
        // …and jumps straight into paragraph two — the prompter must follow,
        // not stall on the unfinished first paragraph.
        engine.ingest(.init(text: "now the results are what everyone came here for", isFinal: false))
        #expect(engine.currentLineIndex == 1)
        #expect(engine.matchedTokenIndex > parked)
    }

    @Test func repeatedLineStaysOnTheNearestCopy() {
        let engine = SpeechSyncEngine()
        // The same sentence appears twice; the speaker is reading the first copy.
        let body = """
        the quick brown fox jumps over the lazy dog
        here is a sentence of completely different filler words in between
        the quick brown fox jumps over the lazy dog
        and then the talk continues on to entirely new material
        """
        engine.load(body: body)
        engine.ingest(.init(text: "the quick brown", isFinal: false))
        #expect(engine.currentLineIndex == 0)
        // Hearing the whole repeated sentence must not teleport us to the second
        // copy — the distance penalty keeps us on the one we're already at.
        engine.ingest(.init(text: "the quick brown fox jumps over the lazy dog", isFinal: false))
        #expect(engine.currentLineIndex == 0)
        #expect(engine.matchedTokenIndex < 9)
    }

    @Test func manualSnapToLine() {
        let engine = SpeechSyncEngine()
        engine.load(body: script)
        engine.snap(toLine: 2)
        #expect(engine.currentLineIndex == 2)
    }
}
