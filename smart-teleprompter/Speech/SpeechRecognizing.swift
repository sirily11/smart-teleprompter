//
//  SpeechRecognizing.swift
//  smart-teleprompter
//
//  The seam between the teleprompter and whatever provides live speech text.
//  v1 ships `AppleSpeechRecognizer`; a future `WhisperSpeechRecognizer` only
//  needs to conform to this protocol — nothing else changes.
//

import Foundation

/// A cumulative best-transcript snapshot for the *current* utterance.
/// `text` grows as the user keeps talking; on `isFinal` the recognizer has
/// closed out this utterance and the next update starts a fresh one.
struct SpeechTranscriptUpdate: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

enum SpeechRecognizerStatus: Sendable, Equatable {
    case idle
    case authorizing
    case listening
    /// Recognition can't run — carries a human-readable reason.
    case unavailable(String)
}

@MainActor
protocol SpeechRecognizing: AnyObject {
    /// Async stream of transcript updates. Consume this after `start()`.
    var updates: AsyncStream<SpeechTranscriptUpdate> { get }
    var status: SpeechRecognizerStatus { get }

    /// Prompt for any permissions the backend needs. Returns `true` if usable.
    func requestAuthorization() async -> Bool
    /// Begin capturing audio and emitting updates. Throws if it can't start.
    func start() throws
    /// Stop capture and end the `updates` stream.
    func stop()
}
