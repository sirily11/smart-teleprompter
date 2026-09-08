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

## Import from Notion (disabled)

Notion import is temporarily hidden from the Add Script menu until OAuth is ready.
To restore it, set `notionImportEnabled` to `true` in `ScriptListView.swift`.

Once enabled, choose **+ → Import from Notion… → Connect to Notion**, sign in, select the pages
to share, then choose a page to import as an editable script. No user-entered
credentials or integration settings are required. The access token remains in
memory for the import session.

Imports include nested text and table cells in reading order. Links use their
visible text. Media, child pages, and databases are omitted. Imports are snapshots;
Notion changes do not automatically sync. Failed and empty imports create no script.

### OAuth deployment configuration (pending)

The native OAuth flow is prepared, but live sign-in requires the app's public
Notion client ID, registered HTTPS redirect URI, and an OAuth service. Fill the
three developer-owned constants in `Import/NotionOAuth.swift` before shipping.
They are intentionally empty until the actual integration settings are supplied.
The app never bundles a client secret or asks users to enter a token.

The service is not implemented in this repository; its backend location still
needs to be selected. It must implement this contract:

- `POST <serviceURL>/start`: accept `client_id`, `redirect_uri`, `state`,
  `code_challenge`, and `code_challenge_method: S256`. Validate the client and
  redirect against server configuration. Store a short-lived transaction bound
  to the state and challenge, then return `{ "authorization_url": "..." }` for
  `https://api.notion.com/v1/oauth/authorize` with that client, redirect, state,
  `owner=user`, and `response_type=code`.
- Registered HTTPS callback: validate and consume the transaction state, exchange
  Notion's code server-side using the client secret, and issue a short-lived,
  one-use ticket bound to the challenge. Redirect to
  `rxlab-smart-teleprompter://notion/callback?ticket=...&state=...`.
  On denial, redirect with `error=access_denied` and the verified state instead.
- `POST <serviceURL>/exchange`: accept `ticket` and `code_verifier`, verify its
  SHA-256 challenge, atomically consume the ticket, and return
  `{ "access_token": "..." }` with `Cache-Control: no-store`. Reject expired,
  reused, and mismatched tickets. Rate-limit endpoints and never log secrets,
  codes, tickets, or tokens. The verifier binding protects the app handoff;
  it does not assume Notion itself supports PKCE.

See Notion's [OAuth documentation](https://developers.notion.com/guides/get-started/authorization).
Page search and block retrieval use API version `2025-09-03`.
