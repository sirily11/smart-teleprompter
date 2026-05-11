//
//  TeleprompterViewModel.swift
//  smart-teleprompter
//

import Foundation
import Observation
import NaturalLanguage
import Speech
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class TeleprompterViewModel {

    // Display
    var fontSize: Double
    var mirrorHorizontal = false
    var mirrorVertical = false

    // Speech sync
    var isRunning = false
    private(set) var recognizerStatus: SpeechRecognizerStatus = .idle

    let lines: [String]
    /// Tokens grouped by their rendered line — precomputed so per-frame text
    /// styling never has to scan the whole token list.
    let tokensByLine: [[ScriptToken]]
    /// Each line pre-sliced into renderable runs (one `Text` per word / CJK
    /// char) so the teleprompter can animate each run's colour independently.
    let lineRuns: [[LineRun]]
    let sync = SpeechSyncEngine()

    private let script: Script
    private let recognizer: any SpeechRecognizing
    private var consumeTask: Task<Void, Never>?

    static let minFontSize: Double = 18
    static let maxFontSize: Double = 220
    static let fontStep: Double = 6

    /// Language the speech recognizer is running in (auto-detected from the script).
    let recognitionLocale: Locale

    init(script: Script, recognizer: (any SpeechRecognizing)? = nil) {
        self.script = script
        let locale = Self.preferredLocale(forScript: script.body)
        self.recognitionLocale = locale
        self.recognizer = recognizer ?? AppleSpeechRecognizer(locale: locale)
        self.fontSize = min(max(script.fontSize, Self.minFontSize), Self.maxFontSize)

        let parsed = ScriptTokenizer.tokenize(script.body)
        self.lines = parsed.lines
        var byLine = Array(repeating: [ScriptToken](), count: max(parsed.lines.count, 1))
        for token in parsed.tokens where token.lineIndex < byLine.count {
            byLine[token.lineIndex].append(token)
        }
        self.tokensByLine = byLine
        self.lineRuns = ScriptTokenizer.layoutRuns(forLines: parsed.lines)

        sync.load(script: script)
        sync.restore(tokenIndex: script.lastTokenIndex)
    }

    /// Pick the speech-recognition locale that best fits the script's language,
    /// falling back to the device locale. Chinese scripts map to zh-CN / zh-TW.
    static func preferredLocale(forScript body: String) -> Locale {
        let detector = NLLanguageRecognizer()
        detector.processString(body)
        guard let lang = detector.dominantLanguage else {
            Log.ui.notice("language detection: none — using device locale \(Locale.current.identifier, privacy: .public)")
            return .current
        }
        Log.ui.info("language detection: \(lang.rawValue, privacy: .public)")
        let supported = SFSpeechRecognizer.supportedLocales()

        func firstSupported(prefixes: [String]) -> Locale? {
            for p in prefixes.map({ $0.lowercased() }) {
                if let m = supported.first(where: {
                    $0.identifier.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix(p)
                }) { return m }
            }
            return nil
        }

        switch lang {
        case .simplifiedChinese:  return firstSupported(prefixes: ["zh-cn", "zh-hans", "zh"]) ?? .current
        case .traditionalChinese: return firstSupported(prefixes: ["zh-tw", "zh-hk", "zh-hant", "zh"]) ?? .current
        default:
            let raw = lang.rawValue
            return firstSupported(prefixes: [raw, String(raw.prefix(2))]) ?? .current
        }
    }

    // MARK: Font

    func increaseFont() { fontSize = min(Self.maxFontSize, fontSize + Self.fontStep) }
    func decreaseFont() { fontSize = max(Self.minFontSize, fontSize - Self.fontStep) }
    func setFont(_ value: Double) { fontSize = min(Self.maxFontSize, max(Self.minFontSize, value)) }

    // MARK: Position

    func resetToTop() {
        Log.ui.debug("reset to top")
        sync.reset()
        script.lastTokenIndex = -1
    }

    /// Jump the reading position to the start of the given rendered line, so the
    /// next thing the prompter follows is that paragraph.
    func startReading(fromLine line: Int) {
        Log.ui.debug("start reading from line \(line)")
        sync.start(fromLine: line)
        script.lastTokenIndex = sync.matchedTokenIndex
    }

    // MARK: Speech sync lifecycle

    func toggleSync() {
        if isRunning { stopSync() } else { Task { await startSync() } }
    }

    func startSync() async {
        guard !isRunning else { return }
        Log.ui.info("startSync (locale=\(self.recognitionLocale.identifier, privacy: .public))")
        recognizerStatus = .authorizing
        let ok = await recognizer.requestAuthorization()
        guard ok else {
            Log.ui.error("startSync aborted — authorization failed: \(String(describing: self.recognizer.status), privacy: .public)")
            recognizerStatus = recognizer.status
            return
        }
        do {
            try recognizer.start()
        } catch {
            Log.ui.error("startSync — recognizer.start() threw: \(error.localizedDescription, privacy: .public)")
            recognizerStatus = .unavailable("Couldn't start the microphone.")
            return
        }
        isRunning = true
        recognizerStatus = recognizer.status
        Log.ui.info("sync running")
        let stream = recognizer.updates
        consumeTask = Task { [weak self] in
            for await update in stream {
                guard let self else { break }
                self.sync.ingest(update)
            }
            Log.ui.debug("transcript stream ended")
        }
    }

    func stopSync() {
        guard isRunning else { return }
        Log.ui.info("stopSync")
        isRunning = false
        consumeTask?.cancel()
        consumeTask = nil
        recognizer.stop()
        recognizerStatus = .idle
    }

    // MARK: Present-mode lifecycle

    func onEnterPresent() {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    func onExitPresent() {
        stopSync()
        persistSettings()
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func persistSettings() {
        var changed = false
        if script.fontSize != fontSize { script.fontSize = fontSize; changed = true }
        if script.lastTokenIndex != sync.matchedTokenIndex { script.lastTokenIndex = sync.matchedTokenIndex; changed = true }
        if changed { script.updatedAt = Date() }
    }
}
