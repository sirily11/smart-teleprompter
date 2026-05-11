//
//  AppleSpeechRecognizer.swift
//  smart-teleprompter
//
//  `SpeechRecognizing` backed by Apple's Speech framework + AVAudioEngine.
//

import Foundation
import AVFoundation
import Speech
import os

@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {

    private(set) var status: SpeechRecognizerStatus = .idle

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTask: Task<Void, Never>?

    private var stream: AsyncStream<SpeechTranscriptUpdate>
    private var continuation: AsyncStream<SpeechTranscriptUpdate>.Continuation
    private var isRunning = false

    // Restart-storm protection.
    private var currentTaskStartedAt: Date?
    private var consecutiveQuickFailures = 0
    private var forceServerRecognition = false

    var updates: AsyncStream<SpeechTranscriptUpdate> { stream }

    init(locale: Locale = Locale.current) {
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.speechRecognizer = recognizer
        var cont: AsyncStream<SpeechTranscriptUpdate>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
        Log.speech.info("init requestedLocale=\(locale.identifier, privacy: .public) actualLocale=\(recognizer?.locale.identifier ?? "nil", privacy: .public) onDeviceSupported=\(recognizer?.supportsOnDeviceRecognition ?? false)")
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        status = .authorizing
        let speechAuth = await withCheckedContinuation { (cc: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cc.resume(returning: $0) }
        }
        Log.speech.info("speech authorization status=\(speechAuth.rawValue)")
        guard speechAuth == .authorized else {
            status = .unavailable("Speech recognition permission was denied.")
            return false
        }
        let micOK: Bool
        if #available(iOS 17.0, macOS 14.0, *) {
            micOK = await AVAudioApplication.requestRecordPermission()
        } else {
            #if os(iOS)
            micOK = await withCheckedContinuation { (cc: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { cc.resume(returning: $0) }
            }
            #else
            micOK = true
            #endif
        }
        Log.speech.info("microphone permission granted=\(micOK)")
        guard micOK else {
            status = .unavailable("Microphone permission was denied.")
            return false
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            Log.speech.error("recognizer unavailable (recognizer=\(self.speechRecognizer != nil), isAvailable=\(self.speechRecognizer?.isAvailable ?? false))")
            status = .unavailable("Speech recognition is not available right now.")
            return false
        }
        Log.speech.info("authorization OK — ready to listen")
        status = .idle
        return true
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw RecognizerError.unavailable
        }

        // Fresh stream for this run.
        var cont: AsyncStream<SpeechTranscriptUpdate>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont

        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        Log.speech.info("start — input format \(format.sampleRate)Hz \(format.channelCount)ch")
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRunning = true
        status = .listening
        consecutiveQuickFailures = 0
        forceServerRecognition = false
        Log.speech.info("audio engine running, listening")
        beginRecognitionTask()
    }

    func stop() {
        Log.speech.info("stop")
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        status = .idle
        continuation.finish()
    }

    // MARK: - Recognition task (with auto-restart + storm protection)

    /// Apple's recognition tasks have a ~1 minute ceiling and occasionally fail
    /// transiently. When one ends we spin up the next — the audio engine keeps
    /// running so there's no gap — but with a short delay and failure caps so a
    /// persistently-failing recognizer can never hot-loop and freeze the app.
    private func beginRecognitionTask() {
        guard isRunning, let speechRecognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = false
        if speechRecognizer.supportsOnDeviceRecognition && !forceServerRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        currentTaskStartedAt = Date()
        Log.speech.debug("recognition task started (onDevice=\(req.requiresOnDeviceRecognition))")

        task = speechRecognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { self.consecutiveQuickFailures = 0 }   // healthy output
                    let final = result.isFinal
                    Log.speech.debug("transcript final=\(final) text=\"\(text, privacy: .public)\"")
                    self.continuation.yield(.init(text: text, isFinal: final))
                    if final { self.scheduleRestart() }
                } else if let error {
                    self.handleTaskFailure(error as NSError)
                }
            }
        }
    }

    private func handleTaskFailure(_ error: NSError) {
        let elapsed = currentTaskStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if elapsed < 1.0 { consecutiveQuickFailures += 1 } else { consecutiveQuickFailures = 0 }
        Log.speech.notice("recognition task ended after \(String(format: "%.2f", elapsed), privacy: .public)s: \(error.domain, privacy: .public) code=\(error.code) (quickFailures=\(self.consecutiveQuickFailures))")
        continuation.yield(.init(text: "", isFinal: true))

        if consecutiveQuickFailures == 2 && !forceServerRecognition {
            Log.speech.notice("falling back to server-based recognition")
            forceServerRecognition = true
            scheduleRestart()
            return
        }
        if consecutiveQuickFailures >= 5 {
            Log.speech.error("too many rapid recognition failures — stopping")
            stop()
            status = .unavailable("Speech recognition keeps failing on this device.")
            return
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        task = nil
        request = nil
        guard isRunning else { return }
        restartTask?.cancel()
        // Brief backoff so we never spin up tasks faster than the speech daemon
        // can handle; grows if we're failing repeatedly.
        let millis = consecutiveQuickFailures > 0 ? 500 * min(consecutiveQuickFailures, 8) : 150
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(millis))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.beginRecognitionTask()
        }
    }

    enum RecognizerError: Error { case unavailable }
}
