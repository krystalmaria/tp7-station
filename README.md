# tp7-station

**[Download for Mac](https://github.com/krystalmaria/tp7-station/releases/latest/download/tp7-station.dmg)** (macOS 26+, signed and notarized)

A native macOS station for the Teenage Engineering [TP-7 field recorder](https://teenage.engineering/products/tp-7). Plug in the recorder and it pulls new recordings automatically, transcribes voice memos on-device, and gives each one a title, no cloud involved. Send any memo to a markdown notes folder you choose (built with Obsidian in mind but it's just plain files) whenever you decide it's worth keeping. Rename a memo in the app and the file on the TP-7 itself picks up that name at the next sync.

Every recording and library track gets a waveform with in-app playback, and cue points can be added, dragged, nudged, and deleted with DAW-style keyboard controls, then written back into the WAV so the markers appear under the TP-7's physical cue controls.

## What it does
<img width="1920" height="1440" alt="station-cue-editor" src="https://github.com/user-attachments/assets/4594f325-1f55-42dc-a335-dca0a835c0dd" />

- **Auto-sync on plug-in, and on recovery**: no button ritual, no MTP mode gymnastics; the app performs the device's mode-switch handshake itself and returns it to normal when done. If the TP-7 ever wakes into the wrong USB mode (rare, but it happens and the app shows and explains it), power-cycling it back into the right mode triggers a sync on its own too.
- **Memos, transcribed and titled locally**: Apple's on-device SpeechAnalyzer and Foundation Models do the work, nothing leaves your Mac. Memos land in the app's inbox as soon as they sync; sending one to your notes folder as a markdown file is an explicit action (there's a toggle if you'd rather it happened automatically).
<img width="1920" height="1440" alt="station-obsidian" src="https://github.com/user-attachments/assets/3aec4758-e7ea-4e7a-b472-c09a84a36f66" />

_If you're an Obsidian user you can set your vault as a save location for memos with transcripts_

- **Cue editing**: waveforms with draggable cue markers, undo, zoom with an overview strip, peak snap, remappable shortcuts, and a hold-⌘ shortcut overlay; edits are written into the file and pushed back to the device.
- **File management**: rename a memo by its title (the device filename follows automatically) or a recording/library file by its raw name; delete from the device, the local archive, or both; add songs to the TP-7 library.
- **A menu bar reel** that pulses while syncing and plays your latest memos from the dropdown.
- **Keyboard shortcuts** use common DAW patterns and are configurable in settings.
  <img width="1920" height="1440" alt="station-recordings-shortcuts" src="https://github.com/user-attachments/assets/bf6d1633-2770-4617-8492-c01fed4e9d82" />


## Requirements

- macOS 26 (Tahoe); the transcription and titling APIs are new in 26
- A Teenage Engineering TP-7 (developed against firmware 1.1.11)
- The [`tp7` CLI](https://github.com/totocaster/tp7) — see Acknowledgments below. This build currently needs [two small patches on top of upstream](https://github.com/krystalmaria/tp7) (a firmware 1.1.11 USB product ID fix, and normalization-insensitive matching for accented filenames).

## Build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project TP7Companion.xcodeproj -scheme TP7Companion -destination 'platform=macOS' build
```

Core logic (device protocol wrapper, WAV cue/tempo metadata, sync engine) lives in a SwiftPM package with its own tests:

```sh
swift test --package-path Core
```

## Footnotes

This is a personal tool, shared as-is. It assumes one device and one user, has no code signing story beyond local development, and its idea of error handling is shaped by one particular TP-7's USB moods. Cue metadata behaviour was reverse-engineered from real device output (cues live in a standard trailing `cue` chunk; tempo in an `acid` chunk). MP3 cues never leave the device; that's the hardware, not the app.

Audio bytes are never modified by anything this app does. Cue edits do write metadata into the archived copy of the file (and push that same change to the device), so "archive" means "safe original audio," not "byte-for-byte untouched file on disk."

Not affiliated with Teenage Engineering.

## Acknowledgments

This app talks to the TP-7 entirely through [`tp7`](https://github.com/totocaster/tp7), a CLI written by **Toto Tvalavadze**. Every device communication primitive this app builds on (listing, pulling, pushing, renaming, deleting) comes from his work; thank you for open-sourcing it. This contribution sits on top: sync orchestration, local transcription and titling, notes export, waveform playback, cue editing and WAV metadata write-back, file management, and the native Mac interface itself.

## License

MIT
