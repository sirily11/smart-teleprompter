# Smart Teleprompter

A teleprompter for iOS that **follows your voice**. Instead of scrolling at a fixed
speed, it listens while you speak, highlights the word you're on, and keeps that
word parked on the reading line — so the script moves at exactly your pace, pauses
when you pause, and catches up when you skip ahead.

Built with SwiftUI + SwiftData; speech recognition uses Apple's on-device
`SFSpeechRecognizer`.

## Features

- **Voice-synced scrolling** — a forward, never-rewinding fuzzy matcher aligns the
  live transcript to the script. It tolerates mis-hears, filler words you ad-lib,
  dropped words, and a speaker who jumps to the next paragraph early; when a line
  repeats it stays on the copy you're actually reading.
- **Word-by-word highlighting** — spoken text dims, the current word glows, and the
  view glides (not jumps) to keep it on the reading line.
- **Resume where you left off** — each script remembers its last position and font size.
- **Long-press to restart from a paragraph** — tap-and-hold any paragraph → "Start
  from here".
- **Mirror modes** — flip horizontally / vertically for beam-splitter rigs.
- **Pinch to resize text**, plus larger/smaller buttons and "back to top".
- **CJK support** — Chinese / Japanese / Korean scripts match per-character; the
  recognition locale is auto-detected from the script (e.g. zh-CN / zh-TW).
- **Markdown import** — links collapse to their visible text, images are dropped, so
  pasted Markdown reads as clean prose.
- **Script library** — create, edit, and manage multiple scripts (SwiftData).

## Project layout

| Path | What |
|------|------|
| `smart-teleprompter/Models/Script.swift` | SwiftData model |
| `smart-teleprompter/Views/` | `ScriptListView`, `ScriptEditorView`, `PresentView`, `TeleprompterTextView` |
| `smart-teleprompter/ViewModels/TeleprompterViewModel.swift` | present-mode state, locale detection, sync lifecycle |
| `smart-teleprompter/Speech/` | `SpeechRecognizing` protocol + `AppleSpeechRecognizer` |
| `smart-teleprompter/Sync/SpeechSyncEngine.swift` | transcript → script-position matcher |
| `smart-teleprompter/Sync/ScriptTokenizer.swift` | splits a script into matchable tokens + render runs |
| `smart-teleprompter/Import/MarkdownPreprocessor.swift` | Markdown → teleprompter prose |
| `smart-teleprompterTests/` | Swift Testing unit tests for the matcher, tokenizer, and Markdown preprocessor |

## Build & test

Open `smart-teleprompter.xcodeproj` in Xcode and run, or from the command line:

```sh
xcodebuild -scheme smart-teleprompter -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme smart-teleprompter -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Requires microphone and speech-recognition permission (requested on first use of
"Follow my voice").
